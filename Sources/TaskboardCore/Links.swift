// Links on tasks: pull requests (kept up to date by the GitHub check), Claude artifacts (attached from a session),
// commits and plain URLs. Attaching and state changes are journaled like any other change to a task.
import Foundation

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
  public mutating func addUpdate(_ id: Int, text: String, source: String, link: String? = nil, date: Date = Date()) throws
    -> Bool
  {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw BoardError.emptyName }
    let link = link.nonEmpty
    if let link, URL(string: link)?.scheme?.hasPrefix("http") != true { throw BoardError.badLink(link) }
    if tasks[index].updates.contains(where: { Proposal.normalize($0.text) == Proposal.normalize(body) }) { return false }
    tasks[index].updates.append(TaskUpdate(text: String(body.prefix(1000)), source: source, link: link, date: date))
    if tasks[index].updates.count > 100 { tasks[index].updates.removeFirst(tasks[index].updates.count - 100) }
    return true
  }

  public mutating func removeUpdate(_ updateID: String, from id: Int) throws {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw BoardError.noTask(id) }
    tasks[index].updates.removeAll { $0.id == updateID }
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
