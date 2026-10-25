// A translucent always-on-top list of tasks in the top-right corner of the main screen.
// The panel never takes focus; clicking a circle marks the task done, clicking the header opens the board.
import AppKit
import SwiftUI
import TaskboardCore

final class WidgetPanel: NSPanel {
  init(model: AppModel, openBoard: @escaping () -> Void, hide: @escaping () -> Void) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    // Kept out of screen shares and recordings unless turned off: defaults write com.lozhka13.taskboard widgetCapturable -bool true
    sharingType = UserDefaults.standard.bool(forKey: "widgetCapturable") ? .readOnly : .none

    // The window follows the measured height of the content; SwiftUI's own sizing clipped wrapped rows.
    let view = WidgetView(model: model, openBoard: openBoard, hide: hide) { [weak self] height in
      self?.fit(height: height)
    }
    let hosting = NSHostingView(rootView: view.frame(maxHeight: .infinity, alignment: .top))
    hosting.sizingOptions = []
    contentView = hosting
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.pin() } }
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private let margin: CGFloat = 12
  private var contentHeight: CGFloat = 120

  private var screenFrame: NSRect? { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame }

  func fit(height: CGFloat) {
    contentHeight = ceil(height)
    pin()
  }

  // Top-right corner under the menu bar, no taller than the screen.
  func pin() {
    guard let visible = screenFrame else { return }
    let height = min(contentHeight, visible.height - margin * 2)
    setFrame(
      NSRect(x: visible.maxX - frame.width - margin, y: visible.maxY - margin - height, width: frame.width, height: height),
      display: true)
  }
}

struct WidgetView: View {
  let model: AppModel
  let openBoard: () -> Void
  let hide: () -> Void
  let resize: (CGFloat) -> Void
  @State private var hovering = false

  private let limit = 10

  var body: some View {
    let board = model.board
    let doing = board.tasks(in: .doing)
    let todo = board.tasks(in: .todo)
    // What can actually be done: a parent with open subtasks is represented by them.
    let actionable = board.ordered(
      (doing + todo).filter { task in !board.children(of: task.id).contains { $0.column != .done } })
    let shown = Array(actionable.prefix(limit))

    VStack(alignment: .leading, spacing: 6) {
      header(
        doing: doing.count, ready: actionable.filter { $0.column == .todo && !board.isBlocked($0) }.count,
        blocked: actionable.filter { $0.column == .todo && board.isBlocked($0) }.count)
      ActivityLine(activity: model.activity)
      ForEach(SyncKind.allCases.filter { model.isSyncing($0) }, id: \.self) { kind in
        Label(kind.running, systemImage: kind.icon).font(.caption).foregroundStyle(.secondary)
      }
      if !board.proposals.isEmpty { proposals(board) }
      if shown.isEmpty {
        Text("Empty. ⌃⌥⌘R — dictate a task")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(shown) { task in
        WidgetRow(
          task: task, blocked: board.isBlocked(task),
          parent: task.parent.flatMap { board.task($0) }?.title
        ) {
          model.change { board in _ = try board.update(task.id) { $0.column = .done } }
        }
      }
      let hidden = actionable.count - shown.count
      if hidden > 0 {
        Text("\(hidden) more…").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(.regularMaterial.opacity(hovering ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
    .opacity(hovering ? 1 : 0.9)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      model.ingest(urls: files, project: nil)
      return !files.isEmpty
    }
    .help("Drop a file here — it goes to the inbox, Claude reads it and files it under a project")
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resize($0) }
  }

  // Up to three proposals above the tasks: ✓ applies, ✕ drops it for good; the rest are in the board's tab.
  private func proposals(_ board: Board) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        model.boardTab = .proposals
        openBoard()
      } label: {
        Label("Proposals · \(board.proposals.count)", systemImage: "tray.and.arrow.down")
          .font(.caption).fontWeight(.semibold).foregroundStyle(Color.accentColor)
      }
      .buttonStyle(.plain)
      ForEach(board.proposals.prefix(3)) { proposal in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Button { act(proposal.id, accept: true) } label: { Image(systemName: "checkmark.circle") }
            .buttonStyle(.plain).help("Accept")
          Button { act(proposal.id, accept: false) } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Reject — it won't be proposed again")
          Text(board.line(proposal)).font(.callout).lineLimit(2).help(proposal.reason)
        }
      }
      if board.proposals.count > 3 {
        Text("\(board.proposals.count - 3) more…").font(.caption2).foregroundStyle(.secondary)
      }
      Divider()
    }
  }

  private func act(_ id: Int, accept: Bool) {
    model.change(source: "email") { board in
      if accept { try board.acceptProposal(id) } else { try board.rejectProposal(id) }
    }
  }

  private func header(doing: Int, ready: Int, blocked: Int) -> some View {
    Button(action: openBoard) {
      HStack(spacing: 6) {
        Image(systemName: "checklist")
        Text("Tasks").font(.headline)
        Spacer()
        Text("\(doing) doing · \(ready) ready" + (blocked > 0 ? " · \(blocked) waiting" : ""))
          .font(.caption).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open the board (⌃⌥⌘K)")
    .overlay(alignment: .topTrailing) {
      if hovering {
        Button(action: hide) {
          Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .help("Hide the widget (⌃⌥⌘W)")
        .offset(x: 4, y: -4)
      }
    }
  }
}

struct WidgetRow: View {
  let task: BoardTask
  let blocked: Bool
  let parent: String?
  let complete: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Button(action: complete) {
        Image(systemName: task.column == .doing ? "circle.inset.filled" : blocked ? "lock" : "circle")
          .foregroundStyle(task.column == .doing ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .help(blocked ? "Waiting on other tasks; click to mark done anyway" : "Done")
      VStack(alignment: .leading, spacing: 1) {
        Text(task.title)
          .font(.callout)
          .fontWeight(task.priority == .high ? .semibold : .regular)
          .lineLimit(2)
        if let parent {
          Text("↳ \(parent)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .opacity(blocked ? 0.55 : 1)
      Spacer(minLength: 0)
      if let project = task.project {
        Text(project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

struct ActivityLine: View {
  let activity: Activity

  var body: some View {
    switch activity {
    case .idle:
      EmptyView()
    case .recording(let since):
      TimelineView(.periodic(from: since, by: 1)) { context in
        let seconds = Int(context.date.timeIntervalSince(since))
        Label(
          String(format: "Recording %d:%02d — ⌃⌥⌘R to finish, Esc to cancel", seconds / 60, seconds % 60),
          systemImage: "mic.fill"
        )
        .font(.caption).foregroundStyle(.red)
      }
    case .transcribing:
      Label("Transcribing…", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
    case .thinking(let transcript):
      VStack(alignment: .leading, spacing: 2) {
        Label("Claude is sorting it onto the board…", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
        Text("«\(transcript)»").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
      }
    case .ingesting(let name):
      VStack(alignment: .leading, spacing: 2) {
        Label("Claude is reading the document…", systemImage: "doc.text.magnifyingglass").font(.caption)
          .foregroundStyle(.secondary)
        Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
      }
    case .message(let text, let isError):
      Label(text, systemImage: isError ? "exclamationmark.triangle" : "checkmark")
        .font(.caption).foregroundStyle(isError ? .orange : .secondary).lineLimit(4)
    }
  }
}
