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
  @State private var linkTarget: BoardTask?
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
            ColumnView(
              column: column, model: model, filter: matches, edit: { editing = $0 }, askLink: { linkTarget = $0 },
              attach: attachLink)
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
      EditTaskView(
        task: task, projects: model.board.activeProjects, updates: model.board.task(task.id)?.updates ?? [],
        addUpdate: { text in
          model.change(source: "manual") { board in try board.addUpdate(task.id, text: text, source: "manual") }
        },
        removeUpdate: { updateID in model.change { board in try board.removeUpdate(updateID, from: task.id) } },
        links: model.board.task(task.id)?.links ?? [], addLink: { url, title in attachLink(task.id, url, title) },
        removeLink: { url in model.change(source: "manual") { board in try board.removeLink(url, from: task.id) } }
      ) { updated in
        model.change { board in
          _ = try board.update(task.id) {
            $0.title = updated.title
            $0.notes = updated.notes
            $0.project = updated.project
            $0.owner = updated.owner
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
    .sheet(item: $linkTarget) { task in
      AddLinkSheet(task: task) { url, title in attachLink(task.id, url, title) }
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

  // Adds a link typed, pasted or dropped by the user; returns what to tell them if it didn't work.
  private func attachLink(_ taskID: Int, _ url: String, _ title: String?) -> String? {
    guard let link = TaskLink.detect(url: url, title: title) else { return "That isn't a web link (http or https)" }
    var added = false
    model.change(source: "manual") { board in added = try board.attach(link, to: taskID) }
    return added ? nil : "This task already has that link"
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
  let askLink: (BoardTask) -> Void
  let attach: (Int, String, String?) -> String?
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
              // A web link dragged from a browser onto a card is attached to it; files fall through to the window.
              .dropDestination(for: URL.self) { urls, _ in
                let web = urls.filter { !$0.isFileURL }
                for url in web { _ = attach(task.id, url.absoluteString, nil) }
                return !web.isEmpty
              }
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

  // The clipboard text, if it is a web link.
  private static var clipboardLink: String? {
    guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
      TaskLink.detect(url: text) != nil
    else { return nil }
    return text
  }

  @ViewBuilder
  private func menu(for task: BoardTask) -> some View {
    Button("Edit…") { edit(task) }
    Button("Add link…") { askLink(task) }
    if let url = Self.clipboardLink {
      Button("Paste link: \(TaskLink.detect(url: url)?.chip ?? url)") { _ = attach(task.id, url, nil) }
    }
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
    case "email": "envelope"
    case "slack": "number"
    case "github": "arrow.triangle.pull"
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
      if let latest = task.updates.last { LatestUpdate(update: latest, total: task.updates.count) }
      if !task.links.isEmpty { LinkChips(links: task.links) }
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
        if let owner = task.owner {
          Label(owner, systemImage: "person").font(.caption2).foregroundStyle(owner == "me" ? .secondary : Color.orange)
            .help(owner == "me" ? "Yours" : "Someone else's task — owner: \(owner)")
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

// A link to where something came from. An email opens in the Mail app when we know enough to find it there (and the
// setting allows), falling back to the web link; a right-click always offers the web link. Anything else is a plain Link.
struct SourceLink<Label: View>: View {
  let url: URL
  let mail: MailRef?
  @ViewBuilder var label: () -> Label

  var body: some View {
    if let mail, MailOpener.usesMail {
      Button(action: { MailOpener.open(webURL: url, mail: mail) }, label: label)
        .contextMenu { Button("Open in Gmail (web)") { NSWorkspace.shared.open(url) } }
    } else {
      Link(destination: url, label: label)
    }
  }
}

// The newest piece of news about a task, under its title; the task window has the whole timeline.
struct LatestUpdate: View {
  let update: TaskUpdate
  let total: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Image(systemName: CardView.icon(for: update.source)).font(.caption2).foregroundStyle(Color.accentColor)
      Text(update.text).font(.caption).lineLimit(2)
      Spacer(minLength: 0)
      if let url = update.link.flatMap(URL.init(string:)) {
        SourceLink(url: url, mail: update.mail) { Image(systemName: "arrow.up.right.square") }
          .buttonStyle(.plain).foregroundStyle(Color.accentColor)
          .help(update.mail != nil && MailOpener.usesMail ? "Open the email in Mail" : "Open the source: \(update.link ?? "")")
      }
      VStack(alignment: .trailing, spacing: 1) {
        Text(update.date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
        if total > 1 { Text("+\(total - 1) earlier").font(.caption2).foregroundStyle(.tertiary) }
      }
    }
    .padding(.horizontal, 6).padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    .help(update.text)
  }
}

// Pull requests, artifacts and other links on a card: a chip each, a click opens it.
struct LinkChips: View {
  let links: [TaskLink]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(links.prefix(4)), id: \.url) { link in
        if let url = URL(string: link.url) {
          SourceLink(url: url, mail: link.mail) { chip(link) }.buttonStyle(.plain).help(helpText(link))
        }
      }
      if links.count > 4 { Text("+\(links.count - 4)").font(.caption2).foregroundStyle(.secondary) }
    }
  }

  private func chip(_ link: TaskLink) -> some View {
    HStack(spacing: 3) {
      Image(systemName: Self.icon(for: link)).font(.caption2)
      Text(link.chip).font(.caption2).lineLimit(1)
      if let live = link.live, !live.isEmpty {
        Image(systemName: "checkmark.seal.fill").font(.caption2)
        Text(live.joined(separator: ",")).font(.caption2)
      }
    }
    .padding(.horizontal, 6).padding(.vertical, 2)
    .foregroundStyle(color(link))
    .background(Capsule().fill(color(link).opacity(0.14)))
  }

  static func icon(for link: TaskLink) -> String {
    switch link.kind {
    case "pr": link.state == "merged" ? "arrow.triangle.merge" : "arrow.triangle.pull"
    case "artifact": "sparkles.rectangle.stack"
    case "commit": "smallcircle.filled.circle"
    case "email": "envelope"
    case "slack": "number"
    default: "link"
    }
  }

  private func color(_ link: TaskLink) -> Color {
    guard link.kind == "pr" else { return .accentColor }
    if link.live?.isEmpty == false { return .green }
    switch link.state {
    case "merged": return .purple
    case "closed": return .secondary
    default: return .blue
    }
  }

  private func helpText(_ link: TaskLink) -> String {
    var text = link.label
    if let state = link.state { text += " — \(state)" }
    if let live = link.live, !live.isEmpty { text += ", live on \(live.joined(separator: ", "))" }
    return text
  }
}

struct EditTaskView: View {
  @State var task: BoardTask
  let projects: [Project]
  let updates: [TaskUpdate]  // live from the board: news may arrive while the window is open
  let addUpdate: (String) -> Void
  let removeUpdate: (String) -> Void
  let links: [TaskLink]  // live from the board, like updates: a pull request may be linked while the window is open
  let addLink: (String, String?) -> String?  // url, title → an error message, or nil when added
  let removeLink: (String) -> Void
  let save: (BoardTask) -> Void
  @State private var newUpdate = ""
  @State private var newLinkURL = ""
  @State private var newLinkTitle = ""
  @State private var linkError: String?
  @Environment(\.dismiss) private var dismiss

  // The current project stays selectable even if it has been archived since.
  private var projectNames: [String] {
    var names = projects.map(\.name)
    if let current = task.project, !names.contains(current) { names.append(current) }
    return names
  }

  private func submitLink() {
    guard !newLinkURL.isBlank else { return }
    linkError = addLink(newLinkURL, newLinkTitle.isBlank ? nil : newLinkTitle)
    if linkError == nil {
      newLinkURL = ""
      newLinkTitle = ""
    }
  }

  private func submitUpdate() {
    let text = newUpdate
    guard !text.isBlank else { return }
    addUpdate(text)
    newUpdate = ""
  }

  var body: some View {
    Form {
      TextField("Title", text: $task.title)
      Picker("Project", selection: $task.project) {
        Text("No project").tag(String?.none)
        ForEach(projectNames, id: \.self) { Text($0).tag(Optional($0)) }
      }
      TextField("Owner (a name, or “me”)", text: Binding(get: { task.owner ?? "" }, set: { task.owner = $0.isBlank ? nil : $0 }))
      Picker("Priority", selection: $task.priority) {
        ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      Section("Links") {
        HStack {
          TextField("Paste a link — Enter", text: $newLinkURL).onSubmit(submitLink)
          TextField("Title (optional)", text: $newLinkTitle).onSubmit(submitLink).frame(width: 150)
          Button("Add", action: submitLink).disabled(newLinkURL.isBlank)
        }
        if let linkError { Text(linkError).font(.caption).foregroundStyle(.red) }
        ForEach(links, id: \.url) { link in
          HStack {
            Image(systemName: LinkChips.icon(for: link))
            if let url = URL(string: link.url) {
              SourceLink(url: url, mail: link.mail) { Text(link.label).lineLimit(1) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).help(link.url)
            } else {
              Text(link.label).lineLimit(1)
            }
            Spacer()
            Button { removeLink(link.url) } label: { Image(systemName: "xmark.circle") }
              .buttonStyle(.plain).help("Remove this link")
          }
        }
      }
      Section("Updates") {
        HStack {
          TextField("Add an update — Enter", text: $newUpdate).onSubmit(submitUpdate)
          Button("Add", action: submitUpdate).disabled(newUpdate.isBlank)
        }
        if updates.isEmpty {
          Text("News about this task from email, Slack, documents and you will collect here.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(updates.reversed()) { update in
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Image(systemName: CardView.icon(for: update.source)).font(.caption2).foregroundStyle(.secondary)
                    Text(update.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    if let link = update.link.flatMap(URL.init(string:)) {
                      SourceLink(url: link, mail: update.mail) { Label("source", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                    }
                    Spacer()
                    Button { removeUpdate(update.id) } label: { Image(systemName: "xmark.circle") }
                      .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove this update")
                  }
                  Text(update.text).font(.callout).textSelection(.enabled)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        }
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

// "Add link…" from a card's menu: a URL and an optional title.
struct AddLinkSheet: View {
  let task: BoardTask
  let add: (String, String?) -> String?
  @State private var url = ""
  @State private var title = ""
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a link to #\(task.id) \(task.title)").font(.headline).lineLimit(2)
      TextField("https://…", text: $url).onSubmit(submit)
      TextField("Title (optional — a name is made from the address)", text: $title).onSubmit(submit)
      Text("Pull requests, commits and Claude artifacts are recognised; anything else is kept as a plain link.")
        .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(url.isBlank)
      }
    }
    .padding()
    .frame(width: 460)
    .onAppear {
      // A link on the clipboard is the likely thing to add.
      if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
        TaskLink.detect(url: text) != nil
      {
        url = text
      }
    }
  }

  private func submit() {
    guard !url.isBlank else { return }
    error = add(url, title.isBlank ? nil : title)
    if error == nil { dismiss() }
  }
}
