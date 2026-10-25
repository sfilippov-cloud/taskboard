import Foundation
import Testing

@testable import TaskboardCore

@Suite struct LinksTests {
  func pr(_ number: Int = 1255, state: String = "open") -> TaskLink {
    TaskLink(
      kind: "pr", title: "feat: AML screening", url: "https://github.com/o/r/pull/\(number)", repo: "o/r", number: number,
      state: state)
  }

  @Test func attachDedupesByIdentityAndChecksTheURL() throws {
    var board = Board()
    let task = board.add(title: "AML screening", source: "manual")
    #expect(try board.attach(pr(), to: task.id))
    #expect(try board.attach(pr(), to: task.id) == false)
    var again = pr()
    again.url = "https://github.com/o/r/pull/1255/files"  // same PR under another URL
    #expect(try board.attach(again, to: task.id) == false)
    #expect(throws: BoardError.self) { try board.attach(TaskLink(kind: "link", title: "x", url: "javascript:alert(1)"), to: task.id) }
    #expect(throws: BoardError.self) { try board.attach(pr(), to: 99) }
    #expect(board.isLinked("o/r#1255"))
    try board.removeLink(pr().url, from: task.id)
    #expect(!board.isLinked("o/r#1255"))
  }

  @Test func pullRequestStateFollowsGitHubWithoutTouchingUpdated() throws {
    var board = Board()
    let task = board.add(title: "T", source: "manual")
    try board.attach(pr(), to: task.id)
    let updated = board.task(task.id)!.updated
    board.refreshPullRequests(["o/r#1255": (title: "feat: AML screening", state: "merged", live: ["test"])])
    let link = board.task(task.id)!.links[0]
    #expect(link.state == "merged" && link.live == ["test"])
    #expect(board.task(task.id)!.updated == updated)
    board.refreshPullRequests(["o/r#1": (title: "other", state: "merged", live: [])])  // unrelated PR: nothing changes
    #expect(board.task(task.id)!.links[0].state == "merged")
  }

  @Test func linkChangesAreJournaled() throws {
    var board = Board()
    let task = board.add(title: "T", project: nil, source: "manual")
    var before = board
    try board.attach(pr(), to: task.id)
    #expect(board.changes(since: before).map(\.text) == ["#1 T: linked PR o/r#1255 “feat: AML screening”\nhttps://github.com/o/r/pull/1255"])
    before = board
    board.refreshPullRequests(["o/r#1255": (title: "feat: AML screening", state: "merged", live: [])])
    #expect(board.changes(since: before).map(\.text) == ["#1 T: PR o/r#1255 “feat: AML screening” is now merged"])
    before = board
    board.refreshPullRequests(["o/r#1255": (title: "feat: AML screening", state: "merged", live: ["test"])])
    #expect(board.changes(since: before).map(\.text) == ["#1 T: PR o/r#1255 “feat: AML screening” is live on test"])
  }

  @Test func linkProposalAttachesAndMoves() throws {
    var board = Board()
    let task = board.add(title: "AML screening", source: "manual")
    let draft = ProposalDraft(title: "", reason: "PR implements the task", sourceKind: "github", sourceRef: "o/r#1255")
    #expect(throws: BoardError.self) { try board.proposeLink(99, pr(), draft) }
    let proposal = try board.proposeLink(task.id, pr(state: "merged"), moveTo: .done, draft)
    #expect(board.line(proposal) == "PR o/r#1255 “feat: AML screening” → #1 AML screening · move to Done")
    #expect(throws: BoardError.self) { try board.proposeLink(task.id, pr(state: "merged"), moveTo: .done, draft) }  // waiting
    try board.acceptProposal(proposal.id)
    let linked = board.task(task.id)!
    #expect(linked.column == .done && linked.links.count == 1)
    #expect(throws: BoardError.self) { try board.proposeLink(task.id, pr(), draft) }  // already linked

    // Same column as now: no move is proposed with it.
    let other = board.add(title: "Other", source: "manual")
    let second = try board.proposeLink(other.id, pr(1300), moveTo: .todo, draft)
    #expect(second.column == nil)
    // Rejected links are not proposed again.
    try board.rejectProposal(second.id)
    #expect(throws: BoardError.self) { try board.proposeLink(other.id, pr(1300), draft) }
  }

  @Test func oldTasksHaveNoLinks() throws {
    let json = #"{"id":1,"title":"x","priority":"normal","column":"todo","source":"manual","created":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z"}"#
    #expect(try BoardStore.decoder.decode(BoardTask.self, from: Data(json.utf8)).links.isEmpty)
  }
}
