// The email check: Claude (read-only Gmail) looks through the last few days of the inbox, writes the journal and
// queues proposals. It runs on demand, and — once a manual run has succeeded — by itself at an interval.
import Foundation
import TaskboardCore

extension AppModel {
  static var syncDays: Int { max(1, UserDefaults.standard.object(forKey: "emailDays") as? Int ?? 3) }

  // Minutes between automatic runs; 0 turns them off.
  static var syncIntervalMinutes: Int { UserDefaults.standard.object(forKey: "emailSyncMinutes") as? Int ?? 60 }

  // Newsletters and automated senders are filtered by Gmail itself, the rest by Claude.
  static var syncQuery: String {
    UserDefaults.standard.string(forKey: "emailQuery")
      ?? "in:inbox newer_than:\(syncDays)d -from:(noreply OR no-reply OR donotreply OR notifications OR mailer-daemon) -\"unsubscribe\""
  }

  // The first run is always manual; automatic ones follow only after it has succeeded.
  var isAutoSyncDue: Bool {
    let minutes = Self.syncIntervalMinutes
    guard minutes > 0, !syncing, let last = sync.lastRun else { return false }
    return Date().timeIntervalSince(last) >= Double(minutes) * 60
  }

  func syncEmail(manual: Bool) {
    guard !syncing else {
      if manual { show("The email check is already running") }
      return
    }
    syncing = true
    let before = board.proposals.count
    Task { @MainActor [self] in
      defer { syncing = false }
      let now = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
      let prompt = """
        Check the inbox. Now: \(now) (\(TimeZone.current.identifier)). Look at the last \(Self.syncDays) days.
        Gmail search query: \(Self.syncQuery)
        """
      do {
        let summary = try await ClaudeRunner.syncEmail(prompt: prompt)
        try? SyncStore.change { state in
          state.lastRun = Date()
          state.lastError = nil
        }
        reload()
        let added = board.proposals.count - before
        if manual || added > 0 { show(added > 0 ? "\(summary) (\(added) new proposal\(added == 1 ? "" : "s"))" : summary) }
      } catch {
        let message = error.localizedDescription
        let repeated = sync.lastError == message
        try? SyncStore.change { $0.lastError = message }
        reload()
        if manual || !repeated { show("Email check failed: \(message)", isError: true) }
      }
    }
  }
}
