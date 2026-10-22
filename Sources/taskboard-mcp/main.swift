// MCP server for Claude: read and change the personal kanban in ~/Library/Application Support/Taskboard.
// Tasks form a tree (subtasks) with dependencies between them ("can't start until #3 is done").
// JSON-RPC 2.0 over stdio, one message per line.
// Register (wingform profile only):
//   CLAUDE_CONFIG_DIR=~/.claude-wingform claude mcp add --scope user taskboard /Applications/Taskboard.app/Contents/MacOS/taskboard-mcp
import Foundation
import TaskboardCore

let serverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

let instructions = """
  Личный канбан пользователя (колонки todo «Сделать», doing «В работе», done «Готово»), виден ему виджетом \
  в углу экрана. Задачи бывают деревом (parent — подзадача) и зависят друг от друга (depends_on — нельзя \
  начать, пока те не готовы). Добавляй задачи, когда пользователь просит запомнить, записать, поставить или \
  «закинуть на доску», и когда договорились о follow-up, который он сам будет делать. Ветвистую работу из \
  нескольких связанных шагов раскладывай одним add_plan (подробно — скилл taskboard). Перед добавлением \
  смотри list_tasks, чтобы не дублировать. Название — короткое действие («Проверить алерт на диск \
  monitoring»), детали — в notes, репозиторий или проект — в project. Сделал задачу вместе с пользователем — \
  move_task в done.
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
let notesProperty: [String: Any] = ["type": "string", "description": "Детали, ссылки, контекст, критерий готовности"]
let projectProperty: [String: Any] = [
  "type": "string", "description": "Репозиторий или проект, если понятен; подзадачи без своего наследуют от родителя",
]
let parentProperty: [String: Any] = ["type": "integer", "description": "Номер родительской задачи; 0 — убрать родителя"]
let dependsProperty: [String: Any] = [
  "type": "array", "items": ["type": "integer"],
  "description": "Номера задач, без которых эту не начать. Заменяет весь список; [] — убрать зависимости",
]

let tools: [[String: Any]] = [
  [
    "name": "list_tasks",
    "description":
      "Доска. view=tree (по умолчанию) — дерево с подзадачами, блокировками и прогрессом; view=ready — что можно брать прямо сейчас (не ждёт других и без открытых подзадач).",
    "inputSchema": schema([
      "view": ["type": "string", "enum": ["tree", "ready"]],
      "include_done": ["type": "boolean", "description": "Показать и готовые (только для tree)"],
    ]),
    "annotations": ["readOnlyHint": true],
  ],
  [
    "name": "get_task",
    "description": "Задача целиком: заметки, путь от корня, подзадачи, от чего зависит и кто её ждёт.",
    "inputSchema": schema(["id": idProperty], required: ["id"]),
    "annotations": ["readOnlyHint": true],
  ],
  [
    "name": "add_task",
    "description": "Добавить одну задачу (по умолчанию в «Сделать»). Для нескольких связанных — add_plan.",
    "inputSchema": schema(
      [
        "title": titleProperty, "notes": notesProperty, "project": projectProperty,
        "priority": priorityProperty, "column": columnProperty, "parent": parentProperty, "depends_on": dependsProperty,
      ], required: ["title"]),
  ],
  [
    "name": "add_plan",
    "description": """
      Разложить ветвистую работу: создать сразу дерево задач с зависимостями, атомарно (ошибка — не создаётся ничего). \
      У каждой задачи свой ref (любая короткая метка, например "db"); parent и depends_on ссылаются на ref из этого \
      же плана или на номер задачи, уже стоящей на доске ("#12"). Возвращает созданное дерево и что можно брать первым.
      """,
    "inputSchema": schema(
      [
        "tasks": [
          "type": "array",
          "items": schema(
            [
              "ref": ["type": "string", "description": "Метка внутри плана"],
              "title": titleProperty, "notes": notesProperty, "project": projectProperty,
              "priority": priorityProperty,
              "parent": ["type": "string", "description": "ref или #номер родителя"],
              "depends_on": [
                "type": "array", "items": ["type": "string"], "description": "ref или #номера задач, которые нужны раньше",
              ],
            ], required: ["ref", "title"]),
        ]
      ], required: ["tasks"]),
  ],
  [
    "name": "update_task",
    "description":
      "Изменить название, заметки, проект, приоритет, родителя или зависимости. Пустая строка очищает текстовое поле.",
    "inputSchema": schema(
      [
        "id": idProperty, "title": titleProperty, "notes": notesProperty, "project": projectProperty,
        "priority": priorityProperty, "parent": parentProperty, "depends_on": dependsProperty,
      ], required: ["id"]),
  ],
  [
    "name": "move_task",
    "description":
      "Перенести задачу в колонку: doing — взял в работу, done — сделано. Сообщает, какие задачи после этого разблокировались.",
    "inputSchema": schema(["id": idProperty, "column": columnProperty], required: ["id", "column"]),
  ],
  [
    "name": "delete_task",
    "description":
      "Удалить задачу совсем (ошибочную или дубль). Её подзадачи поднимаются на уровень выше, зависимости от неё снимаются. Сделанную — move_task в done.",
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

func number(_ value: Any?) -> Int? {
  if let id = value as? Int { return id }
  if let string = value as? String { return Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
  return nil
}

func id(_ arguments: [String: Any]) throws -> Int {
  guard let id = number(arguments["id"]) else { throw ToolError("Нужен id задачи") }
  return id
}

func numbers(_ value: Any?) throws -> [Int]? {
  guard let value else { return nil }
  guard let list = value as? [Any] else { throw ToolError("depends_on — список номеров задач") }
  return try list.map { item in
    guard let id = number(item) else { throw ToolError("depends_on: «\(item)» — не номер задачи") }
    return id
  }
}

// Board around the given tasks after a change: their summaries plus what got unblocked.
func report(_ board: Board, _ verb: String, _ tasks: [BoardTask]) -> String {
  tasks.map { "\(verb): " + board.summary($0) }.joined(separator: "\n")
}

let source = ProcessInfo.processInfo.environment["TASKBOARD_SOURCE"] ?? "claude"

func callTool(_ name: String, _ arguments: [String: Any]) throws -> String {
  switch name {
  case "list_tasks":
    let board = BoardStore.load()
    if (arguments["view"] as? String) == "ready" { return board.readyListing() }
    return board.tree(includeDone: arguments["include_done"] as? Bool ?? false)

  case "get_task":
    return try BoardStore.load().details(try id(arguments))

  case "add_task":
    guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    else { throw ToolError("Нужно название задачи") }
    let priority = try priority(arguments) ?? .normal
    let column = try column(arguments) ?? .todo
    let dependencies = try numbers(arguments["depends_on"]) ?? []
    let parent = number(arguments["parent"]).flatMap { $0 == 0 ? nil : $0 }
    return try BoardStore.change { board in
      let task = board.add(
        title: title, notes: arguments["notes"] as? String, project: arguments["project"] as? String,
        priority: priority, column: column, source: source)
      if let parent {
        try board.setParent(task.id, parent)
        if task.project == nil, let project = board.task(parent)?.project {
          _ = try board.update(task.id) { $0.project = project }
        }
      }
      if !dependencies.isEmpty { try board.setDependencies(task.id, dependencies) }
      return report(board, "Добавлена", [board.task(task.id)!])
    }

  case "add_plan":
    guard let raw = arguments["tasks"] as? [[String: Any]], !raw.isEmpty else { throw ToolError("Нужен список tasks") }
    let items = try raw.map { item -> PlanItem in
      guard let ref = (item["ref"] as? String).map({ $0.trimmingCharacters(in: .whitespaces) }), !ref.isEmpty else {
        throw ToolError("У каждой задачи плана нужен ref")
      }
      guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
      else { throw ToolError("У «\(ref)» нет названия") }
      let parent = item["parent"].flatMap { $0 is NSNull ? nil : "\($0)" }
      let dependsOn = (item["depends_on"] as? [Any] ?? []).map { "\($0)" }
      return PlanItem(
        ref: ref, title: title, notes: item["notes"] as? String, project: item["project"] as? String,
        priority: try priority(item) ?? .normal, parent: parent, dependsOn: dependsOn)
    }
    return try BoardStore.change { board in
      let created = try board.addPlan(items, source: source)
      let ids = Set(created.map(\.task.id))
      // The new subtree(s): created tasks whose parent isn't part of the plan.
      var lines: [String] = []
      func walk(_ task: BoardTask, depth: Int) {
        lines.append(String(repeating: "  ", count: depth) + board.summary(task))
        for child in board.children(of: task.id) where ids.contains(child.id) { walk(child, depth: depth + 1) }
      }
      for (_, task) in created where task.parent.map({ !ids.contains($0) }) ?? true {
        let under = task.parent.flatMap { board.task($0) }.map { " (внутри #\($0.id) \($0.title))" } ?? ""
        if !under.isEmpty { lines.append("↳\(under)") }
        walk(task, depth: 0)
      }
      let refs = created.map { "\($0.ref)=#\($0.task.id)" }.joined(separator: ", ")
      let ready = board.ordered(created.map(\.task).filter(board.isReady)).map { "#\($0.id) \($0.title)" }
      return "Создано задач: \(created.count) (\(refs))\n\n" + lines.joined(separator: "\n")
        + "\n\nМожно брать сразу: " + (ready.isEmpty ? "—" : ready.joined(separator: "; "))
    }

  case "update_task":
    let id = try id(arguments)
    let priority = try priority(arguments)
    let dependencies = try numbers(arguments["depends_on"])
    return try BoardStore.change { board in
      _ = try board.update(id) { task in
        if let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
          task.title = title
        }
        if let notes = arguments["notes"] as? String { task.notes = notes.isEmpty ? nil : notes }
        if let project = arguments["project"] as? String { task.project = project.isEmpty ? nil : project }
        if let priority { task.priority = priority }
      }
      if let parent = number(arguments["parent"]) { try board.setParent(id, parent == 0 ? nil : parent) }
      if let dependencies { try board.setDependencies(id, dependencies) }
      return report(board, "Обновлена", [board.task(id)!])
    }

  case "move_task":
    let id = try id(arguments)
    guard let column = try column(arguments) else { throw ToolError("Нужна колонка: todo, doing, done") }
    return try BoardStore.change { board in
      let task = try board.update(id) { $0.column = column }
      var lines = [report(board, "Перенесена", [task])]
      let waiting = board.waitingOn(task)
      if column == .doing, !waiting.isEmpty {
        lines.append("Внимание: она ещё ждёт " + waiting.map { "#\($0.id) \($0.title)" }.joined(separator: ", "))
      }
      let open = board.children(of: id).filter { $0.column != .done }
      if column == .done, !open.isEmpty {
        lines.append("Внимание: открыты подзадачи " + open.map { "#\($0.id) \($0.title)" }.joined(separator: ", "))
      }
      if column == .done {
        let unblocked = board.unblocked(by: id)
        if !unblocked.isEmpty { lines.append(report(board, "Разблокирована", unblocked)) }
        if let parent = task.parent.flatMap({ board.task($0) }), parent.column != .done,
          board.children(of: parent.id).allSatisfy({ $0.column == .done })
        {
          lines.append("Все подзадачи #\(parent.id) «\(parent.title)» готовы — закрыть и её?")
        }
      }
      return lines.joined(separator: "\n")
    }

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
