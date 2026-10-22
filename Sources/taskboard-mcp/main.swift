// MCP server for Claude: read and change the personal kanban in ~/Library/Application Support/Taskboard.
// JSON-RPC 2.0 over stdio, one message per line.
// Register (wingform profile only):
//   CLAUDE_CONFIG_DIR=~/.claude-wingform claude mcp add --scope user taskboard /Applications/Taskboard.app/Contents/MacOS/taskboard-mcp
import Foundation
import TaskboardCore

let serverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

let instructions = """
  Личный канбан пользователя (колонки todo «Сделать», doing «В работе», done «Готово»), виден ему виджетом \
  в углу экрана. Добавляй задачу, когда пользователь просит запомнить, записать, поставить или «закинуть \
  на доску», и когда договорились о follow-up, который он сам будет делать. Перед добавлением смотри \
  list_tasks, чтобы не дублировать: похожую задачу лучше дополнить через update_task. Название — короткое \
  действие в повелительном наклонении («Проверить алерт на диск monitoring»), детали — в notes, репозиторий \
  или проект — в project. Сделал задачу вместе с пользователем — move_task в done.
  """

struct ToolError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
  ["type": "object", "properties": properties, "required": required]
}

let idProperty: [String: Any] = ["type": "integer", "description": "Номер задачи (#12 → 12)"]
let columnProperty: [String: Any] = ["type": "string", "enum": Column.allCases.map(\.rawValue)]
let priorityProperty: [String: Any] = ["type": "string", "enum": Priority.allCases.map(\.rawValue)]
let titleProperty: [String: Any] = ["type": "string", "description": "Коротко, действием: «Проверить …»"]
let notesProperty: [String: Any] = ["type": "string", "description": "Детали, ссылки, контекст"]
let projectProperty: [String: Any] = ["type": "string", "description": "Репозиторий или проект, если понятен"]

let tools: [[String: Any]] = [
  [
    "name": "list_tasks",
    "description": "Задачи на доске по колонкам. По умолчанию без «Готово».",
    "inputSchema": schema(["include_done": ["type": "boolean"]]),
    "annotations": ["readOnlyHint": true],
  ],
  [
    "name": "add_task",
    "description": "Добавить задачу (по умолчанию в «Сделать»).",
    "inputSchema": schema(
      [
        "title": titleProperty, "notes": notesProperty, "project": projectProperty,
        "priority": priorityProperty, "column": columnProperty,
      ], required: ["title"]),
  ],
  [
    "name": "update_task",
    "description": "Изменить название, заметки, проект или приоритет. Пустая строка очищает поле.",
    "inputSchema": schema(
      [
        "id": idProperty, "title": titleProperty, "notes": notesProperty, "project": projectProperty,
        "priority": priorityProperty,
      ], required: ["id"]),
  ],
  [
    "name": "move_task",
    "description": "Перенести задачу в другую колонку: doing — взял в работу, done — сделано.",
    "inputSchema": schema(["id": idProperty, "column": columnProperty], required: ["id", "column"]),
  ],
  [
    "name": "delete_task",
    "description": "Удалить задачу совсем (ошибочную или дубль). Сделанную — move_task в done.",
    "inputSchema": schema(["id": idProperty], required: ["id"]),
    "annotations": ["destructiveHint": true],
  ],
]

func column(_ arguments: [String: Any]) throws -> Column? {
  guard let value = arguments["column"] as? String else { return nil }
  guard let column = Column(loose: value) else { throw ToolError("Неизвестная колонка «\(value)»: todo, doing, done") }
  return column
}

func priority(_ arguments: [String: Any]) throws -> Priority? {
  guard let value = arguments["priority"] as? String else { return nil }
  guard let priority = Priority(rawValue: value.lowercased()) else {
    throw ToolError("Неизвестный приоритет «\(value)»: low, normal, high")
  }
  return priority
}

func id(_ arguments: [String: Any]) throws -> Int {
  if let id = arguments["id"] as? Int { return id }
  if let string = arguments["id"] as? String, let id = Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) {
    return id
  }
  throw ToolError("Нужен id задачи")
}

func callTool(_ name: String, _ arguments: [String: Any]) throws -> String {
  switch name {
  case "list_tasks":
    let columns: [Column] = (arguments["include_done"] as? Bool ?? false) ? Column.allCases : [.doing, .todo]
    return BoardStore.load().listing(columns: columns)

  case "add_task":
    guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    else { throw ToolError("Нужно название задачи") }
    let priority = try priority(arguments) ?? .normal
    let column = try column(arguments) ?? .todo
    let task = try BoardStore.change {
      $0.add(
        title: title, notes: arguments["notes"] as? String, project: arguments["project"] as? String,
        priority: priority, column: column, source: ProcessInfo.processInfo.environment["TASKBOARD_SOURCE"] ?? "claude")
    }
    return "Добавлена: \(task.line)"

  case "update_task":
    let id = try id(arguments)
    let priority = try priority(arguments)
    let task = try BoardStore.change { board in
      try board.update(id) { task in
        if let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
          task.title = title
        }
        if let notes = arguments["notes"] as? String { task.notes = notes.isEmpty ? nil : notes }
        if let project = arguments["project"] as? String { task.project = project.isEmpty ? nil : project }
        if let priority { task.priority = priority }
      }
    }
    return "Обновлена: \(task.line)"

  case "move_task":
    let id = try id(arguments)
    guard let column = try column(arguments) else { throw ToolError("Нужна колонка: todo, doing, done") }
    let task = try BoardStore.change { board in try board.update(id) { $0.column = column } }
    return "Перенесена: \(task.line)"

  case "delete_task":
    let id = try id(arguments)
    let task = try BoardStore.change { try $0.remove(id) }
    return "Удалена: #\(task.id) \(task.title)"

  default:
    throw ToolError("Unknown tool \(name)")
  }
}

// MARK: - JSON-RPC over stdio

func send(_ message: [String: Any]) {
  guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
  data.append(0x0A)
  FileHandle.standardOutput.write(data)
}

while let line = readLine() {
  guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
    let id = message["id"]  // notifications (no id) need no reply
  else { continue }
  let params = message["params"] as? [String: Any] ?? [:]

  switch message["method"] as? String {
  case "initialize":
    send([
      "jsonrpc": "2.0", "id": id,
      "result": [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "taskboard", "version": serverVersion],
        "instructions": instructions,
      ],
    ])
  case "ping":
    send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
  case "tools/list":
    send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
  case "tools/call":
    let name = params["name"] as? String ?? ""
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    do {
      send(["jsonrpc": "2.0", "id": id, "result": ["content": [text(try callTool(name, arguments))]]])
    } catch {
      send(["jsonrpc": "2.0", "id": id, "result": ["content": [text(error.localizedDescription)], "isError": true]])
    }
  default:
    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
  }
}
