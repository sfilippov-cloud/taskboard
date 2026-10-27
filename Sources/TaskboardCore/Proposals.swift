// The proposals queue: things an assistant run (email sync) noticed but must not decide on its own.
// A proposal waits in board.json until the user accepts it (it is applied and journaled) or rejects it
// (it is dropped and remembered, so the same thing isn't proposed again).
import Foundation

public enum ProposalKind: String, Codable, Sendable {
  case addTask, moveTask, linkTask  // linkTask: attach a link (a pull request), optionally moving the task too
}

public struct Proposal: Codable, Identifiable, Equatable, Sendable {
  public var id: Int
  public var kind: ProposalKind
  public var title: String  // addTask: the new task's title; moveTask: the task's title when proposed
  public var notes: String?
  public var project: String?
  public var owner: String?  // who is to do it (addTask): a name as in the source, "me" for the user; nil if unclear
  public var priority: Priority
  public var taskID: Int?  // moveTask
  public var column: Column?  // moveTask: where to; linkTask: where to move it as well (optional)
  public var link: TaskLink?  // linkTask
  public var reason: String  // one line: why it is proposed
  public var sourceKind: String  // "email"
  public var sourceRef: String?  // e.g. the Gmail thread id
  public var sourceTitle: String?  // e.g. the subject
  public var sourceLink: String?
  public var created: Date
  public var mail: MailRef?  // for an email source: how to find it in the Mail app

  // Same thing proposed again → same key.
  public var key: String {
    let subject: String
    switch kind {
    case .addTask: subject = Proposal.normalize(title)
    case .moveTask: subject = "\(taskID ?? 0)>\(column?.rawValue ?? "")"
    case .linkTask: subject = "\(taskID ?? 0)|\(link?.identity ?? "")"
    }
    return "\(kind.rawValue)|\(subject)"
  }

  static func normalize(_ text: String) -> String {
    text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
}

public struct ProposalDraft: Sendable {
  public var title: String
  public var notes: String?
  public var project: String?
  public var owner: String?
  public var priority: Priority
  public var reason: String
  public var sourceKind: String
  public var sourceRef: String?
  public var sourceTitle: String?
  public var sourceLink: String?
  public var mail: MailRef?

  public init(
    title: String, notes: String? = nil, project: String? = nil, owner: String? = nil, priority: Priority = .normal,
    reason: String, sourceKind: String, sourceRef: String? = nil, sourceTitle: String? = nil, sourceLink: String? = nil,
    mail: MailRef? = nil
  ) {
    self.mail = mail
    self.title = title
    self.notes = notes
    self.project = project
    self.owner = owner
    self.priority = priority
    self.reason = reason
    self.sourceKind = sourceKind
    self.sourceRef = sourceRef
    self.sourceTitle = sourceTitle
    self.sourceLink = sourceLink
  }
}

extension Board {
  public func proposal(_ id: Int) -> Proposal? { proposals.first { $0.id == id } }

  @discardableResult
  public mutating func proposeTask(_ draft: ProposalDraft, now: Date = Date()) throws -> Proposal {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw BoardError.emptyName }
    let normalized = Proposal.normalize(title)
    if tasks.contains(where: { $0.column != .done && Proposal.normalize($0.title) == normalized }) {
      throw BoardError.duplicateProposal("an open task with this title already exists")
    }
    return try enqueue(
      Proposal(
        id: 0, kind: .addTask, title: title, notes: draft.notes.nonEmpty, project: try resolveProject(draft.project),
        owner: draft.owner.nonEmpty, priority: draft.priority, taskID: nil, column: nil, link: nil, reason: draft.reason, sourceKind: draft.sourceKind,
        sourceRef: draft.sourceRef, sourceTitle: draft.sourceTitle, sourceLink: draft.sourceLink, created: now,
        mail: draft.mail))
  }

  @discardableResult
  public mutating func proposeMove(_ taskID: Int, to column: Column, _ draft: ProposalDraft, now: Date = Date()) throws
    -> Proposal
  {
    guard let task = task(taskID) else { throw BoardError.noTask(taskID) }
    guard task.column != column else {
      throw BoardError.duplicateProposal("#\(taskID) is already in “\(column.title)”")
    }
    return try enqueue(
      Proposal(
        id: 0, kind: .moveTask, title: task.title, notes: draft.notes.nonEmpty, project: task.project,
        owner: task.owner, priority: task.priority, taskID: taskID, column: column, link: nil, reason: draft.reason, sourceKind: draft.sourceKind,
        sourceRef: draft.sourceRef, sourceTitle: draft.sourceTitle, sourceLink: draft.sourceLink, created: now))
  }

