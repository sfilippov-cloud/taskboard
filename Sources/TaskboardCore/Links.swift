// Links on tasks: pull requests (kept up to date by the GitHub check), Claude artifacts (attached from a session),
// commits and plain URLs. Attaching and state changes are journaled like any other change to a task.
import Foundation

// What it takes to find an email in the Mail app without its RFC 822 Message-ID (which the Gmail connector gives only
// inside the full raw message): the subject, who sent it and when.
public struct MailRef: Codable, Equatable, Hashable, Sendable {
  public var subject: String
  public var from: String?  // as shown: "Name <address>" or just an address
  public var date: Date?  // the message's own date

  public init(subject: String, from: String? = nil, date: Date? = nil) {
    self.subject = subject
    self.from = from
    self.date = date
  }

  // The subject without "Re:", "Fwd:", "Ответ:" and "[2]"-style prefixes, which differ between a thread's messages.
  public var coreSubject: String {
    var text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = ["re", "fwd", "fw", "ответ", "пересл", "aw", "sv"]
    var changed = true
    while changed {
      changed = false
      let lower = text.lowercased()
      for prefix in prefixes where lower.hasPrefix(prefix) {
        var rest = text.dropFirst(prefix.count)
        if rest.first == "[", let close = rest.firstIndex(of: "]") { rest = rest[rest.index(after: close)...] }
        if rest.first == ":" {
          text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
          changed = true
          break
        }
      }
    }
    return text
  }

  // message://%3Cid%40host%3E — the form the Mail app opens. nil for an empty id.
  public static func messageURL(forMessageID id: String) -> URL? {
    let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t"))
    guard !bare.isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = bare.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "message://%3C\(encoded)%3E")
  }

  // The bare address from "Name <address>", lowercased.
  public var fromAddress: String? {
    guard let from = from?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty else { return nil }
    if let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
      return from[from.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
    }
    return from.contains("@") ? from.lowercased() : nil
  }
}

extension Board {
  public func isLinked(_ identity: String) -> Bool {
    tasks.contains { $0.links.contains { $0.identity == identity } }
  }

  // Adds the link unless the task already has it; returns whether anything was added.
  @discardableResult
  public mutating func attach(_ link: TaskLink, to id: Int) throws -> Bool {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    guard URL(string: link.url)?.scheme?.hasPrefix("http") == true else { throw BoardError.badLink(link.url) }
    if tasks[index].links.contains(where: { $0.identity == link.identity }) { return false }
    tasks[index].links.append(link)
    tasks[index].updated = Date()
    return true
  }

  public mutating func removeLink(_ url: String, from id: Int) throws {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    tasks[index].links.removeAll { $0.url == url }
  }

  // Pull requests as the GitHub check saw them now: every link to one of them takes the new state.
  // `live: nil` means "couldn't tell" (the stand didn't answer): what was known stays; [] means "not deployed".
  public mutating func refreshPullRequests(_ current: [String: (title: String, state: String, live: [String]?)]) {
    for t in tasks.indices {
      for l in tasks[t].links.indices {
        let link = tasks[t].links[l]
        guard link.kind == "pr", let now = current[link.identity] else { continue }
        let live = now.live.map { $0.isEmpty ? nil : $0 } ?? link.live
        if link.state != now.state || link.live != live || link.title != now.title {
          tasks[t].links[l].state = now.state
          tasks[t].links[l].live = live
          tasks[t].links[l].title = now.title
          // Not a user edit of the task: leave `updated` alone, so "Done" doesn't age out because of it.
        }
      }
    }
  }

