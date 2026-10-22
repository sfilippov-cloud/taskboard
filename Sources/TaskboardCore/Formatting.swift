import Foundation

extension BoardTask {
  // "#12 [high] Поднять алерт на диск (infrastructure) — В работе"
  public var line: String {
    var line = "#\(id)"
    if priority != .normal { line += " [\(priority.rawValue)]" }
    line += " \(title)"
    if let project { line += " (\(project))" }
    line += " — \(column.title)"
    if let notes { line += "\n    " + notes.replacingOccurrences(of: "\n", with: "\n    ") }
    return line
  }
}

extension Board {
  public func listing(columns: [Column]) -> String {
    let sections = columns.map { column -> String in
      let tasks = self.tasks(in: column)
      let body = tasks.isEmpty ? "  —" : tasks.map { "  " + $0.line.replacingOccurrences(of: "\n", with: "\n  ") }
        .joined(separator: "\n")
      return "\(column.title) (\(column.rawValue)):\n\(body)"
    }
    return sections.joined(separator: "\n\n")
  }
}
