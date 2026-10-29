// Developer tool: `TASKBOARD_DIR=<scratch folder> Taskboard --snapshot <output folder>` draws the main screens from
// sample data into PNG files and exits. It reads no window contents from the screen, so a layout change can be
// looked at without the real board (the folder in TASKBOARD_DIR is where the sample board is written).
import AppKit
import SwiftUI
import TaskboardCore

@MainActor
enum Snapshot {
  static func run(into folder: URL) -> Int32 {
    guard ProcessInfo.processInfo.environment["TASKBOARD_DIR"] != nil else {
      FileHandle.standardError.write(Data("Set TASKBOARD_DIR to a scratch folder: the sample board is written there.\n".utf8))
      return 2
    }
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sample = writeSampleBoard()
    let model = AppModel()
    let scales = ProcessInfo.processInfo.environment["SNAPSHOT_SCALES"]?.split(separator: ",").compactMap { Double($0) } ?? [1]

    for scale in scales {
      TextScale.shared.set(CGFloat(scale), remember: false)
      let tag = scale == 1 ? "" : "@\(scale)"
      for dark in [false, true] {
        let mode = dark ? "dark" : "light"
        func save(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: some View) {
          render(
            view, width: width, height: height, dark: dark, to: folder.appendingPathComponent("\(name)-\(mode)\(tag).png"))
        }
        save("edit", width: 560 * scale, editSheet(sample, updates: true))
        save("edit-empty", width: 560 * scale, editSheet(sample, updates: false))
        save("project-form", width: 460 * scale, ProjectForm(mode: .edit(model.board.projects[0])) { _, _, _, _ in })
        save("add-link", width: 480 * scale, AddLinkSheet(task: sample) { _, _ in nil })
        save("widget", width: 300 * scale, WidgetView(model: model, openBoard: {}, hide: {}, resize: { _ in }))
        save("board", width: 1000, height: 640, BoardView(model: model))
      }
    }
    return 0
  }

  private static func editSheet(_ task: BoardTask, updates: Bool) -> some View {
    EditTaskView(
      task: task, projects: [], updates: updates ? task.updates : [], addUpdate: { _ in }, removeUpdate: { _ in },
      links: task.links, addLink: { _, _ in nil }, removeLink: { _ in }, save: { _ in })
  }

  // Wingform and JSSI with a handful of tasks, one of them with links and updates, one proposal.
  private static func writeSampleBoard() -> BoardTask {
    try? BoardStore.change(source: "snapshot") { board in
      for name in ["JSSI", "Wingform"] { _ = try board.addProject(name: name, summary: "About the \(name) platform") }
      board.add(title: "Set up marketing (social, ads, email, webinars)", notes: "Tier 1 priority from the roadmap", project: "Wingform", owner: "me", priority: .high, source: "document")
      board.add(title: "Respond to the legal cease-and-desist over unauthorized listings", project: "Wingform", owner: "me", priority: .high, source: "slack")
      board.add(title: "Onboarding 2FA policy", project: "Wingform", column: .doing, source: "manual")
      board.add(title: "Pricing model from Max", project: "Wingform", owner: "Max", column: .doing, source: "slack")
      board.add(title: "Create payment link for the enterprise plan", project: "Wingform", column: .done, source: "slack")
      board.add(title: "Fix the KYC callback retry", project: "JSSI", source: "manual")
      let task = board.add(
        title: "Review Max's \"Cost Comparison\" doc and the onboarding plan", notes: "From slack: #commercial-development: Max shared pricing/onboarding/CRM-comparison docs for review",
        project: "Wingform", owner: "me", source: "slack")
      try board.attach(
        TaskLink(kind: "slack", title: "slack “#commercial-development: Max shared pricing…”", url: "https://example.slack.com/archives/C0123/p1700000000"),
        to: task.id)
      try board.attach(
        TaskLink(kind: "link", title: "Cost comparison", url: "https://docs.example.com/document/d/abcdef/edit"), to: task.id)
      try board.addUpdate(task.id, text: "Max asked again for feedback before Monday's call; the seat-based pricing is the open question.", source: "slack", link: "https://example.slack.com/archives/C0123/p1700000001")
      try board.addUpdate(task.id, text: "Added to the Monday agenda with Andrew.", source: "manual")
      try board.proposeTask(ProposalDraft(title: "Book the Monday sync with Andrew", project: "Wingform", owner: "me", reason: "Mentioned in a DM", sourceKind: "slack", sourceTitle: "DM with Andrew"))
    }
    return BoardStore.load().tasks.last { $0.links.count > 1 } ?? BoardTask(id: 0, title: "?", source: "manual")
  }

  private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, dark: Bool, to url: URL) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).textScaled())
    host.appearance = appearance
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 800), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 800)
    host.layoutSubtreeIfNeeded()
    let size = NSSize(width: width, height: height ?? ceil(host.fittingSize.height))
    window.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
