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

  public var id: String { slug }

  public init(slug: String, name: String, summary: String? = nil, status: ProjectStatus = .active, created: Date = Date()) {
    self.slug = slug
    self.name = name
    self.summary = summary
    self.status = status
    self.created = created
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

  // Переименование меняет имя и у задач проекта; папка (slug) остаётся.
  @discardableResult
  public mutating func updateProject(
    _ slug: String, name: String? = nil, summary: String? = nil, status: ProjectStatus? = nil
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
    var result: [(String?, String)] = []
    let old = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
    let current = Set(tasks.map(\.id))
    for task in tasks {
      if let previous = old[task.id] {
        if previous.column != task.column { result.append((task.project, "#\(task.id) \(task.title) → \(task.column.title)")) }
      } else {
        result.append((task.project, "+ #\(task.id) \(task.title)"))
      }
    }
    for task in before.tasks where !current.contains(task.id) {
      result.append((task.project, "− #\(task.id) \(task.title) deleted"))
    }
    return result
  }
}
