// The full kanban: three columns, drag cards between them, double-click to edit, right-click for more.
import AppKit
import SwiftUI
import TaskboardCore

enum ProjectFilter: Hashable {
  case all, none, project(String)  // project — slug
}

enum BoardTab: String, CaseIterable {
  case board = "Board"
  case journal = "Journal"
  case documents = "Documents"
  case proposals = "Proposals"
}

struct BoardView: View {
  @Bindable var model: AppModel
  @State private var newTitle = ""
  @State private var editing: BoardTask?
  @State private var filter = ProjectFilter.all
  @State private var projectForm: ProjectFormMode?
  @State private var showNote = false
  @State private var dropTargeted = false

  private var selected: Project? {
    if case .project(let slug) = filter { return model.board.project(slug: slug) }
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      switch model.boardTab {
      case .board:
        HStack(alignment: .top, spacing: 12) {
          ForEach(Column.allCases, id: \.self) { column in
            ColumnView(column: column, model: model, filter: matches, edit: { editing = $0 })
          }
        }
        .padding(12)
      case .journal:
        JournalView(model: model, project: selected, showsProject: filter == .all)
      case .documents:
        DocumentsView(model: model, project: selected)
      case .proposals:
        ProposalsView(model: model)
      }
    }
    .frame(minWidth: 760, minHeight: 420)
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
          .background(Color.accentColor.opacity(0.06)).padding(6).allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      model.ingest(urls: files, project: selected)
      return !files.isEmpty
    } isTargeted: { dropTargeted = $0 }
    .sheet(item: $editing) { task in
      EditTaskView(task: task, projects: model.board.activeProjects) { updated in
        model.change { board in
          _ = try board.update(task.id) {
            $0.title = updated.title
            $0.notes = updated.notes
            $0.project = updated.project
            $0.priority = updated.priority
          }
        }
      }
    }
    .sheet(item: $projectForm) { mode in
      ProjectForm(mode: mode) { name, summary, status, channels in
        switch mode {
        case .new:
          model.change { board in
            let project = try board.addProject(name: name, summary: summary)
            try board.updateProject(project.slug, slackChannels: channels)
            filter = .project(project.slug)
          }
        case .edit(let project):
          model.change { board in
            _ = try board.updateProject(project.slug, name: name, summary: summary, status: status, slackChannels: channels)
          }
        }
      }
    }
    .sheet(isPresented: $showNote) {
      NoteSheet(projects: model.board.activeProjects, preselected: selected) { text, project in
        model.ingest(note: text, project: project)
      }
    }
  }

  private var toolbar: some View {
    VStack(spacing: 8) {
      ProjectTabs(
        board: model.board, filter: $filter, add: { projectForm = .new },
        drop: { ids, name in moveTasks(ids, to: name) })
      HStack {
        Picker("", selection: $model.boardTab) {
          ForEach(BoardTab.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
        if let selected {
          Button { projectForm = .edit(selected) } label: { Image(systemName: "slider.horizontal.3") }
            .help("Project settings")
        }
        Spacer()
        ForEach(SyncKind.allCases, id: \.self) { SyncButton(model: model, kind: $0) }
        Button { showNote = true } label: { Label("Note", systemImage: "square.and.pencil") }
          .help("Paste a note or meeting minutes — Claude will sort it out")
        Button(action: pickFiles) { Label("File", systemImage: "paperclip") }
          .help("Attach a document (or drop it on this window or the widget)")
      }
      HStack {
        if model.boardTab == .board {
          TextField(newTaskPlaceholder, text: $newTitle).textFieldStyle(.roundedBorder).onSubmit(add)
        }
        Text("⌃⌥⌘R — by voice").font(.caption).foregroundStyle(.secondary)
      }
      if let summary = selected?.summary {
        Text(summary).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(12)
  }

  // A card dropped on a project tab: the task and its subtasks move there (nil — "No project").
  private func moveTasks(_ ids: [Int], to name: String?) -> Bool {
    guard !ids.isEmpty else { return false }
    model.change(source: "manual") { board in
      var count = 0
      for id in ids { count += try board.setProject(id, name).count }
      model.show("Moved \(count) task\(count == 1 ? "" : "s") to \(name ?? "No project")")
    }
    return true
  }

  private func label(for tab: BoardTab) -> String {
    let count = model.board.proposals.count
    return tab == .proposals && count > 0 ? "Proposals (\(count))" : tab.rawValue
  }

  private var newTaskPlaceholder: String {
    selected.map { "New task in “\($0.name)” — Enter" } ?? "New task — Enter"
  }

  private func matches(_ task: BoardTask) -> Bool {
    switch filter {
    case .all: true
    case .none: task.project == nil
    case .project: task.project == selected?.name
    }
  }

  private func add() {
    let title = newTitle
    let project = selected?.name
    guard !title.isBlank else { return }
    model.change(source: "manual") { $0.add(title: title, project: project, source: "manual") }
    newTitle = ""
  }

  private func pickFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Attach"
    if panel.runModal() == .OK { model.ingest(urls: panel.urls, project: selected) }
  }
}

struct ColumnView: View {
  let column: Column
  let model: AppModel
  let filter: (BoardTask) -> Bool
  let edit: (BoardTask) -> Void
  @State private var targeted = false

  var body: some View {
    let board = model.board
    let tasks =
      column == .done
      ? board.tasks(in: .done).filter(filter) : board.ordered(board.tasks.filter { $0.column == column && filter($0) })
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(column.title).font(.headline)
        Text("\(tasks.count)").foregroundStyle(.secondary)
      }
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(tasks) { task in
            CardView(task: task, board: board)
              .draggable(String(task.id))
              .onTapGesture(count: 2) { edit(task) }
              .contextMenu { menu(for: task) }
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
    )
    .dropDestination(for: String.self) { ids, _ in
      let numbers = ids.compactMap(Int.init)
      model.change { board in
        for id in numbers { _ = try board.update(id) { $0.column = column } }
      }
      return !numbers.isEmpty
    } isTargeted: { targeted = $0 }
  }

  @ViewBuilder
  private func menu(for task: BoardTask) -> some View {
    Button("Edit…") { edit(task) }
    ForEach(Column.allCases.filter { $0 != task.column }, id: \.self) { target in
      Button("→ \(target.title)") { model.change { board in _ = try board.update(task.id) { $0.column = target } } }
    }
    Menu("Priority") {
      ForEach(Priority.allCases, id: \.self) { priority in
        Button(priority.label) { model.change { board in _ = try board.update(task.id) { $0.priority = priority } } }
      }
    }
    Divider()
    Button("Copy") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString([task.title, task.notes].compactMap { $0 }.joined(separator: "\n\n"), forType: .string)
    }
    Button("Delete", role: .destructive) { model.change { board in _ = try board.remove(task.id) } }
  }
}

