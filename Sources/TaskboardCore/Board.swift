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
  public var parent: Int?  // подзадача этой задачи
  public var dependsOn: [Int]  // не начать, пока эти не готовы

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
    self.dependsOn = []
  }

  enum CodingKeys: String, CodingKey {
    case id, title, notes, project, priority, column, source, created, updated, parent, dependsOn
  }

  // Доски из версий без структуры: parent и dependsOn отсутствуют.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    notes = try container.decodeIfPresent(String.self, forKey: .notes)
    project = try container.decodeIfPresent(String.self, forKey: .project)
    priority = try container.decode(Priority.self, forKey: .priority)
    column = try container.decode(Column.self, forKey: .column)
    source = try container.decode(String.self, forKey: .source)
    created = try container.decode(Date.self, forKey: .created)
    updated = try container.decode(Date.self, forKey: .updated)
    parent = try container.decodeIfPresent(Int.self, forKey: .parent)
    dependsOn = try container.decodeIfPresent([Int].self, forKey: .dependsOn) ?? []
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

  // Подзадачи поднимаются к родителю удалённой, ссылки на неё из зависимостей убираются.
  public mutating func remove(_ id: Int) throws -> BoardTask {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    let removed = tasks.remove(at: index)
    for i in tasks.indices {
      if tasks[i].parent == id { tasks[i].parent = removed.parent }
      tasks[i].dependsOn.removeAll { $0 == id }
    }
    return removed
  }

  // Done tasks older than a week leave the board; they stay in the archive file.
  // A done task whose subtasks are still open stays, so the tree doesn't fall apart.
  public mutating func takeStaleDone(olderThan days: Int = 7, now: Date = Date()) -> [BoardTask] {
    let cutoff = now.addingTimeInterval(-Double(days) * 86400)
    let openParents = Set(tasks.filter { $0.column != .done }.compactMap(\.parent))
    let isStale = { (task: BoardTask) in task.column == .done && task.updated < cutoff && !openParents.contains(task.id) }
    let stale = tasks.filter(isStale)
    tasks.removeAll(where: isStale)
    return stale
  }
}

public enum BoardError: LocalizedError {
  case noTask(Int)
  case selfReference(Int)
  case parentCycle(Int, Int)
  case dependencyCycle([Int])
  case unknownRef(String)
  case duplicateRef(String)

  public var errorDescription: String? {
    switch self {
    case .noTask(let id): "Задачи #\(id) нет на доске"
    case .selfReference(let id): "#\(id) не может ссылаться на саму себя"
    case .parentCycle(let id, let parent): "#\(parent) — подзадача #\(id), сделать её родителем нельзя"
    case .dependencyCycle(let path): "Зависимости по кругу: " + path.map { "#\($0)" }.joined(separator: " → ")
    case .unknownRef(let ref): "Неизвестная ссылка «\(ref)»: нужен ref из этого плана или номер задачи (#12)"
    case .duplicateRef(let ref): "ref «\(ref)» повторяется в плане"
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
