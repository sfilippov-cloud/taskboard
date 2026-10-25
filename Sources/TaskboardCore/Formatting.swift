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
  // "▶ #12 Название (project) [high] · ждёт #3, #5 · 2/4"
  public func summary(_ task: BoardTask, withNotes: Bool = false) -> String {
    let marker: String
    switch task.column {
    case .doing: marker = "▶"
    case .done: marker = "✓"
    case .todo:
      if isBlocked(task) {
        marker = "⛔"
      } else if children(of: task.id).contains(where: { $0.column != .done }) {
        marker = "□"  // group: done through its subtasks
      } else {
        marker = "○"
      }
    }
    var line = "\(marker) #\(task.id) \(task.title)"
    if let project = task.project { line += " (\(project))" }
    if let owner = task.owner { line += " — \(owner)" }
    if task.priority != .normal { line += " [\(task.priority.rawValue)]" }
    let waiting = waitingOn(task)
    if !waiting.isEmpty { line += " · waiting on " + waiting.map { "#\($0.id)" }.joined(separator: ", ") }
    if let progress = progress(of: task.id) { line += " · \(progress.done)/\(progress.total)" }
    if withNotes, let notes = task.notes { line += "\n    " + notes.replacingOccurrences(of: "\n", with: "\n    ") }
    return line
  }

  // The whole board as a tree. Done tasks are hidden unless asked for; a done task with open subtasks stays.
  public func tree(includeDone: Bool) -> String {
    let ids = Set(tasks.map(\.id))
    let roots = ordered(tasks.filter { $0.parent == nil || !ids.contains($0.parent!) })
    var lines: [String] = []
    func visible(_ task: BoardTask) -> Bool {
      includeDone || task.column != .done || children(of: task.id).contains(where: visible)
    }
    func walk(_ task: BoardTask, depth: Int) {
      guard visible(task) else { return }
      lines.append(String(repeating: "  ", count: depth) + summary(task))
      for child in children(of: task.id) { walk(child, depth: depth + 1) }
    }
    roots.forEach { walk($0, depth: 0) }
    guard !lines.isEmpty else { return "The board is empty." }
    return lines.joined(separator: "\n") + "\n\n▶ doing · ○ ready to take · ⛔ waiting on others · □ group, closes through its subtasks · ✓ done · n/m — subtasks done"
  }

  // What can be taken right now.
  public func readyListing() -> String {
    let ready = ordered(tasks.filter(isReady))
    guard !ready.isEmpty else { return "Nothing to take right now: everything is done or waiting on other tasks." }
    return ready.map { task in
      let path = ancestors(of: task.id).reversed().map(\.title).joined(separator: " › ")
      return summary(task) + (path.isEmpty ? "" : "\n    in “\(path)”")
    }.joined(separator: "\n")
  }

  // One task with everything around it.
  public func details(_ id: Int) throws -> String {
    guard let task = task(id) else { throw BoardError.noTask(id) }
    var lines = [summary(task, withNotes: true), "Column: \(task.column.title), source: \(task.source)"]
    let path = ancestors(of: id).reversed().map { "#\($0.id) \($0.title)" }
    if !path.isEmpty { lines.append("Part of: " + path.joined(separator: " › ")) }
    if !task.links.isEmpty {
      lines.append(
        "Links:\n"
          + task.links.map { link in
            "  " + link.label + (link.state.map { " [\($0)" + (link.live.map { ", live on " + $0.joined(separator: ", ") } ?? "") + "]" } ?? "")
              + " " + link.url
          }.joined(separator: "\n"))
    }
    if !task.updates.isEmpty {
      let recent = task.updates.suffix(10).reversed()
      lines.append(
        "Updates (newest first" + (task.updates.count > 10 ? ", last 10 of \(task.updates.count)" : "") + "):\n"
          + recent.map { "  \(ProjectLog.stamp($0.date)) · \($0.source) · " + $0.text.replacingOccurrences(of: "\n", with: " ") }
          .joined(separator: "\n"))
    }
    let children = children(of: id)
    if !children.isEmpty { lines.append("Subtasks:\n" + children.map { "  " + summary($0) }.joined(separator: "\n")) }
    let dependencies = task.dependsOn.compactMap { self.task($0) }
    if !dependencies.isEmpty {
      lines.append("Depends on:\n" + dependencies.map { "  " + summary($0) }.joined(separator: "\n"))
    }
    let dependents = dependents(of: id)
    if !dependents.isEmpty { lines.append("Waited on by:\n" + dependents.map { "  " + summary($0) }.joined(separator: "\n")) }
    return lines.joined(separator: "\n")
  }
}