  // News about a task. The same text on the same task is not repeated; the oldest fall off after 100.
  // The task's own `updated` stays put: this is not the user editing the task, and a Done task shouldn't age
  // differently because mail arrived about it.
  @discardableResult
  public mutating func addUpdate(
    _ id: Int, text: String, source: String, link: String? = nil, date: Date = Date(), mail: MailRef? = nil
  ) throws -> Bool {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw BoardError.emptyName }
    let link = link.nonEmpty
    if let link, URL(string: link)?.scheme?.hasPrefix("http") != true { throw BoardError.badLink(link) }
    if tasks[index].updates.contains(where: { Proposal.normalize($0.text) == Proposal.normalize(body) }) { return false }
    tasks[index].updates.append(
      TaskUpdate(text: String(body.prefix(1000)), source: source, link: link, date: date, mail: mail))
    if tasks[index].updates.count > 100 { tasks[index].updates.removeFirst(tasks[index].updates.count - 100) }
    return true
  }

  public mutating func removeUpdate(_ updateID: String, from id: Int) throws {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    tasks[index].updates.removeAll { $0.id == updateID }
  }

  // Email chips saved before links knew how to find a message in Mail: the chip is titled with the subject, so that is
  // the reference (searching by subject alone — the sender and date weren't kept). Deterministic, like the others.
  mutating func adoptMailReferences() {
    for t in tasks.indices {
      for l in tasks[t].links.indices where tasks[t].links[l].kind == "email" && tasks[t].links[l].mail == nil {
        let title = tasks[t].links[l].title
        if title != "Email" { tasks[t].links[l].mail = MailRef(subject: title) }
      }
    }
  }

  // Older tasks kept their source as text in the notes ("From email: subject" and the URL on the next line):
  // it becomes a link too, dated by the task, so the result doesn't change from load to load.
  mutating func adoptLegacySourceLinks() {
    for index in tasks.indices {
      guard let notes = tasks[index].notes else { continue }
      let lines = notes.components(separatedBy: "\n")
      for (position, line) in lines.enumerated() {
        guard line.hasPrefix("From "), let colon = line.firstIndex(of: ":"), position + 1 < lines.count else { continue }
        let kind = String(line[line.index(line.startIndex, offsetBy: 5)..<colon])
        guard ["email", "slack", "github"].contains(kind) else { continue }
        let subject = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let link = TaskLink.source(kind: kind, title: subject, url: lines[position + 1]) else { continue }
        if !tasks[index].links.contains(where: { $0.identity == link.identity }) {
          var adopted = link
          adopted.added = tasks[index].created
          tasks[index].links.append(adopted)
        }
        // The URL line is now a chip; the notes keep only the "From …" line.
        tasks[index].notes = Optional(
          lines.enumerated().filter { $0.offset != position + 1 }.map(\.element).joined(separator: "\n")
        ).nonEmpty
        break  // one source per task; `lines` is stale after the edit
      }
    }
  }

  // Journal lines for links that appeared or changed state since `before`.
  func linkChanges(since before: Board) -> [(project: String?, text: String)] {
    var result: [(String?, String)] = []
    let old = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
    for task in tasks {
      guard let previous = old[task.id] else { continue }
      let known = Set(previous.updates.map(\.id))
      for update in task.updates where !known.contains(update.id) {
        result.append((task.project, "#\(task.id) \(task.title): " + update.text + (update.link.map { "\n" + $0 } ?? "")))
      }
      for link in task.links {
        let head = "#\(task.id) \(task.title): "
        guard let was = previous.links.first(where: { $0.identity == link.identity }) else {
          result.append((task.project, head + "linked " + link.label + "\n" + link.url))
          continue
        }
        if link.state != was.state, let state = link.state {
          result.append((task.project, head + "\(link.label) is now \(state)"))
        }
        let nowLive = Set(link.live ?? []).subtracting(was.live ?? [])
        for env in nowLive.sorted() { result.append((task.project, head + "\(link.label) is live on \(env)")) }
      }
    }
    return result
  }
}

extension TaskLink {
  // Where a task or an update came from: an email thread or a Slack message ("email", "slack"), anything else a plain link.
  public static func source(kind: String, title: String?, url: String, mail: MailRef? = nil) -> TaskLink? {
    guard let link = detect(url: url, title: title.nonEmpty ?? (kind == "email" ? "Email" : kind == "slack" ? "Slack message" : nil)) else {
      return nil
    }
    // A pull request or commit keeps what detect made of it; otherwise the source's own kind.
    guard link.kind == "link", kind == "email" || kind == "slack" else { return link }
    // An email can be found in Mail by its subject at least; the sender and date narrow it down.
    let ref = kind == "email" ? (mail ?? title.nonEmpty.map { MailRef(subject: $0) }) : nil
    return TaskLink(kind: kind, title: link.title, url: link.url, mail: ref)
  }

  // A link the user typed, pasted or dropped: only http(s). GitHub pull requests and commits and Claude artifacts are
  // recognised (a PR then keeps its repo and number, so the GitHub check can keep its state current); anything else is
  // a plain link, named by its host and last path part unless a title is given.
  public static func detect(url text: String, title: String? = nil) -> TaskLink? {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), !host.isEmpty
    else { return nil }
    let name = title.nonEmpty
    let parts = url.pathComponents.filter { $0 != "/" }
    if host == "github.com" || host == "www.github.com", parts.count >= 4 {
      let repo = "\(parts[0])/\(parts[1])"
      if parts[2] == "pull", let number = Int(parts[3]) {
        return TaskLink(
          kind: "pr", title: name ?? "\(repo)#\(number)", url: "https://github.com/\(repo)/pull/\(number)", repo: repo, number: number)
      }
      if parts[2] == "commit", parts[3].count >= 7 {
        return TaskLink(kind: "commit", title: name ?? "\(repo)@\(parts[3].prefix(7))", url: "https://github.com/\(repo)/commit/\(parts[3])", repo: repo)
      }
    }
    if host == "claude.ai", parts.contains("artifact") {
      return TaskLink(kind: "artifact", title: name ?? "Claude artifact", url: raw)
    }
    let shownHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    var fallback = shownHost
    if let last = parts.last { fallback += " › " + (last.removingPercentEncoding ?? last) }
    if fallback.count > 48 { fallback = String(fallback.prefix(47)) + "…" }
    return TaskLink(kind: "link", title: name ?? fallback, url: raw)
  }

  // "PR owner/name#12 “title”" / "artifact “title”".
  public var label: String {
    switch kind {
    case "pr": "PR \(identity) “\(title)”"
    default: "\(kind) “\(title)”"
    }
  }

  // Short text for a chip.
  public var chip: String {
    if kind == "pr", let number { return "#\(number)" }
    return title.count > 26 ? String(title.prefix(25)) + "…" : title
  }
}
