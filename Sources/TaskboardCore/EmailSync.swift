// What the email sync remembers between runs (sync-state.json): when it last ran and which threads it has
// already looked at, with the date of the latest message it saw — a thread is looked at again only once
// it has something newer.
import Foundation

public struct SyncState: Codable, Equatable, Sendable {
  public var lastRun: Date?  // the email check
  public var lastError: String?
  public var slackLastRun: Date?  // the Slack check
  public var slackLastError: String?
  public var reports: [String: String]?  // "email" / "slack" → what the last successful check looked at
  public var threads: [String: Date] = [:]  // Gmail thread id → latest message seen; Slack: "slack:<channel>" → same

  public init() {}

  static let keepDays = 14

  public mutating func record(thread id: String, lastMessage: Date) {
    if let known = threads[id], known >= lastMessage { return }
    threads[id] = lastMessage
  }

  public mutating func prune(now: Date = Date()) {
    let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
    threads = threads.filter { $0.value >= cutoff }
  }
}

// A check ends with a report (what it looked at: names, counts, outcomes — never message text) and, on the
// last line, a one-line summary. Anything before that last line is the report.
public struct CheckOutput: Equatable, Sendable {
  public var summary: String
  public var report: String?

  public init(_ text: String) {
    let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    let last = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
    summary = lines[last].trimmingCharacters(in: .whitespaces)
    let rest = lines[..<last].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    report = rest.isEmpty ? nil : rest
  }
}

public enum SyncStore {
  public static var url: URL { BoardStore.directory.appendingPathComponent("sync-state.json") }

  public static func load() -> SyncState {
    guard let data = try? Data(contentsOf: url), let state = try? BoardStore.decoder.decode(SyncState.self, from: data)
    else { return SyncState() }
    return state
  }

  @discardableResult
  public static func change<T>(_ body: (inout SyncState) throws -> T) throws -> T {
    try BoardStore.locked {
      var state = load()
      let before = state
      let result = try body(&state)
      if state != before { try BoardStore.encoder.encode(state).write(to: url, options: .atomic) }
      return result
    }
  }

  // The date format Claude uses when it records a thread: ISO 8601, with or without fractions or a time.
  public static func parseDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
    ] {
      formatter.formatOptions = options
      if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
    }
    return nil
  }
}
