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
  public mutating func refreshPullRequests(_ current: [String: (title: String, state: String, live: [String])]) {
    for t in tasks.indices {
      for l in tasks[t].links.indices {
        let link = tasks[t].links[l]
        guard link.kind == "pr", let now = current[link.identity] else { continue }
        let live = now.live.isEmpty ? nil : now.live
        if link.state != now.state || link.live != live || link.title != now.title {
          tasks[t].links[l].state = now.state
          tasks[t].links[l].live = live
          tasks[t].links[l].title = now.title
          // Not a user edit of the task: leave `updated` alone, so "Done" doesn't age out because of it.
        }
      }
    }
  }

  // Journal lines for links that appeared or changed state since `before`.
  func linkChanges(since before: Board) -> [(project: String?, text: String)] {
    var result: [(String?, String)] = []
    let old = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
    for task in tasks {
      guard let previous = old[task.id] else { continue }
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
