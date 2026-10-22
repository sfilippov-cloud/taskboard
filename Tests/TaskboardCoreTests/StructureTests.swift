import Foundation
import Testing

@testable import TaskboardCore

@Suite struct StructureTests {
  // Переезд: БД → сервис → переключение трафика; документация параллельно.
  func plan() throws -> (Board, [String: Int]) {
    var board = Board()
    let created = try board.addPlan(
      [
        PlanItem(ref: "move", title: "Переезд", project: "infra"),
        PlanItem(ref: "db", title: "Поднять БД", parent: "move"),
        PlanItem(ref: "svc", title: "Развернуть сервис", parent: "move", dependsOn: ["db"]),
        PlanItem(ref: "dns", title: "Переключить DNS", parent: "move", dependsOn: ["svc"]),
        PlanItem(ref: "doc", title: "Описать", parent: "move"),
      ], source: "test")
    return (board, Dictionary(uniqueKeysWithValues: created.map { ($0.ref, $0.task.id) }))
  }

  @Test func readyAndBlocked() throws {
    var (board, id) = try plan()
    #expect(board.task(id["svc"]!)!.project == "infra")  // унаследовал от родителя
    #expect(Set(board.tasks.filter(board.isReady).map(\.id)) == [id["db"]!, id["doc"]!])
    #expect(board.isBlocked(board.task(id["dns"]!)!))
    _ = try board.update(id["db"]!) { $0.column = .done }
    #expect(board.unblocked(by: id["db"]!).map(\.id) == [id["svc"]!])
    #expect(board.progress(of: id["move"]!)! == (1, 4))
  }

  @Test func cyclesRejected() throws {
    var (board, id) = try plan()
    #expect(throws: BoardError.self) { try board.setDependencies(id["db"]!, [id["dns"]!]) }
    #expect(board.task(id["db"]!)!.dependsOn.isEmpty)  // откатилось
    #expect(throws: BoardError.self) { try board.setParent(id["move"]!, id["db"]!) }
    #expect(throws: BoardError.self) { try board.setDependencies(id["db"]!, [id["db"]!]) }
  }

  @Test func planIsValidatedAsAWhole() {
    var board = Board()
    #expect(throws: BoardError.self) {
      try board.addPlan([PlanItem(ref: "a", title: "A", dependsOn: ["b"]), PlanItem(ref: "b", title: "B", dependsOn: ["a"])], source: "test")
    }
    #expect(throws: BoardError.self) { try board.addPlan([PlanItem(ref: "a", title: "A", parent: "nope")], source: "test") }
  }

  @Test func removeDetaches() throws {
    var (board, id) = try plan()
    _ = try board.remove(id["svc"]!)
    #expect(board.task(id["dns"]!)!.dependsOn.isEmpty)
    _ = try board.remove(id["move"]!)
    #expect(board.task(id["db"]!)!.parent == nil)
  }

  @Test func oldBoardFilesStillLoad() throws {
    let json = #"{"nextID":2,"tasks":[{"id":1,"title":"Старая","priority":"normal","column":"todo","source":"manual","created":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z"}]}"#
    let board = try BoardStore.decoder.decode(Board.self, from: Data(json.utf8))
    #expect(board.tasks[0].dependsOn.isEmpty && board.tasks[0].parent == nil)
  }

  @Test func staleDoneParentWithOpenChildrenStays() throws {
    var (board, id) = try plan()
    let old = Date().addingTimeInterval(-30 * 86400)
    _ = try board.update(id["move"]!) { $0.column = .done }
    board.tasks[board.tasks.firstIndex { $0.id == id["move"]! }!].updated = old
    #expect(board.takeStaleDone().isEmpty)
  }
}
