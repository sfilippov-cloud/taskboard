// What the email sync remembers between runs (sync-state.json): when it last ran and which threads it has
// already looked at, with the date of the latest message it saw — a thread is looked at again only once
// it has something newer.
import Foundation

public struct SyncState: Codable, Equatable, Sendable {
  public var lastRun: Date?
  public var lastError: String?
  public var threads: [String: Date] = [:]

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
