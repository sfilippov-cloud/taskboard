import Foundation
import Testing

@testable import TaskboardCore

@Suite struct BoardTests {
  @Test func addMoveAndOrder() throws {
    var board = Board()
    let first = board.add(title: "  Первая ", source: "manual")
    let urgent = board.add(title: "Срочная", priority: .high, source: "claude")
    #expect(first.title == "Первая")
    #expect(board.tasks(in: .todo).map(\.id) == [urgent.id, first.id])
    _ = try board.update(first.id) { $0.column = .doing }
    #expect(board.tasks(in: .doing).map(\.id) == [first.id])
    #expect(throws: BoardError.self) { try board.update(99) { _ in } }
  }

  @Test func staleDoneLeavesBoard() throws {
    var board = Board()
    let task = board.add(title: "Старая", column: .done, source: "manual")
    board.tasks[0].updated = Date().addingTimeInterval(-8 * 86400)
    #expect(board.takeStaleDone().map(\.id) == [task.id])
    #expect(board.tasks.isEmpty)
  }

  @Test func looseColumn() {
    #expect(Column(loose: "Doing") == .doing)
    #expect(Column(loose: "В работе") == .doing)  // titles from earlier versions
    #expect(Column(loose: "done") == .done)
    #expect(Column(loose: "later") == nil)
  }
}
