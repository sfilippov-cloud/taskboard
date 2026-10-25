import Foundation
import Testing

@testable import TaskboardCore

@Suite struct UpdatesTests {
  @Test func updatesAreAddedOnceAndLeaveUpdatedAlone() throws {
    var board = Board()
    let task = board.add(title: "Send the term sheet", source: "manual")
    let updated = board.task(task.id)!.updated
    #expect(try board.addUpdate(task.id, text: "  Dana moved the deadline to Friday ", source: "email", link: "https://x.y/1"))
    #expect(try board.addUpdate(task.id, text: "dana moved   the DEADLINE to friday", source: "slack") == false)  // same news
    let stored = board.task(task.id)!
    #expect(stored.updates.count == 1 && stored.updates[0].text == "Dana moved the deadline to Friday")
    #expect(stored.updated == updated)
    #expect(throws: BoardError.self) { try board.addUpdate(99, text: "x", source: "email") }
    #expect(throws: BoardError.self) { try board.addUpdate(task.id, text: "  ", source: "email") }
    #expect(throws: BoardError.self) { try board.addUpdate(task.id, text: "ok", source: "email", link: "file:///etc/passwd") }
    try board.removeUpdate(stored.updates[0].id, from: task.id)
    #expect(board.task(task.id)!.updates.isEmpty)
  }

  @Test func theNewestHundredAreKept() throws {
    var board = Board()
    let task = board.add(title: "T", source: "manual")
    for n in 1...105 { try board.addUpdate(task.id, text: "news \(n)", source: "email") }
    let updates = board.task(task.id)!.updates
    #expect(updates.count == 100 && updates.first?.text == "news 6" && updates.last?.text == "news 105")
  }

  @Test func anUpdateIsJournaledWithTheTaskNumberAndLink() throws {
    var board = Board()
    let task = board.add(title: "Term sheet", source: "manual")
    let before = board
    try board.addUpdate(task.id, text: "Dana moved the deadline to Friday", source: "email", link: "https://x.y/1")
    #expect(board.changes(since: before).map(\.text) == ["#1 Term sheet: Dana moved the deadline to Friday\nhttps://x.y/1"])
    let again = board
    try board.addUpdate(task.id, text: "Dana moved the deadline to Friday", source: "email")  // repeat: nothing new
    #expect(board.changes(since: again).isEmpty)
  }

  @Test func detailsListTheLatestFirst() throws {
    var board = Board()
    let task = board.add(title: "T", source: "manual")
    try board.addUpdate(task.id, text: "alpha news", source: "email", date: Date().addingTimeInterval(-3600))
    try board.addUpdate(task.id, text: "beta news", source: "slack")
    let details = try board.details(task.id)
    let first = try #require(details.range(of: "alpha news")), second = try #require(details.range(of: "beta news"))
    #expect(second.lowerBound < first.lowerBound && details.contains("Updates (newest first)"))
  }

  @Test func oldTasksHaveNoUpdates() throws {
    let json = #"{"id":1,"title":"x","priority":"normal","column":"todo","source":"manual","created":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z"}"#
    #expect(try BoardStore.decoder.decode(BoardTask.self, from: Data(json.utf8)).updates.isEmpty)
  }
}

@Suite struct OwnerTests {
  @Test func aProposalForSomeoneElseKeepsItsOwnerThroughAccept() throws {
    var board = Board()
    let draft = ProposalDraft(
      title: "Update the API docs", owner: "  Maria ", reason: "Maria said she would, no date", sourceKind: "email")
    let proposal = try board.proposeTask(draft)
    #expect(proposal.owner == "Maria" && board.line(proposal) == "+ Update the API docs — Maria")
    let mine = try board.proposeTask(ProposalDraft(title: "Send the contract", owner: "me", reason: "asked", sourceKind: "email"))
    #expect(board.line(mine) == "+ Send the contract — you")
    let task = try #require(try board.acceptProposal(proposal.id))
    #expect(task.owner == "Maria")
    #expect(try board.proposeTask(ProposalDraft(title: "No owner", reason: "r", sourceKind: "email")).owner == nil)
  }

  @Test func oldTasksHaveNoOwnerAndAddKeepsIt() throws {
    let json = #"{"id":1,"title":"x","priority":"normal","column":"todo","source":"manual","created":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z"}"#
    #expect(try BoardStore.decoder.decode(BoardTask.self, from: Data(json.utf8)).owner == nil)
    var board = Board()
    #expect(board.add(title: "T", owner: " Andrew ", source: "voice").owner == "Andrew")
    #expect(board.add(title: "U", owner: "  ", source: "voice").owner == nil)
  }
}
