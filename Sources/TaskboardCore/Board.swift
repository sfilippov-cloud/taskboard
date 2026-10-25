// The kanban: tasks in three columns, stored as one JSON file shared by the app and the MCP server.
import Foundation

public enum Column: String, Codable, CaseIterable, Sendable {
  case todo, doing, done

  public var title: String {
    switch self {
    case .todo: "To do"
    case .doing: "Doing"
    case .done: "Done"
    }
  }

  // Accepts the raw value or the Russian title ("в работе").
  public init?(loose value: String) {
    let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
    // The Russian titles from earlier versions still work.
    let russian: [String: Column] = ["сделать": .todo, "в работе": .doing, "готово": .done]
    if let match = Column.allCases.first(where: { $0.rawValue == normalized || $0.title.lowercased() == normalized })
      ?? russian[normalized]
    {
      self = match
    } else {
      return nil
    }
  }
}

public enum Priority: String, Codable, CaseIterable, Sendable {
  case low, normal, high
}

// Something a task points to: a pull request, a commit, a Claude artifact, a document or any URL.
public struct TaskLink: Codable, Equatable, Hashable, Sendable {
  public var kind: String  // "pr", "commit", "artifact", "link"
  public var title: String
  public var url: String
  public var repo: String?  // "owner/name", for pull requests
  public var number: Int?  // pull request number
  public var state: String?  // pull request: "open", "merged", "closed"
  public var live: [String]?  // environments the pull request is deployed to, e.g. ["test"]
  public var added: Date

  public init(
    kind: String, title: String, url: String, repo: String? = nil, number: Int? = nil, state: String? = nil,
    live: [String]? = nil, added: Date = Date()
  ) {
    self.kind = kind
    self.title = title
    self.url = url
    self.repo = repo
    self.number = number
    self.state = state
    self.live = live
    self.added = added
  }

  // The same pull request may come as different URLs; repo + number is its identity.
  public var identity: String { (repo != nil && number != nil) ? "\(repo!)#\(number!)" : url }
}

// One piece of news about a task: what an email, a Slack message, a document or the user said about it.
public struct TaskUpdate: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var date: Date
  public var source: String  // email, slack, github, document, voice, manual, claude
  public var text: String
  public var link: String?  // where it comes from

  public init(text: String, source: String, link: String? = nil, date: Date = Date(), id: String = UUID().uuidString) {
    self.id = id
    self.date = date
    self.source = source
    self.text = text
    self.link = link
  }
}

public struct BoardTask: Codable, Identifiable, Equatable, Sendable {
  public var id: Int
  public var title: String
  public var notes: String?
  public var project: String?
  public var owner: String?  // who is responsible: a name, or "me"; nil when unknown
  public var priority: Priority
  public var column: Column
  public var source: String  // voice, claude, manual
  public var created: Date
  public var updated: Date
  public var parent: Int?  // подзадача этой задачи
  public var dependsOn: [Int]  // не начать, пока эти не готовы
  public var links: [TaskLink] = []
  public var updates: [TaskUpdate] = []  // oldest first; the card shows the last one

  public init(
    id: Int, title: String, notes: String? = nil, project: String? = nil, owner: String? = nil,
    priority: Priority = .normal, column: Column = .todo, source: String, created: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.project = project
    self.owner = owner
    self.priority = priority
    self.column = column
    self.source = source
    self.created = created
    self.updated = created
    self.dependsOn = []
  }

  enum CodingKeys: String, CodingKey {
    case id, title, notes, project, owner, priority, column, source, created, updated, parent, dependsOn, links, updates
  }

  // Доски из версий без структуры: parent и dependsOn отсутствуют.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    notes = try container.decodeIfPresent(String.self, forKey: .notes)
    project = try container.decodeIfPresent(String.self, forKey: .project)
    owner = try container.decodeIfPresent(String.self, forKey: .owner)
    priority = try container.decode(Priority.self, forKey: .priority)
    column = try container.decode(Column.self, forKey: .column)
    source = try container.decode(String.self, forKey: .source)
    created = try container.decode(Date.self, forKey: .created)
    updated = try container.decode(Date.self, forKey: .updated)
    parent = try container.decodeIfPresent(Int.self, forKey: .parent)
    dependsOn = try container.decodeIfPresent([Int].self, forKey: .dependsOn) ?? []
    links = try container.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
    updates = try container.decodeIfPresent([TaskUpdate].self, forKey: .updates) ?? []
  }
}

public struct Board: Codable, Equatable, Sendable {
  public var nextID = 1
  public var tasks: [BoardTask] = []
  public var projects: [Project] = []
  public var proposals: [Proposal] = []  // waiting for the user's yes/no
  public var nextProposalID = 1
  public var dismissedProposals: [String] = []  // keys of rejected proposals, so they don't come back

  public init() {}

  enum CodingKeys: String, CodingKey { case nextID, tasks, projects, proposals, nextProposalID, dismissedProposals }

  // Доски из версий без проектов: projects отсутствует.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nextID = try container.decodeIfPresent(Int.self, forKey: .nextID) ?? 1
    tasks = try container.decodeIfPresent([BoardTask].self, forKey: .tasks) ?? []
    projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    proposals = try container.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
    nextProposalID = try container.decodeIfPresent(Int.self, forKey: .nextProposalID) ?? 1
    dismissedProposals = try container.decodeIfPresent([String].self, forKey: .dismissedProposals) ?? []
  }

  public func tasks(in column: Column) -> [BoardTask] {
    tasks.filter { $0.column == column }.sorted { lhs, rhs in
      if lhs.column == .done { return lhs.updated > rhs.updated }
      if lhs.priority != rhs.priority { return lhs.priority.rank > rhs.priority.rank }
      return lhs.created < rhs.created
    }
  }

  @discardableResult
  public mutating func add(
    title: String, notes: String? = nil, project: String? = nil, owner: String? = nil, priority: Priority = .normal,
    column: Column = .todo, source: String
  ) -> BoardTask {
    let task = BoardTask(
      id: nextID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes.nonEmpty,
      project: project.nonEmpty, owner: owner.nonEmpty, priority: priority, column: column, source: source)
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
  case unknownProject(String, known: [String])
  case duplicateProject(String)
  case emptyName
  case noProposal(Int)
  case duplicateProposal(String)
  case badLink(String)

  public var errorDescription: String? {
    switch self {
    case .noTask(let id): "There is no task #\(id) on the board"
    case .selfReference(let id): "#\(id) cannot refer to itself"
    case .parentCycle(let id, let parent): "#\(parent) is a subtask of #\(id), so it cannot become its parent"
    case .dependencyCycle(let path): "Circular dependencies: " + path.map { "#\($0)" }.joined(separator: " → ")
    case .unknownRef(let ref): "Unknown reference “\(ref)”: use a ref from this plan or a task number (#12)"
    case .duplicateRef(let ref): "ref “\(ref)” appears twice in the plan"
    case .unknownProject(let name, let known):
      "There is no project “\(name)”. Known projects: " + (known.isEmpty ? "—" : known.joined(separator: ", "))
        + ". For a genuinely new project use create_project — only if the user really started a new one."
    case .duplicateProject(let name): "Project “\(name)” already exists"
    case .emptyName: "A name is required"
    case .noProposal(let id): "There is no proposal #\(id)"
    case .duplicateProposal(let why): "Not proposed: \(why)"
    case .badLink(let url): "“\(url)” is not an http(s) link"
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
  public var nonEmpty: String? {
    guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
}