struct CardView: View {
  let task: BoardTask
  let board: Board

  static func icon(for source: String) -> String {
    switch source {
    case "voice": "mic"
    case "claude": "sparkles"
    case "document": "doc.text"
    default: "keyboard"
    }
  }

  var body: some View {
    let waiting = board.waitingOn(task)
    VStack(alignment: .leading, spacing: 4) {
      if let parent = task.parent.flatMap({ board.task($0) }) {
        Text("↳ #\(parent.id) \(parent.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
      HStack(alignment: .firstTextBaseline) {
        if task.column == .todo && !waiting.isEmpty {
          Image(systemName: "lock").foregroundStyle(.secondary).font(.caption)
        }
        if task.priority == .high { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption) }
        Text(task.title).fontWeight(task.priority == .high ? .semibold : .regular)
          .strikethrough(task.column == .done, color: .secondary)
        Spacer(minLength: 0)
        Text("#\(task.id)").font(.caption2).foregroundStyle(.tertiary)
      }
      if let notes = task.notes {
        Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
      }
      if !waiting.isEmpty && task.column != .done {
        Text("waiting on " + waiting.map { "#\($0.id) \($0.title)" }.joined(separator: ", "))
          .font(.caption2).foregroundStyle(.orange).lineLimit(2)
      }
      HStack(spacing: 6) {
        if let progress = board.progress(of: task.id) {
          Label("\(progress.done)/\(progress.total)", systemImage: "list.bullet.indent")
            .font(.caption2).foregroundStyle(.secondary)
        }
        if let project = task.project {
          Text(project).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        Image(systemName: Self.icon(for: task.source))
          .font(.caption2).foregroundStyle(.tertiary)
        Spacer()
        Text(task.updated, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    .contentShape(Rectangle())
  }
}

struct EditTaskView: View {
  @State var task: BoardTask
  let projects: [Project]
  let save: (BoardTask) -> Void
  @Environment(\.dismiss) private var dismiss

  // The current project stays selectable even if it has been archived since.
  private var projectNames: [String] {
    var names = projects.map(\.name)
    if let current = task.project, !names.contains(current) { names.append(current) }
    return names
  }

  var body: some View {
    Form {
      TextField("Title", text: $task.title)
      Picker("Project", selection: $task.project) {
        Text("No project").tag(String?.none)
        ForEach(projectNames, id: \.self) { Text($0).tag(Optional($0)) }
      }
      Picker("Priority", selection: $task.priority) {
        ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      TextField(
        "Notes", text: Binding(get: { task.notes ?? "" }, set: { task.notes = $0.isBlank ? nil : $0 }),
        axis: .vertical
      )
      .lineLimit(4...12)
    }
    .padding()
    .frame(width: 460)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          save(task)
          dismiss()
        }
        .disabled(task.title.isBlank)
      }
    }
  }
}

extension Priority {
  var label: String {
    switch self {
    case .low: "Low"
    case .normal: "Normal"
    case .high: "High"
    }
  }
}

// The project strip: All, one tab per active project, No project. Task cards can be dropped on a tab.
struct ProjectTabs: View {
  let board: Board
  @Binding var filter: ProjectFilter
  let add: () -> Void
  let drop: ([Int], String?) -> Bool

  var body: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ProjectTab(title: "All", count: open { _ in true }, isSelected: filter == .all) { filter = .all }
          ForEach(board.activeProjects) { project in
            ProjectTab(
              title: project.name, count: open { $0.project == project.name },
              isSelected: filter == .project(project.slug), select: { filter = .project(project.slug) },
              drop: { drop($0, project.name) })
          }
          ProjectTab(
            title: "No project", count: open { $0.project == nil }, isSelected: filter == .none,
            select: { filter = .none }, drop: { drop($0, nil) })
        }
        .padding(.vertical, 2)
      }
      Button(action: add) { Image(systemName: "plus") }.help("New project")
    }
  }

  private func open(_ matches: (BoardTask) -> Bool) -> Int {
    board.tasks.filter { $0.column != .done && matches($0) }.count
  }
}

struct ProjectTab: View {
  let title: String
  let count: Int
  let isSelected: Bool
  let select: () -> Void
  var drop: (([Int]) -> Bool)?
  @State private var targeted = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 5) {
        Text(title).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
        if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
      }
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(Capsule().fill(fill))
      .overlay(Capsule().stroke(targeted ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .dropDestination(for: String.self) { ids, _ in drop?(ids.compactMap(Int.init)) ?? false } isTargeted: {
      targeted = drop != nil && $0
    }
  }

  private var fill: Color {
    if targeted { return Color.accentColor.opacity(0.3) }
    return isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)
  }
}
