// Pull requests from GitHub through the `gh` CLI (read-only calls), and the commit the test stand is running.
import Foundation
import TaskboardCore

struct PullRequest: Equatable {
  var repo: String
  var number: Int
  var title: String
  var branch: String
  var author: String
  var isBot: Bool
  var url: String
  var state: String  // open, merged, closed
  var isDraft: Bool
  var body: String
  var updatedAt: Date
  var mergeSHA: String?
  var live: [String]?  // environments the merge commit is deployed to; nil when the stand couldn't be asked

  var identity: String { "\(repo)#\(number)" }

  // Automatic branch syncs, promotions between environments, dependabot and the like: never worth matching with a task.
  var isNoise: Bool {
    isBot || author.hasPrefix("app/") || author.contains("[bot]") || branch.hasPrefix("sync/")
      || branch.hasPrefix("merge/") || title.lowercased().hasPrefix("sync:")
  }

  var link: TaskLink {
    TaskLink(kind: "pr", title: title, url: url, repo: repo, number: number, state: state, live: (live ?? []).isEmpty ? nil : live)
  }
}

enum GitHubError: LocalizedError {
  case noGH
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .noGH: "gh (GitHub CLI) not found — install it and run `gh auth login`"
    case .failed(let output): "gh failed: \(output.prefix(300))"
    }
  }
}

enum GitHubClient {
  static let home = FileManager.default.homeDirectoryForCurrentUser.path

  // Repositories to follow, "owner/name", comma-separated: defaults write com.lozhka13.taskboard githubRepos "a/b, c/d"
  static var repos: [String] {
    let text = UserDefaults.standard.string(forKey: "githubRepos") ?? "JetSetProjects/JetSetBackend, JetSetProjects/monorepo"
    return text.components(separatedBy: CharacterSet(charactersIn: ", \n")).filter { $0.contains("/") }
  }

  // The branch that deploys to the test stand.
  static var base: String { UserDefaults.standard.string(forKey: "githubBase") ?? "test" }

  // "owner/name=https://…/version/, …": where a running stand reports its commit as {"commit": "<sha>"}.
  static var versionURLs: [String: String] {
    let text =
      UserDefaults.standard.string(forKey: "githubVersionURLs")
      ?? "JetSetProjects/JetSetBackend=https://app-test.wingform.com/api/version/"
    var result: [String: String] = [:]
    for part in text.components(separatedBy: ",") {
      let pair = part.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
      if pair.count >= 2 { result[pair[0].trimmingCharacters(in: .whitespaces)] = pair.dropFirst().joined(separator: "=") }
    }
    return result
  }

  static var executable: String? {
    ["\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  static func run(_ arguments: [String]) async throws -> Data {
    guard let executable else { throw GitHubError.noGH }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
          try process.run()
          // Read while it runs: a full pipe would block a long listing.
          let data = output.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          if process.terminationStatus == 0 {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: GitHubError.failed(String(data: data, encoding: .utf8) ?? ""))
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // Pull requests into `base` updated since `since`, with their live state where a version URL is known.
  static func pullRequests(repo: String, since: Date) async throws -> [PullRequest] {
    let day = ISO8601DateFormatter().string(from: since).prefix(10)
    let data = try await run([
      "pr", "list", "-R", repo, "--base", base, "--state", "all", "--limit", "100", "--search", "updated:>=\(day)",
      "--json", "number,title,headRefName,state,isDraft,author,url,body,updatedAt,mergeCommit",
    ])
    guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let formatter = ISO8601DateFormatter()
    var result: [PullRequest] = []
    for item in items {
      guard let number = item["number"] as? Int, let title = item["title"] as? String,
        let updated = (item["updatedAt"] as? String).flatMap(formatter.date(from:))
      else { continue }
      let author = item["author"] as? [String: Any]
      result.append(
        PullRequest(
          repo: repo, number: number, title: title, branch: item["headRefName"] as? String ?? "",
          author: author?["login"] as? String ?? "", isBot: author?["is_bot"] as? Bool ?? false,
          url: item["url"] as? String ?? "", state: (item["state"] as? String ?? "").lowercased(),
          isDraft: item["isDraft"] as? Bool ?? false, body: item["body"] as? String ?? "", updatedAt: updated,
          mergeSHA: (item["mergeCommit"] as? [String: Any])?["oid"] as? String))
    }
    return result
  }

  static func deployedCommit(_ urlString: String) async -> String? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: request),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["commit"] as? String
  }

  // The merge commit is part of what's running when the deployed commit is identical to it or ahead of it.
  static func isLive(repo: String, sha: String, deployed: String) async -> Bool {
    if sha == deployed { return true }
    guard let data = try? await run(["api", "repos/\(repo)/compare/\(sha)...\(deployed)", "--jq", ".status"]),
      let status = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return false }
    return status == "ahead" || status == "identical"
  }

  // Everything followed, noise included (the caller filters), with `live` filled in.
  static func snapshot(days: Int) async throws -> [PullRequest] {
    let since = Date().addingTimeInterval(-Double(days) * 86400)
    var all: [PullRequest] = []
    for repo in repos {
      var prs = try await pullRequests(repo: repo, since: since)
      if let versionURL = versionURLs[repo], let deployed = await deployedCommit(versionURL) {
        for index in prs.indices where prs[index].state == "merged" {
          guard let sha = prs[index].mergeSHA else { continue }
          prs[index].live = await isLive(repo: repo, sha: sha, deployed: deployed) ? [base] : []
        }
      }
      all += prs
    }
    return all
  }
}
