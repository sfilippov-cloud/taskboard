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

@Suite struct MailRefTests {
  @Test func prefixesAreStrippedFromTheSubject() {
    #expect(MailRef(subject: "Re: Re: Fwd: JSSI pricing").coreSubject == "JSSI pricing")
    #expect(MailRef(subject: "RE[2]: Contract").coreSubject == "Contract")
    #expect(MailRef(subject: "Ответ: Договор").coreSubject == "Договор")
    #expect(MailRef(subject: "Revenue report").coreSubject == "Revenue report")  // "Re" inside a word stays
    #expect(MailRef(subject: "  Fw:   spaced  ").coreSubject == "spaced")
  }

  @Test func theSenderAddressIsPulledOut() {
    #expect(MailRef(subject: "s", from: "Dana Smith <Dana@Acme.com>").fromAddress == "dana@acme.com")
    #expect(MailRef(subject: "s", from: "dana@acme.com").fromAddress == "dana@acme.com")
    #expect(MailRef(subject: "s", from: "Dana").fromAddress == nil)
    #expect(MailRef(subject: "s").fromAddress == nil)
  }

  @Test func theMailDetailsTravelFromProposalToLinkAndUpdate() throws {
    var board = Board()
    let date = Date(timeIntervalSince1970: 1_792_000_000)
    let mail = MailRef(subject: "Re: Pricing", from: "Dana <dana@acme.com>", date: date)
    let proposal = try board.proposeTask(
      ProposalDraft(title: "Reply to Dana", reason: "asked", sourceKind: "email", sourceTitle: "Re: Pricing", sourceLink: "https://x.y/1", mail: mail))
    let task = try #require(try board.acceptProposal(proposal.id))
    #expect(task.links.first?.mail == mail)
    // An update keeps its own reference.
    try board.addUpdate(task.id, text: "Dana moved the deadline", source: "email", link: "https://x.y/2", mail: mail)
    #expect(board.task(task.id)!.updates[0].mail == mail)
    // Without details, an email link still knows its subject: Mail can be searched by that.
    let bare = try board.proposeTask(
      ProposalDraft(title: "Other", reason: "r", sourceKind: "email", sourceTitle: "Subject only", sourceLink: "https://x.y/3"))
    let other = try #require(try board.acceptProposal(bare.id))
    #expect(other.links.first?.mail == MailRef(subject: "Subject only"))
    // Slack links carry no mail reference.
    let slack = TaskLink.source(kind: "slack", title: "#jssi: x", url: "https://a.slack.com/archives/C1/p1", mail: mail)
    #expect(slack?.mail == nil)
  }

  @Test func oldTasksAndLinksDecodeWithoutMail() throws {
    let link = #"{"kind":"email","title":"x","url":"https://x.y","added":"2026-10-01T10:00:00Z"}"#
    #expect(try BoardStore.decoder.decode(TaskLink.self, from: Data(link.utf8)).mail == nil)
    let update = #"{"id":"1","date":"2026-10-01T10:00:00Z","source":"email","text":"t"}"#
    #expect(try BoardStore.decoder.decode(TaskUpdate.self, from: Data(update.utf8)).mail == nil)
  }
}

@Suite struct MailURLTests {
  @Test func messageIDsBecomeMailURLs() {
    #expect(MailRef.messageURL(forMessageID: "CAF+abc=@mail.gmail.com")?.absoluteString == "message://%3CCAF%2Babc%3D%40mail.gmail.com%3E")
    #expect(MailRef.messageURL(forMessageID: "<x@y.z>\n")?.absoluteString == "message://%3Cx%40y.z%3E")  // brackets and whitespace dropped
    #expect(MailRef.messageURL(forMessageID: "  <> ") == nil)
  }
}

@Suite struct MailReferenceMigrationTests {
  @Test func oldEmailChipsGetTheirSubjectAsAReference() throws {
    var board = Board()
    let task = board.add(title: "T", source: "email")
    try board.attach(TaskLink(kind: "email", title: "Re: Pricing", url: "https://mail.google.com/x/1"), to: task.id)
    try board.attach(TaskLink(kind: "email", title: "Email", url: "https://mail.google.com/x/2"), to: task.id)  // no subject known
    try board.attach(TaskLink(kind: "slack", title: "#jssi", url: "https://a.slack.com/p1"), to: task.id)
    board.adoptMailReferences()
    let links = board.task(task.id)!.links
    #expect(links[0].mail == MailRef(subject: "Re: Pricing"))
    #expect(links[1].mail == nil && links[2].mail == nil)
    var again = board
    again.adoptMailReferences()
    #expect(again == board)
  }
}
