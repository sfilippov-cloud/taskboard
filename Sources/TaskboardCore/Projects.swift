// Projects: a registry inside board.json (tasks refer to a project by its name), plus a folder per project
// with the journal (log.md) and attached documents — see ProjectLog and ProjectDocuments.
import Foundation

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
  case active, paused, archived

  public var title: String {
    switch self {
    case .active: "Active"
    case .paused: "Paused"
    case .archived: "Archived"
    }
  }
}

public struct Project: Codable, Identifiable, Equatable, Hashable, Sendable {
  public var slug: String  // имя папки на диске; не меняется при переименовании
  public var name: String
  public var summary: String?
  public var status: ProjectStatus
  public var created: Date
  public var slackChannels: [String]  // channels the Slack check reads for this project ("#jssi" or a channel id)

  public var id: String { slug }

  public init(
    slug: String, name: String, summary: String? = nil, status: ProjectStatus = .active, created: Date = Date(),
    slackChannels: [String] = []
  ) {
    self.slug = slug
    self.name = name
    self.summary = summary
    self.status = status
    self.created = created
    self.slackChannels = slackChannels
  }

  enum CodingKeys: String, CodingKey { case slug, name, summary, status, created, slackChannels }

  // Projects saved before Slack channels existed have no such key.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    slug = try container.decode(String.self, forKey: .slug)
    name = try container.decode(String.self, forKey: .name)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    status = try container.decode(ProjectStatus.self, forKey: .status)
    created = try container.decode(Date.self, forKey: .created)
    slackChannels = try container.decodeIfPresent([String].self, forKey: .slackChannels) ?? []
  }

  // "#jssi, deals ,#jssi" → ["#jssi", "#deals"]: a leading # is added to names, ids (C0123…) are kept.
  public static func parseChannels(_ text: String) -> [String] {
    var result: [String] = []
    for part in text.components(separatedBy: CharacterSet(charactersIn: ",\n;")) {
      var item = part.trimmingCharacters(in: .whitespacesAndNewlines)
      if item.isEmpty { continue }
      let isID = item.count >= 9 && item.allSatisfy { $0.isUppercase || $0.isNumber } && "CGD".contains(item.first!)
      if !isID && !item.hasPrefix("#") { item = "#" + item }
      if !result.contains(item) { result.append(item) }
    }
    return result
  }
}

extension Project {
  // «Платформа Wingform» → "platforma-wingform": латиница, цифры и дефисы — безопасное имя папки.
  public static func slug(for name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    let plain = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    var slug = ""
    for scalar in plain.unicodeScalars {
      if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
        slug.unicodeScalars.append(scalar)
      } else if !slug.hasSuffix("-") {
        slug += "-"
      }
    }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "project" : slug
  }
}

extension Board {
  public func project(matching name: String) -> Project? {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let slug = Project.slug(for: name)
    return projects.first { $0.name.lowercased() == normalized || $0.slug == slug }
  }

  public func project(slug: String) -> Project? { projects.first { $0.slug == slug } }

  // Названия и slug'и, по которым проект находят (для списка «известных»).
  public var activeProjects: [Project] { projects.filter { $0.status != .archived } }

  // Каноническое имя проекта по тому, что написал пользователь или Claude; nil/пусто — без проекта.
  public func resolveProject(_ name: String?) throws -> String? {
    guard let name = name.nonEmpty else { return nil }
    guard let project = project(matching: name) else {
      throw BoardError.unknownProject(name, known: activeProjects.map(\.name))
    }
    return project.name
  }

  @discardableResult
  public mutating func addProject(name: String, summary: String? = nil, now: Date = Date()) throws -> Project {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw BoardError.emptyName }
    if project(matching: name) != nil { throw BoardError.duplicateProject(name) }
    var slug = Project.slug(for: name)
    var suffix = 2
    while projects.contains(where: { $0.slug == slug }) {
      slug = Project.slug(for: name) + "-\(suffix)"
      suffix += 1
    }
    let project = Project(slug: slug, name: name, summary: summary.nonEmpty, created: now)
    projects.append(project)
    return project
  }

  // Moves a task and all its subtasks to a project (nil — no project).
  @discardableResult
  public mutating func setProject(_ id: Int, _ name: String?) throws -> [BoardTask] {
    guard task(id) != nil else { throw BoardError.noTask(id) }
    let target = try resolveProject(name)
    var ids = [id]
    var queue = [id]
    while let next = queue.popLast() {
      for child in tasks where child.parent == next {
        ids.append(child.id)
        queue.append(child.id)
      }
    }
    for taskID in ids { _ = try update(taskID) { $0.project = target } }
    return ids.compactMap { task($0) }
  }

  // Переименование меняет имя и у задач проекта; папка (slug) остаётся.
  @discardableResult
  public mutating func updateProject(
    _ slug: String, name: String? = nil, summary: String? = nil, status: ProjectStatus? = nil,
    slackChannels: [String]? = nil
  ) throws -> Project {
    guard let index = projects.firstIndex(where: { $0.slug == slug }) else {
      throw BoardError.unknownProject(slug, known: activeProjects.map(\.name))
    }
    let old = projects[index].name
    if let name = name.nonEmpty, name != old {
      if let other = project(matching: name), other.slug != slug { throw BoardError.duplicateProject(name) }
      projects[index].name = name
      for i in tasks.indices where tasks[i].project == old { tasks[i].project = name }
    }
    if let summary { projects[index].summary = Optional(summary).nonEmpty }
    if let status { projects[index].status = status }
    if let slackChannels { projects[index].slackChannels = slackChannels }
    return projects[index]
  }

  // Доски из версий без проектов: названия из задач становятся проектами (дата — по самой ранней задаче,
  // чтобы результат не менялся от загрузки к загрузке).
  mutating func adoptLegacyProjects() {
    for task in tasks {
      guard let name = task.project, project(matching: name) == nil else { continue }
      let earliest = tasks.filter { $0.project == name }.map(\.created).min() ?? task.created
      _ = try? addProject(name: name, now: earliest)
    }
  }

  // Что изменилось в задачах после `before`: основа автоматического журнала.
  func changes(since before: Board) -> [(project: String?, text: String)] {
    var result: [(String?, String)] = linkChanges(since: before)
    let old = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
    let current = Set(tasks.map(\.id))
    for task in tasks {
      if let previous = old[task.id] {
        if previous.column != task.column { result.append((task.project, "#\(task.id) \(task.title) → \(task.column.title)")) }
        // A project change, but not a rename (same project under a new name) — noted in both journals.
        let from = previous.project.flatMap { before.project(matching: $0) }
        let to = task.project.flatMap { project(matching: $0) }
        if from?.slug != to?.slug {
          let text = "#\(task.id) \(task.title): moved from “\(from?.name ?? "No project")” to “\(to?.name ?? "No project")”"
          result.append((task.project, text))
          if let old = previous.project, to != nil || from != nil { result.append((old, text)) }
        }
      } else {
        // A task that comes with a source (an accepted proposal) shows it in the journal too.
        result.append((task.project, "+ #\(task.id) \(task.title)" + (task.links.first.map { "\n" + $0.url } ?? "")))
      }
    }
    for task in before.tasks where !current.contains(task.id) {
      result.append((task.project, "− #\(task.id) \(task.title) deleted"))
    }
    return result
  }
}
