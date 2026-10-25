// The journal: an append-only Markdown file per project (projects/<slug>/log.md); entries without a project
// go to log.md in the data folder. One entry is "- 2026-10-25 14:03 · source · text", extra lines are indented.
import Foundation

public struct LogEntry: Equatable, Sendable {
  public var date: Date
  public var source: String
  public var text: String
  public var project: String?  // название проекта; nil — общий журнал

  public init(date: Date, source: String, text: String, project: String? = nil) {
    self.date = date
    self.source = source
    self.text = text
    self.project = project
  }
}

public enum ProjectLog {
  static let separator = " · "

  public static var projectsDirectory: URL { BoardStore.directory.appendingPathComponent("projects", isDirectory: true) }

  public static func directory(slug: String?) -> URL {
    slug.map { projectsDirectory.appendingPathComponent($0, isDirectory: true) } ?? BoardStore.directory
  }

  public static func logURL(slug: String?) -> URL { directory(slug: slug).appendingPathComponent("log.md") }

  // Callers that change the board hold the store lock; a lone append is a single small write.
  public static func append(_ text: String, source: String, project: Project?, date: Date = Date()) {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    let url = logURL(slug: project?.slug)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = body.components(separatedBy: "\n")
    var entry = "- " + stamp(date) + separator + source + separator + lines[0]
    for line in lines.dropFirst() { entry += "\n  " + line }
    var data = Data()
    if !FileManager.default.fileExists(atPath: url.path) {
      data.append(Data("# Журнал: \(project?.name ?? "общий")\n\n".utf8))
    }
    data.append(Data((entry + "\n").utf8))
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  // Newest first.
  public static func entries(of project: Project?, limit: Int? = nil) -> [LogEntry] {
    guard let content = try? String(contentsOf: logURL(slug: project?.slug), encoding: .utf8) else { return [] }
    let parsed = parse(content).map { entry -> LogEntry in
      var entry = entry
      entry.project = project?.name
      return entry
    }
    let sorted = Array(parsed.reversed())
    return limit.map { Array(sorted.prefix($0)) } ?? sorted
  }

  // Every journal (projects and the general one) merged, newest first.
  public static func allEntries(projects: [Project], limit: Int? = nil) -> [LogEntry] {
    let all = (projects.map(Optional.some) + [nil]).flatMap { entries(of: $0) }
    let sorted = all.sorted { $0.date > $1.date }
    return limit.map { Array(sorted.prefix($0)) } ?? sorted
  }

  static func parse(_ content: String) -> [LogEntry] {
    var result: [LogEntry] = []
    for line in content.components(separatedBy: "\n") {
      if line.hasPrefix("- "), let entry = parseHead(String(line.dropFirst(2))) {
        result.append(entry)
      } else if line.hasPrefix("  "), !result.isEmpty {
        result[result.count - 1].text += "\n" + line.dropFirst(2)
      }
    }
    return result
  }

  private static func parseHead(_ head: String) -> LogEntry? {
    let parts = head.components(separatedBy: separator)
    guard parts.count >= 3, let date = formatter.date(from: parts[0]) else { return nil }
    return LogEntry(date: date, source: parts[1], text: parts.dropFirst(2).joined(separator: separator))
  }

  public static func stamp(_ date: Date) -> String { formatter.string(from: date) }

  nonisolated(unsafe) private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()
}
