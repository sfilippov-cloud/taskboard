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
    // The stand didn't answer: "live on test" is kept; a real "not deployed" clears it.
    board.refreshPullRequests(["o/r#1255": (title: "feat: AML screening", state: "merged", live: nil)])
    #expect(board.task(task.id)!.links[0].live == ["test"])
    board.refreshPullRequests(["o/r#1255": (title: "feat: AML screening", state: "merged", live: [])])
    #expect(board.task(task.id)!.links[0].live == nil)
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

@Suite struct DetectLinkTests {
  @Test func pullRequestsKeepRepoAndNumber() throws {
    let link = try #require(TaskLink.detect(url: " https://github.com/JetSetProjects/monorepo/pull/2314/files?w=1 "))
    #expect(link.kind == "pr" && link.repo == "JetSetProjects/monorepo" && link.number == 2314)
    #expect(link.url == "https://github.com/JetSetProjects/monorepo/pull/2314" && link.title == "JetSetProjects/monorepo#2314")
    #expect(link.identity == "JetSetProjects/monorepo#2314")  // the GitHub check recognises it
    #expect(TaskLink.detect(url: "https://github.com/o/r/pull/9", title: "AML")?.title == "AML")
  }

  @Test func commitsAndArtifacts() throws {
    let commit = try #require(TaskLink.detect(url: "https://github.com/o/r/commit/76b82e049a3fa63541cd8dc2bdc9435ad3efb4a1"))
    #expect(commit.kind == "commit" && commit.title == "o/r@76b82e0")
    let artifact = try #require(TaskLink.detect(url: "https://claude.ai/artifact/abc123"))
    #expect(artifact.kind == "artifact" && artifact.title == "Claude artifact")
  }

  @Test func otherLinksAreNamedByHostAndPath() throws {
    let doc = try #require(TaskLink.detect(url: "https://docs.google.com/document/d/1AbC/edit"))
    #expect(doc.kind == "link" && doc.title == "docs.google.com › edit")
    #expect(TaskLink.detect(url: "https://www.example.com")?.title == "example.com")
    #expect(TaskLink.detect(url: "https://example.com/a", title: "  Spec v2 ")?.title == "Spec v2")
  }

  @Test func onlyWebLinksPass() {
    for bad in ["", "   ", "not a link", "file:///etc/passwd", "javascript:alert(1)", "ftp://x.y/z", "https://", "mailto:a@b.c"] {
      #expect(TaskLink.detect(url: bad) == nil, "\(bad)")
    }
  }
}

@Suite struct SourceLinkTests {
  @Test func aSourceIsAnEmailOrSlackLinkNamedBySubject() throws {
    let email = try #require(TaskLink.source(kind: "email", title: "Re: Contract", url: "https://mail.google.com/mail/u/0/#all/18f3a"))
    #expect(email.kind == "email" && email.title == "Re: Contract")
    #expect(TaskLink.source(kind: "email", title: nil, url: "https://mail.google.com/x")?.title == "Email")
    #expect(TaskLink.source(kind: "slack", title: "#jssi: term sheet", url: "https://a.slack.com/archives/C1/p1")?.kind == "slack")
    #expect(TaskLink.source(kind: "github", title: "PR", url: "https://github.com/o/r/pull/5")?.kind == "pr")
    #expect(TaskLink.source(kind: "email", title: "x", url: "javascript:alert(1)") == nil)
  }

  @Test func aNewTaskFromAProposalShowsItsSourceInTheJournal() throws {
    var board = Board()
    let before = board
    let proposal = try board.proposeTask(
      ProposalDraft(title: "Reply to Mark", reason: "asked", sourceKind: "email", sourceTitle: "Re: Pricing", sourceLink: "https://x.y/1"))
    try board.acceptProposal(proposal.id)
    #expect(board.changes(since: before).map(\.text).contains("+ #1 Reply to Mark\nhttps://x.y/1"))
  }

  @Test func oldNotesLinksBecomeChipsOnce() throws {
    var board = Board()
    let task = board.add(
      title: "Old", notes: "Context line\n\nFrom email: Re: Contract\nhttps://mail.google.com/mail/u/0/#all/18f3a", source: "email")
    board.adoptLegacySourceLinks()
    let migrated = board.task(task.id)!
    #expect(migrated.links.count == 1 && migrated.links[0].kind == "email" && migrated.links[0].title == "Re: Contract")
    #expect(migrated.links[0].added == migrated.created)
    #expect(migrated.notes == "Context line\n\nFrom email: Re: Contract")
    var again = board
    again.adoptLegacySourceLinks()
    #expect(again == board)  // running it twice changes nothing
    // Notes that merely start like a source line, without a URL after them, are left alone.
    let plain = board.add(title: "Plain", notes: "From email: nothing follows", source: "manual")
    board.adoptLegacySourceLinks()
    #expect(board.task(plain.id)!.links.isEmpty && board.task(plain.id)!.notes == "From email: nothing follows")
  }
}
