// Tree and dependencies: subtasks (parent) and "can't start until" links (dependsOn).
// A task is blocked while any task it depends on isn't done; one missing from the board (archived) counts as done.
import Foundation

extension Board {
  public func task(_ id: Int) -> BoardTask? { tasks.first { $0.id == id } }

  public func children(of id: Int) -> [BoardTask] { ordered(tasks.filter { $0.parent == id }) }

  // Open tasks this one is waiting for.
  public func waitingOn(_ task: BoardTask) -> [BoardTask] {
    task.dependsOn.compactMap { self.task($0) }.filter { $0.column != .done }
  }

  public func isBlocked(_ task: BoardTask) -> Bool { !waitingOn(task).isEmpty }

  // Tasks that depend on this one.
  public func dependents(of id: Int) -> [BoardTask] { ordered(tasks.filter { $0.dependsOn.contains(id) }) }

  // Can be taken right now: open, not blocked, and has no open subtasks (a parent is done through its subtasks).
  public func isReady(_ task: BoardTask) -> Bool {
    task.column != .done && !isBlocked(task) && !children(of: task.id).contains { $0.column != .done }
  }

  // (done, total) over subtasks.
  public func progress(of id: Int) -> (done: Int, total: Int)? {
    let children = tasks.filter { $0.parent == id }
    guard !children.isEmpty else { return nil }
    return (children.filter { $0.column == .done }.count, children.count)
  }

  public func ancestors(of id: Int) -> [BoardTask] {
    var result: [BoardTask] = []
    var current = task(id)?.parent
    while let parentID = current, let parent = task(parentID), !result.contains(where: { $0.id == parentID }) {
      result.append(parent)
      current = parent.parent
    }
    return result
  }

  // Waiting tasks that this one was the last blocker for — to report after it's done.
  public func unblocked(by id: Int) -> [BoardTask] {
    dependents(of: id).filter { $0.column != .done && !isBlocked($0) }
  }

  // MARK: - Changing the structure

  public mutating func setParent(_ id: Int, _ parent: Int?) throws {
    guard task(id) != nil else { throw BoardError.noTask(id) }
    if let parent {
      guard task(parent) != nil else { throw BoardError.noTask(parent) }
      guard parent != id else { throw BoardError.selfReference(id) }
      if ancestors(of: parent).contains(where: { $0.id == id }) { throw BoardError.parentCycle(id, parent) }
    }
    _ = try update(id) { $0.parent = parent }
  }

  public mutating func setDependencies(_ id: Int, _ dependencies: [Int]) throws {
    guard task(id) != nil else { throw BoardError.noTask(id) }
    var unique: [Int] = []
    for dependency in dependencies where !unique.contains(dependency) {
      guard dependency != id else { throw BoardError.selfReference(id) }
      guard task(dependency) != nil else { throw BoardError.noTask(dependency) }
      unique.append(dependency)
    }
    let previous = task(id)!.dependsOn
    _ = try update(id) { $0.dependsOn = unique }
    if let cycle = dependencyCycle(from: id) {
      _ = try update(id) { $0.dependsOn = previous }
      throw BoardError.dependencyCycle(cycle)
    }
  }

  // A path id → … → id through dependsOn, if there is one.
  func dependencyCycle(from start: Int) -> [Int]? {
    var visited = Set<Int>()
    func walk(_ id: Int, _ path: [Int]) -> [Int]? {
      for next in task(id)?.dependsOn ?? [] {
        if next == start { return path + [next] }
        if visited.insert(next).inserted, let found = walk(next, path + [next]) { return found }
      }
      return nil
    }
    return walk(start, [start])
  }

  // MARK: - Plans

  // A tree of new tasks with dependencies, created all at once; refs name tasks inside the plan,
  // "#12" or "12" point to tasks already on the board. Returns ref → created task.
  @discardableResult
  public mutating func addPlan(_ items: [PlanItem], source: String) throws -> [(ref: String, task: BoardTask)] {
    var refs = Set<String>()
    for item in items where !refs.insert(item.ref).inserted { throw BoardError.duplicateRef(item.ref) }

    var created: [(ref: String, task: BoardTask)] = []
    var ids: [String: Int] = [:]
    for item in items {
      let task = add(
        title: item.title, notes: item.notes, project: item.project, priority: item.priority, column: item.column,
        source: source)
      ids[item.ref] = task.id
      created.append((item.ref, task))
    }
    func resolve(_ ref: String) throws -> Int {
      if let id = ids[ref] { return id }
      if let id = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "# "))), task(id) != nil { return id }
      throw BoardError.unknownRef(ref)
    }
    for item in items {
      let id = ids[item.ref]!
      if let parent = item.parent {
        let parentID = try resolve(parent)
        try setParent(id, parentID)
        // Subtasks without their own project inherit the parent's.
        if task(id)?.project == nil, let project = task(parentID)?.project { _ = try update(id) { $0.project = project } }
      }
      if !item.dependsOn.isEmpty { try setDependencies(id, try item.dependsOn.map(resolve)) }
    }
    return created.map { ($0.ref, task($0.task.id)!) }
  }

  // MARK: - Ordering

  // Doing first, then ready, then blocked; inside — priority, then age.
  public func ordered(_ list: [BoardTask]) -> [BoardTask] {
    func rank(_ task: BoardTask) -> Int {
      switch task.column {
      case .doing: 0
      case .todo: isBlocked(task) ? 2 : 1
      case .done: 3
      }
    }
    return list.sorted { lhs, rhs in
      if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
      if lhs.priority != rhs.priority { return lhs.priority.rank > rhs.priority.rank }
      return lhs.created < rhs.created
    }
  }
}

public struct PlanItem: Sendable {
  public var ref: String
  public var title: String
  public var notes: String?
  public var project: String?
  public var priority: Priority
  public var column: Column
  public var parent: String?
  public var dependsOn: [String]

  public init(
    ref: String, title: String, notes: String? = nil, project: String? = nil, priority: Priority = .normal,
    column: Column = .todo, parent: String? = nil, dependsOn: [String] = []
  ) {
    self.ref = ref
    self.title = title
    self.notes = notes
    self.project = project
    self.priority = priority
    self.column = column
    self.parent = parent
    self.dependsOn = dependsOn
  }
}
