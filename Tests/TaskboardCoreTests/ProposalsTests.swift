import Foundation
import Testing

@testable import TaskboardCore

@Suite struct ProposalsTests {
  func draft(_ title: String = "Send the contract", ref: String? = "t1") -> ProposalDraft {
    ProposalDraft(
      title: title, reason: "They asked for it by Friday", sourceKind: "email", sourceRef: ref,
      sourceTitle: "Re: Contract", sourceLink: "https://mail.google.com/mail/u/0/#all/t1")
  }

  @Test func proposeAcceptAddsTaskWithEvidence() throws {
    var board = Board()
    try board.addProject(name: "JSSI")
    let proposal = try board.proposeTask(
      ProposalDraft(title: "Send the contract", project: "jssi", reason: "asked", sourceKind: "email", sourceTitle: "Re: Contract",
        sourceLink: "https://x/1"))
    #expect(board.proposals.count == 1 && proposal.project == "JSSI")
    let task = try #require(try board.acceptProposal(proposal.id))
    #expect(board.proposals.isEmpty)
    #expect(task.source == "email" && task.project == "JSSI")
    #expect(task.notes == "From email: Re: Contract")
    #expect(task.links.map(\.kind) == ["email"] && task.links[0].title == "Re: Contract" && task.links[0].url == "https://x/1")
  }

  @Test func duplicatesAreRefused() throws {
    var board = Board()
    board.add(title: "Send the contract", source: "manual")
    #expect(throws: BoardError.self) { try board.proposeTask(draft()) }  // an open task has this title
    try board.proposeTask(draft("Call Oleg"))
    #expect(throws: BoardError.self) { try board.proposeTask(draft("  call   OLEG ")) }  // already waiting
  }

  @Test func rejectedIsRemembered() throws {
    var board = Board()
    let proposal = try board.proposeTask(draft("Call Oleg"))
    try board.rejectProposal(proposal.id)
    #expect(board.proposals.isEmpty)
    #expect(throws: BoardError.self) { try board.proposeTask(draft("Call Oleg")) }
    #expect(throws: BoardError.self) { try board.rejectProposal(99) }
  }

  @Test func moveProposalAppliesAndChecksTask() throws {
    var board = Board()
    let task = board.add(title: "Prepare the demo", source: "manual")
    #expect(throws: BoardError.self) { try board.proposeMove(task.id, to: .todo, draft()) }  // already there
    #expect(throws: BoardError.self) { try board.proposeMove(42, to: .done, draft()) }
    let proposal = try board.proposeMove(task.id, to: .done, draft())
    #expect(board.line(proposal) == "#1 → Done: Prepare the demo")
    try board.acceptProposal(proposal.id)
    #expect(board.task(task.id)?.column == .done)

    // The task disappears before the user answers: accepting is harmless.
    let other = board.add(title: "Other", source: "manual")
    let second = try board.proposeMove(other.id, to: .doing, draft())
    _ = try board.remove(other.id)
    #expect(try board.acceptProposal(second.id) == nil)
  }

  @Test func unknownProjectIsRejected() throws {
    var board = Board()
    #expect(throws: BoardError.self) {
      try board.proposeTask(ProposalDraft(title: "X", project: "Nope", reason: "r", sourceKind: "email"))
    }
  }

  @Test func oldBoardsHaveNoProposals() throws {
    let json = #"{"nextID":1,"tasks":[]}"#
    let board = try BoardStore.decoder.decode(Board.self, from: Data(json.utf8))
    #expect(board.proposals.isEmpty && board.nextProposalID == 1 && board.dismissedProposals.isEmpty)
  }

  @Test func syncStateKeepsNewestAndPrunes() {
    var state = SyncState()
    let now = Date()
    state.record(thread: "a", lastMessage: now)
    state.record(thread: "a", lastMessage: now.addingTimeInterval(-3600))  // older: ignored
    #expect(state.threads["a"] == now)
    state.record(thread: "old", lastMessage: now.addingTimeInterval(-20 * 86400))
    state.prune(now: now)
    #expect(Set(state.threads.keys) == ["a"])
    #expect(SyncStore.parseDate("2026-10-25T10:00:00Z") != nil)
    #expect(SyncStore.parseDate("2026-10-25") != nil)
    #expect(SyncStore.parseDate("yesterday") == nil)
  }
}

@Suite struct ProposalsOnDiskTests {
  @Test func acceptedProposalLandsInTheJournal() throws {
    try withTempStore {
      let project = try BoardStore.change(source: "email") { try $0.addProject(name: "JSSI") }
      let id = try BoardStore.change(source: "email") {
        try $0.proposeTask(ProposalDraft(title: "Reply to Mark", project: "JSSI", reason: "asked", sourceKind: "email")).id
      }
      #expect(ProjectLog.entries(of: project).isEmpty)  // a proposal alone writes nothing
      try BoardStore.change(source: "email") { try $0.acceptProposal(id) }
      #expect(ProjectLog.entries(of: project).map(\.text) == ["+ #1 Reply to Mark"])
      #expect(ProjectLog.entries(of: project).first?.source == "email")

      try SyncStore.change { $0.record(thread: "t", lastMessage: Date()) }
      #expect(SyncStore.load().threads.keys.contains("t"))
    }
  }
}

@Suite struct CheckOutputTests {
  @Test func lastLineIsTheSummaryTheRestIsTheReport() {
    let output = CheckOutput("""
      REPORT
      - #jssi | 4 new | journal

      Not covered: none

      Checked 2 conversations: 0 proposals, 1 journal entry.

      """)
    #expect(output.summary == "Checked 2 conversations: 0 proposals, 1 journal entry.")
    #expect(output.report == "REPORT\n- #jssi | 4 new | journal\n\nNot covered: none")
  }

  @Test func aLoneLineHasNoReport() {
    #expect(CheckOutput("Checked 0 threads.").report == nil)
    #expect(CheckOutput("").summary == "")
  }

  @Test func reportsRoundTripAndOldStateHasNone() throws {
    var state = SyncState()
    state.reports = ["slack": "x"]
    let data = try BoardStore.encoder.encode(state)
    #expect(try BoardStore.decoder.decode(SyncState.self, from: data).reports?["slack"] == "x")
    let old = #"{"threads":{}}"#
    #expect(try BoardStore.decoder.decode(SyncState.self, from: Data(old.utf8)).reports == nil)
  }
}
