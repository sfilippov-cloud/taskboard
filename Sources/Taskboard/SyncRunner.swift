// The read-only checks: Claude looks through the last few days of the inbox (Gmail) or of Slack, writes the
// journal and queues proposals. Each runs on demand and — once a manual run has succeeded — by itself at an interval.
import Foundation
import TaskboardCore

enum SyncKind: String, CaseIterable {
  case email, slack

  var title: String { self == .email ? "Email" : "Slack" }
  var icon: String { self == .email ? "envelope" : "number" }
  var running: String { self == .email ? "Checking email…" : "Checking Slack…" }
  var menuTitle: String { self == .email ? "Check email now" : "Check Slack now" }
  var days: Int { max(1, UserDefaults.standard.object(forKey: "\(rawValue)Days") as? Int ?? 3) }
  // Minutes between automatic runs; 0 turns them off.
  var intervalMinutes: Int { UserDefaults.standard.object(forKey: "\(rawValue)SyncMinutes") as? Int ?? 60 }
}

extension SyncState {
  func lastRun(_ kind: SyncKind) -> Date? { kind == .email ? lastRun : slackLastRun }
  func lastError(_ kind: SyncKind) -> String? { kind == .email ? lastError : slackLastError }
  func report(_ kind: SyncKind) -> String? { reports?[kind.rawValue] }

  mutating func finish(_ kind: SyncKind, error: String?, report: String? = nil) {
    if error == nil {
      var all = reports ?? [:]
      all[kind.rawValue] = report
      reports = all.isEmpty ? nil : all
    }
    switch kind {
    case .email:
      if error == nil { lastRun = Date() }
      lastError = error
    case .slack:
      if error == nil { slackLastRun = Date() }
      slackLastError = error
    }
  }
}

extension AppModel {
  // Newsletters and automated senders are filtered by Gmail itself, the rest by Claude.
  static var emailQuery: String {
    UserDefaults.standard.string(forKey: "emailQuery")
      ?? "in:inbox newer_than:\(SyncKind.email.days)d -from:(noreply OR no-reply OR donotreply OR notifications OR mailer-daemon) -\"unsubscribe\""
  }

  func isSyncing(_ kind: SyncKind) -> Bool { syncingKinds.contains(kind) }

  // The first run is always manual; automatic ones follow only after it has succeeded.
  func isAutoSyncDue(_ kind: SyncKind) -> Bool {
    let minutes = kind.intervalMinutes
    guard minutes > 0, !isSyncing(kind), let last = sync.lastRun(kind) else { return false }
    return Date().timeIntervalSince(last) >= Double(minutes) * 60
  }

  func sync(_ kind: SyncKind, manual: Bool) {
    guard !isSyncing(kind) else {
      if manual { show("The \(kind.title) check is already running") }
      return
    }
    syncingKinds.insert(kind)
    let before = board.proposals.count
    Task { @MainActor [self] in
      defer { syncingKinds.remove(kind) }
      let now = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
      let window = "Now: \(now) (\(TimeZone.current.identifier)). Look at the last \(kind.days) days."
      do {
        let text: String
        switch kind {
        case .email:
          text = try await ClaudeRunner.syncEmail(prompt: "Check the inbox. \(window)\nGmail search query: \(Self.emailQuery)")
        case .slack:
          text = try await ClaudeRunner.syncSlack(
            prompt: "Check Slack. \(window)\nThe channels mapped to each project are in list_projects.")
        }
        let output = CheckOutput(text)
        let summary = output.summary
        try? SyncStore.change { $0.finish(kind, error: nil, report: output.report) }
        reload()
        let added = board.proposals.count - before
        if manual || added > 0 { show(added > 0 ? "\(summary) (\(added) new proposal\(added == 1 ? "" : "s"))" : summary) }
      } catch {
        let message = error.localizedDescription
        let repeated = sync.lastError(kind) == message
        try? SyncStore.change { $0.finish(kind, error: message) }
        reload()
        if manual || !repeated { show("\(kind.title) check failed: \(message)", isError: true) }
      }
    }
  }
}
