// Hands a voice note to Claude Code in the wingform profile (`claude -p`), which changes the board
// through taskboard-mcp. Only the taskboard tools are available to it.
import Foundation

enum ClaudeError: LocalizedError {
  case notFound
  case failed(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .notFound: "Не найден claude (~/.local/bin/claude)"
    case .failed(let output): "Claude завершился с ошибкой: \(output.prefix(300))"
    case .timedOut: "Claude не ответил за 3 минуты"
    }
  }
}

enum ClaudeRunner {
  static let home = FileManager.default.homeDirectoryForCurrentUser.path

  static var configDirectory: String {
    UserDefaults.standard.string(forKey: "claudeConfigDir") ?? "\(home)/.claude-wingform"
  }

  static var workingDirectory: String {
    UserDefaults.standard.string(forKey: "claudeWorkingDir") ?? "\(home)/GitHub/wingform"
  }

  static var model: String { UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet" }

  static var executable: String? {
    let candidates = [
      UserDefaults.standard.string(forKey: "claudePath"), "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  // The MCP server ships next to the app's executable.
  static var mcpServer: String {
    Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("taskboard-mcp").path
  }

  static let systemPrompt = """
    Ты ведёшь личный канбан пользователя через инструменты taskboard. Тебе приходит расшифровка его \
    голосовой заметки (распознана автоматически, возможны ошибки в терминах — восстанавливай по смыслу: \
    названия репозиториев, сервисов, серверов wingform).

    1. Сначала list_tasks, чтобы видеть доску.
    2. Каждое отдельное дело из заметки — add_task: короткое название действием («Проверить алерт на диск \
    monitoring»), детали и контекст из заметки — в notes, репозиторий/проект — в project, «срочно»/«в первую \
    очередь» — priority high. Не дроби одно дело на шаги.
    3. Если заметка про уже существующую задачу — дополни её (update_task) вместо дубля.
    4. «Взял в работу», «начинаю» — move_task в doing; «сделал», «закрыл», «готово» — в done; «убери», \
    «отмени» — delete_task.
    5. Ничего не придумывай сверх сказанного.

    В конце ответь одной короткой строкой по-русски, что сделал, с номерами задач, например: \
    «+#14 Проверить алерт на диск, #9 → готово».
    """

  // Claude's one-line summary.
  static func process(transcript: String) async throws -> String {
    guard let executable else { throw ClaudeError.notFound }
    let mcpConfig: [String: Any] = [
      "mcpServers": ["taskboard": ["command": mcpServer, "env": ["TASKBOARD_SOURCE": "voice"]]]
    ]
    let mcpJSON = String(data: try JSONSerialization.data(withJSONObject: mcpConfig), encoding: .utf8)!

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
      "-p", "Голосовая заметка:\n\n\(transcript)",
      "--append-system-prompt", systemPrompt,
      "--model", model,
      "--mcp-config", mcpJSON, "--strict-mcp-config",
      "--tools", "",
      "--allowedTools", "mcp__taskboard",
      "--no-session-persistence",
      "--output-format", "text",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_CONFIG_DIR"] = configDirectory
    environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
      .joined(separator: ":")
    process.environment = environment
    if FileManager.default.fileExists(atPath: workingDirectory) {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice

    return try await withCheckedThrowingContinuation { continuation in
      let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
      process.terminationHandler = { process in
        timeout.cancel()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationReason == .uncaughtSignal {
          continuation.resume(throwing: ClaudeError.timedOut)
        } else if process.terminationStatus != 0 {
          continuation.resume(throwing: ClaudeError.failed(text))
        } else {
          continuation.resume(returning: text.components(separatedBy: "\n").last(where: { !$0.isBlank }) ?? text)
        }
      }
      do {
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