  // Propose attaching a link (a pull request) to an open task, and moving the task along with it.
  @discardableResult
  public mutating func proposeLink(
    _ taskID: Int, _ link: TaskLink, moveTo column: Column? = nil, _ draft: ProposalDraft, now: Date = Date()
  ) throws -> Proposal {
    guard let task = task(taskID) else { throw BoardError.noTask(taskID) }
    guard URL(string: link.url)?.scheme?.hasPrefix("http") == true else { throw BoardError.badLink(link.url) }
    if task.links.contains(where: { $0.identity == link.identity }) {
      throw BoardError.duplicateProposal("#\(taskID) already has this link")
    }
    let target = column.flatMap { $0 == task.column ? nil : $0 }
    return try enqueue(
      Proposal(
        id: 0, kind: .linkTask, title: task.title, notes: draft.notes.nonEmpty, project: task.project,
        owner: task.owner, priority: task.priority, taskID: taskID, column: target, link: link, reason: draft.reason,
        sourceKind: draft.sourceKind, sourceRef: draft.sourceRef, sourceTitle: draft.sourceTitle,
        sourceLink: draft.sourceLink, created: now))
  }

  private mutating func enqueue(_ proposal: Proposal) throws -> Proposal {
    var proposal = proposal
    if proposals.contains(where: { $0.key == proposal.key }) {
      throw BoardError.duplicateProposal("the same proposal is already waiting")
    }
    if dismissedProposals.contains(proposal.key) {
      throw BoardError.duplicateProposal("the user already rejected this")
    }
    proposal.id = nextProposalID
    nextProposalID += 1
    proposals.append(proposal)
    return proposal
  }

  // Applies the proposal; returns what it changed (nil when the task it was about is gone).
  @discardableResult
  public mutating func acceptProposal(_ id: Int) throws -> BoardTask? {
    guard let proposal = proposal(id) else { throw BoardError.noProposal(id) }
    proposals.removeAll { $0.id == id }
    switch proposal.kind {
    case .addTask:
      var notes = proposal.notes ?? ""
      if let subject = proposal.sourceTitle ?? proposal.sourceRef {
        notes += (notes.isEmpty ? "" : "\n\n") + "From \(proposal.sourceKind): \(subject)"
      }
      let task = add(
        title: proposal.title, notes: notes, project: proposal.project, owner: proposal.owner, priority: proposal.priority,
        source: proposal.sourceKind)
      // The source (the email, the Slack message) is a link on the task, one click from the card.
      if let url = proposal.sourceLink,
        let link = TaskLink.source(
          kind: proposal.sourceKind, title: proposal.sourceTitle ?? proposal.sourceRef, url: url, mail: proposal.mail)
      {
        try? attach(link, to: task.id)
      }
      return self.task(task.id)
    case .moveTask:
      guard let taskID = proposal.taskID, let column = proposal.column, task(taskID) != nil else { return nil }
      return try update(taskID) { $0.column = column }
    case .linkTask:
      guard let taskID = proposal.taskID, let link = proposal.link, task(taskID) != nil else { return nil }
      try attach(link, to: taskID)
      if let column = proposal.column { _ = try update(taskID) { $0.column = column } }
      return task(taskID)
    }
  }

  public mutating func rejectProposal(_ id: Int) throws {
    guard let proposal = proposal(id) else { throw BoardError.noProposal(id) }
    proposals.removeAll { $0.id == id }
    dismissedProposals.append(proposal.key)
    if dismissedProposals.count > 300 { dismissedProposals.removeFirst(dismissedProposals.count - 300) }
  }

  // A line for lists: "+ Title" or "#12 → Done: Title".
  public func line(_ proposal: Proposal) -> String {
    switch proposal.kind {
    case .addTask:
      "+ \(proposal.title)" + (proposal.project.map { " (\($0))" } ?? "")
        + (proposal.owner.map { " — \($0 == "me" ? "you" : $0)" } ?? "")
    case .moveTask: "#\(proposal.taskID ?? 0) → \(proposal.column?.title ?? "?"): \(proposal.title)"
    case .linkTask:
      "\(proposal.link?.label ?? "link") → #\(proposal.taskID ?? 0) \(proposal.title)"
        + (proposal.column.map { " · move to \($0.title)" } ?? "")
    }
  }
}
