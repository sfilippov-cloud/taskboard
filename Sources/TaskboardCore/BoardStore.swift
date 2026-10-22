// Reads and writes ~/Library/Application Support/Taskboard/board.json.
// The app and the MCP server change it from different processes, so every change holds an flock.
import Foundation

public enum BoardStore {
  public static var directory: URL {
    if let custom = ProcessInfo.processInfo.environment["TASKBOARD_DIR"], !custom.isEmpty {
      return URL(fileURLWithPath: custom, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Taskboard", isDirectory: true)
  }

  public static var boardURL: URL { directory.appendingPathComponent("board.json") }
  public static var archiveURL: URL { directory.appendingPathComponent("archive.jsonl") }
  public static var voiceDirectory: URL { directory.appendingPathComponent("voice", isDirectory: true) }
  static var lockURL: URL { directory.appendingPathComponent(".lock") }

  public static func load() -> Board {
    guard let data = try? Data(contentsOf: boardURL),
      let board = try? decoder.decode(Board.self, from: data)
    else { return Board() }
    return board
  }

  // Loads, changes and saves the board under the lock; returns what the change returned.
  @discardableResult
  public static func change<T>(_ body: (inout Board) throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    defer { close(fd) }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN) }

    var board = load()
    let before = board
    let result = try body(&board)
    let stale = board.takeStaleDone()
    if !stale.isEmpty { archive(stale) }
    if board != before {
      try encoder.encode(board).write(to: boardURL, options: .atomic)
    }
    return result
  }

  static func archive(_ tasks: [BoardTask]) {
    let lines = tasks.compactMap { try? String(data: lineEncoder.encode($0), encoding: .utf8) }
    guard !lines.isEmpty else { return }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: archiveURL) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: archiveURL)
    }
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let lineEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
