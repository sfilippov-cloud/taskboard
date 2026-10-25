import Foundation
import Testing

@testable import TaskboardCore

@Suite struct ProjectsTests {
  @Test func slugIsSafeAndTransliterated() {
    #expect(Project.slug(for: "Платформа Wingform") == "platforma-wingform")
    #expect(Project.slug(for: "  ../../etc  ") == "etc")
    #expect(Project.slug(for: "!!!") == "project")
  }

  @Test func addAndResolveLoosely() throws {
    var board = Board()
    let project = try board.addProject(name: "JetSet Backend")
    #expect(try board.resolveProject("jetset backend") == "JetSet Backend")
    #expect(try board.resolveProject("jetset-backend") == project.name)
    #expect(try board.resolveProject("  ") == nil)
    #expect(throws: BoardError.self) { try board.resolveProject("Другой") }
    #expect(throws: BoardError.self) { try board.addProject(name: "jetset backend") }
    #expect(throws: BoardError.self) { try board.addProject(name: "   ") }
  }

  @Test func sameSlugCountsAsSameProject() throws {
    var board = Board()
    let first = try board.addProject(name: "A B")
    #expect(first.slug == "a-b")
    #expect(throws: BoardError.self) { try board.addProject(name: "A-B") }
    #expect(board.projects.count == 1)
  }

  @Test func renameCarriesTasksAlong() throws {
    var board = Board()
    let project = try board.addProject(name: "Старое")
    board.add(title: "Задача", project: "Старое", source: "manual")
    try board.updateProject(project.slug, name: "Новое", status: .paused)
    #expect(board.tasks[0].project == "Новое")
    #expect(board.projects[0].slug == project.slug)
    #expect(board.projects[0].status == .paused)
    #expect(board.activeProjects.count == 1)
  }

  @Test func oldBoardsAdoptTheirProjects() throws {
    let json = """
      {"nextID": 3, "tasks": [
        {"id": 1, "title": "a", "project": "infra", "priority": "normal", "column": "todo", "source": "voice",
         "created": "2026-01-01T10:00:00Z", "updated": "2026-01-01T10:00:00Z"},
        {"id": 2, "title": "b", "project": "Infra", "priority": "normal", "column": "todo", "source": "voice",
         "created": "2026-01-02T10:00:00Z", "updated": "2026-01-02T10:00:00Z"}]}
      """
    var board = try BoardStore.decoder.decode(Board.self, from: Data(json.utf8))
    #expect(board.projects.isEmpty)
    board.adoptLegacyProjects()
    #expect(board.projects.map(\.name) == ["infra"])
    var again = board
    again.adoptLegacyProjects()
    #expect(again == board)
  }

  @Test func changesDescribeAddMoveDelete() throws {
    var board = Board()
    let kept = board.add(title: "Остаётся", source: "manual")
    let gone = board.add(title: "Уйдёт", source: "manual")
    let before = board
    board.add(title: "Новая", project: "P", source: "manual")
    _ = try board.update(kept.id) { $0.column = .done }
    _ = try board.remove(gone.id)
    let texts = board.changes(since: before).map(\.text)
    #expect(texts.contains("+ #3 Новая"))
    #expect(texts.contains("#1 Остаётся → Done"))
    #expect(texts.contains("− #2 Уйдёт deleted"))
  }
}

@Suite(.serialized) struct StoreOnDiskTests {
  func withTempStore(_ body: () throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taskboard-test-\(UUID().uuidString)")
    setenv("TASKBOARD_DIR", dir.path, 1)
    defer {
      unsetenv("TASKBOARD_DIR")
      try? FileManager.default.removeItem(at: dir)
    }
    try body()
  }

  @Test func journalFollowsBoardChanges() throws {
    try withTempStore {
      let project = try BoardStore.change(source: "voice") { try $0.addProject(name: "Бэкенд") }
      try BoardStore.change(source: "voice") { $0.add(title: "Починить", project: "Бэкенд", source: "voice") }
      try BoardStore.change(source: "manual") { board in _ = try board.update(1) { $0.column = .done } }
      try BoardStore.change(source: "manual") { $0.add(title: "Без проекта", source: "manual") }

      let entries = ProjectLog.entries(of: project)
      #expect(entries.map(\.text) == ["#1 Починить → Done", "+ #1 Починить"])
      #expect(entries.map(\.source) == ["manual", "voice"])
      #expect(ProjectLog.entries(of: nil).map(\.text) == ["+ #2 Без проекта"])
      #expect(ProjectLog.allEntries(projects: [project]).count == 3)
    }
  }

  @Test func multilineEntriesRoundTrip() throws {
    try withTempStore {
      let project = Project(slug: "p", name: "P")
      ProjectLog.append("Итоги встречи\n- решили A\n- решили B", source: "claude", project: project)
      ProjectLog.append("Второе · с разделителем", source: "claude", project: project)
      let entries = ProjectLog.entries(of: project)
      #expect(entries.count == 2)
      #expect(entries[0].text == "Второе · с разделителем")
      #expect(entries[1].text == "Итоги встречи\n- решили A\n- решили B")
    }
  }

  @Test func documentsAttachFileAndExtract() throws {
    try withTempStore {
      let source = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).md")
      try "Решили перенести релиз".write(to: source, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: source) }

      let inbox = try ProjectDocuments.attach(source, slug: nil)
      #expect(inbox.deletingLastPathComponent().lastPathComponent == "inbox")
      #expect(try ProjectDocuments.extractText(inbox) == "Решили перенести релиз")

      let filed = try ProjectDocuments.file(inboxName: inbox.lastPathComponent, into: "p")
      #expect(ProjectDocuments.list(slug: nil).isEmpty)
      #expect(ProjectDocuments.list(slug: "p").map(\.lastPathComponent) == [filed.lastPathComponent])

      let note = try ProjectDocuments.saveNote("Созвон с клиентом\nдетали", slug: "p")
      #expect(note.lastPathComponent.hasSuffix("Созвон с клиентом.md"))
      #expect(ProjectDocuments.list(slug: "p").count == 2)
    }
  }

  @Test func documentNamesCannotEscapeTheFolder() throws {
    try withTempStore {
      #expect(throws: DocumentError.self) { try ProjectDocuments.resolve("../board.json", slug: nil) }
      #expect(throws: DocumentError.self) { try ProjectDocuments.resolve(".lock", slug: nil) }
      #expect(throws: DocumentError.self) { try ProjectDocuments.file(inboxName: "../x", into: "p") }
    }
  }

  @Test func unsupportedFormatIsReported() throws {
    try withTempStore {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString).png")
      try Data([1, 2, 3]).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(throws: DocumentError.self) { try ProjectDocuments.extractText(url) }
    }
  }
}
