// The kanban: tasks in three columns, stored as one JSON file shared by the app and the MCP server.
import Foundation

public enum Column: String, Codable, CaseIterable, Sendable {
  case todo, doing, done

  public var title: String {
    switch self {
    case .todo: "Сделать"
    case .doing: "В работе"
    case .done: "Готово"
    }
  }

  // Accepts the raw value or the Russian title ("в работе").
  public init?(loose value: String) {
    let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
    guard let match = Column.allCases.first(where: { $0.rawValue == normalized || $0.title.lowercased() == normalized })
    else { return nil }
    self = match
  }
}

public enum Priority: String, Codable, CaseIterable, Sendable {
  case low, normal, high
}

public struct BoardTask: Codable, Identifiable, Equatable, Sendable {
  public var id: Int
  public var title: String
  public var notes: String?
  public var project: String?
  public var priority: Priority
  public var column: Column
  public var source: String  // voice, claude, manual
  public var created: Date
  public var updated: Date

  public init(
    id: Int, title: String, notes: String? = nil, project: String? = nil, priority: Priority = .normal,
    column: Column = .todo, source: String, created: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.project = project
    self.priority = priority
    self.column = column
    self.source = source
    self.created = created
    self.updated = created
  }
}

public struct Board: Codable, Equatable, Sendable {
  public var nextID = 1
  public var tasks: [BoardTask] = []

  public init() {}

  public func tasks(in column: Column) -> [BoardTask] {
    tasks.filter { $0.column == column }.sorted { lhs, rhs in
      if lhs.column == .done { return lhs.updated > rhs.updated }
      if lhs.priority != rhs.priority { return lhs.priority.rank > rhs.priority.rank }
      return lhs.created < rhs.created
    }
  }

  @discardableResult
  public mutating func add(
    title: String, notes: String? = nil, project: String? = nil, priority: Priority = .normal,
    column: Column = .todo, source: String
  ) -> BoardTask {
    let task = BoardTask(
      id: nextID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes.nonEmpty,
      project: project.nonEmpty, priority: priority, column: column, source: source)
    nextID += 1
    tasks.append(task)
    return task
  }

  public mutating func update(_ id: Int, _ change: (inout BoardTask) -> Void) throws -> BoardTask {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    change(&tasks[index])
    tasks[index].updated = Date()
    return tasks[index]
  }

  public mutating func remove(_ id: Int) throws -> BoardTask {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    return tasks.remove(at: index)
  }

  // Done tasks older than a week leave the board; they stay in the archive file.
  public mutating func takeStaleDone(olderThan days: Int = 7, now: Date = Date()) -> [BoardTask] {
    let cutoff = now.addingTimeInterval(-Double(days) * 86400)
    let stale = tasks.filter { $0.column == .done && $0.updated < cutoff }
    tasks.removeAll { $0.column == .done && $0.updated < cutoff }
    return stale
  }
}

public enum BoardError: LocalizedError {
  case noTask(Int)

  public var errorDescription: String? {
    switch self {
    case .noTask(let id): "Задачи #\(id) нет на доске"
    }
  }
}

extension Priority {
  var rank: Int {
    switch self {
    case .low: 0
    case .normal: 1
    case .high: 2
    }
  }
}

extension Optional where Wrapped == String {
  var nonEmpty: String? {
    guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
}
