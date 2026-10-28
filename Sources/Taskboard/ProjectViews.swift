// Project journal, documents, and the sheets for creating a project and pasting a note.
import AppKit
import SwiftUI
import TaskboardCore

// The journal and document folders live on disk and change without touching board.json,
// so these views re-read them every couple of seconds while visible.
struct JournalView: View {
  let model: AppModel
  let project: Project?  // nil with showsProject — every journal; nil without — the general one
  let showsProject: Bool
  @State private var entries: [LogEntry] = []
  @State private var newEntry = ""

  var body: some View {
    VStack(spacing: 0) {
      TextField(project.map { "Journal entry for “\($0.name)” — Enter" } ?? "Journal entry — Enter", text: $newEntry)
        .textFieldStyle(.roundedBorder).onSubmit(append).padding(12)
      if entries.isEmpty {
        Spacer()
        Text("Nothing here yet. Entries appear on their own as tasks change and as notes and documents come in.")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
      } else {
        List(Array(entries.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(entry.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
              if showsProject, let name = entry.project {
                Text(name).font(.caption2).padding(.horizontal, 6)
                  .background(Capsule().fill(Color.accentColor.opacity(0.15)))
              }
              Image(systemName: CardView.icon(for: entry.source)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(entry.text).textSelection(.enabled)
          }
        }
      }
    }
    .task(id: project?.slug ?? (showsProject ? "*" : "")) {
      while !Task.isCancelled {
        load()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func load() {
    let fresh =
      showsProject
      ? ProjectLog.allEntries(projects: model.board.projects, limit: 300) : ProjectLog.entries(of: project, limit: 300)
    if fresh != entries { entries = fresh }
  }

  private func append() {
    let text = newEntry
    let target = project
    guard !text.isBlank else { return }
    try? BoardStore.change(source: "manual") { _ in ProjectLog.append(text, source: "manual", project: target) }
    newEntry = ""
    load()
  }
}

struct DocumentsView: View {
  let model: AppModel
  let project: Project?  // nil — the inbox
  @State private var files: [URL] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(
        project == nil
          ? "Inbox: everything dropped on the widget or this window without a project lands here. Claude will read it and file it under a project."
          : "Project documents and notes. Drop a file on the window — Claude will read it and log the gist."
      )
      .font(.caption).foregroundStyle(.secondary).padding(12)
      if files.isEmpty {
        Spacer()
        HStack {
          Spacer()
          Label("No files", systemImage: "tray").foregroundStyle(.secondary)
          Spacer()
        }
        Spacer()
      } else {
        List(files, id: \.self) { url in
          HStack {
            Image(systemName: "doc.text")
            Text(url.lastPathComponent).lineLimit(1)
            Spacer()
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
          }
          .contentShape(Rectangle())
          .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        }
      }
    }
    .task(id: project?.slug ?? "") {
      while !Task.isCancelled {
        let fresh = ProjectDocuments.list(slug: project?.slug)
        if fresh != files { files = fresh }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}

// A check's status and trigger: spinner while it runs, otherwise when it last ran (or what went wrong).
struct SyncButton: View {
  let model: AppModel
  let kind: SyncKind
  @State private var showReport = false

  var body: some View {
    let running = model.isSyncing(kind)
    HStack(spacing: 6) {
      if let report = model.sync.report(kind), !running {
        Button { showReport = true } label: { Image(systemName: "list.bullet.clipboard") }
          .buttonStyle(.plain).help("What the last \(kind.title) check looked at")
          .popover(isPresented: $showReport) { CheckReportView(kind: kind, report: report) }
      }
      if let error = model.sync.lastError(kind), !running {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
      } else if let last = model.sync.lastRun(kind), !running {
        Text("checked \(last, format: .relative(presentation: .numeric))").font(.caption).foregroundStyle(.secondary)
      }
      Button { model.sync(kind, manual: true) } label: {
        if running {
          ProgressView().controlSize(.small)
        } else {
          Label(kind.title, systemImage: kind.icon)
        }
      }
      .disabled(running)
      .help(
        {
          switch kind {
          case .email: "Check the inbox for the last few days: journal entries and proposals (read-only)"
          case .slack: "Check Slack — mapped channels, mentions and direct messages — for the last few days (read-only)"
          }
        }())
    }
  }
}

// What a check looked at — names, counts and outcomes, never message text — so gaps in coverage are visible.
struct CheckReportView: View {
  let kind: SyncKind
  let report: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Last \(kind.title) check — what it looked at").font(.headline)
      ScrollView {
        Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
    .frame(width: 520, height: 320)
  }
}

// What the assistant noticed but left to the user: accept applies it (and journals it), reject drops it for good.
struct ProposalsView: View {
  let model: AppModel

  var body: some View {
    let board = model.board
    VStack(spacing: 0) {
      if board.proposals.isEmpty {
        Spacer()
        VStack(spacing: 6) {
          Label("No proposals", systemImage: "checkmark.circle").foregroundStyle(.secondary)
          Text("Tasks and status changes found in your email wait here for your yes or no.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      } else {
        HStack {
          Text("\(board.proposals.count) waiting").font(.headline)
          Spacer()
          Button("Accept all") { act(board.proposals.map(\.id), accept: true) }
          Button("Reject all", role: .destructive) { act(board.proposals.map(\.id), accept: false) }
        }
        .padding(12)
        List(board.proposals) { proposal in
          ProposalRow(
            proposal: proposal, line: board.line(proposal), projects: board.activeProjects,
            accept: { act([proposal.id], accept: true) }, reject: { act([proposal.id], accept: false) },
            setProject: { name in
              model.change(source: "manual") { board in try board.setProposalProject(proposal.id, name) }
            })
        }
      }
    }
  }

  private func act(_ ids: [Int], accept: Bool) {
    model.change(source: "email") { board in
      for id in ids {
        if accept { try board.acceptProposal(id) } else { try board.rejectProposal(id) }
      }
    }
  }
}

struct ProposalRow: View {
  let proposal: Proposal
  let line: String
  let projects: [Project]
  let accept: () -> Void
  let reject: () -> Void
  let setProject: (String?) -> Void

  // What the assistant proposed (proposals saved before it was remembered: the project they have now).
  private var suggested: String? { proposal.suggestedProject ?? proposal.project }

  private var projectNames: [String] {
    var names = projects.map(\.name)
    if let current = proposal.project, !names.contains(current) { names.append(current) }  // archived since
    return names
  }

  // "Project ▾" for a proposed task: the assistant's pick is preselected and marked, and wherever the user puts it is
  // where the task lands when accepted — with this row's button, the widget's ✓ or "Accept all".
  private var projectPicker: some View {
    HStack(spacing: 6) {
      Text("Project").font(.caption2).foregroundStyle(.secondary)
      Picker(
        "Project", selection: Binding(get: { proposal.project }, set: { setProject($0) })
      ) {
        Text("No project" + (suggested == nil ? "  ·  AI" : "")).tag(String?.none)
        ForEach(projectNames, id: \.self) { name in
          Text(name + (name == suggested ? "  ·  AI" : "")).tag(Optional(name))
        }
      }
      .labelsHidden().pickerStyle(.menu).fixedSize()
      .help("Where the task goes when you accept it. “AI” marks what the assistant proposed.")
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(line).fontWeight(.medium)
        Text(proposal.reason).font(.caption).foregroundStyle(.secondary)
        if proposal.kind == .addTask, let owner = proposal.owner, owner != "me" {
          Label("for \(owner)", systemImage: "person").font(.caption2).foregroundStyle(.orange)
        }
        if let notes = proposal.notes { Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        if proposal.kind == .addTask { projectPicker }
        HStack(spacing: 6) {
          Image(systemName: proposal.sourceKind == "slack" ? "number" : "envelope")
            .font(.caption2).foregroundStyle(.tertiary)
          if proposal.kind == .linkTask, let link = proposal.link, let url = URL(string: link.url) {
            Link("Open \(link.identity)", destination: url).font(.caption2).lineLimit(1)
          } else if let subject = proposal.sourceTitle {
            if let link = proposal.sourceLink.flatMap(URL.init(string:)) {
              SourceLink(url: link, mail: proposal.mail) { Text(subject).lineLimit(1) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption2)
            } else {
              Text(subject).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          Spacer()
        }
      }
      Spacer(minLength: 0)
      Button(action: accept) { Label("Accept", systemImage: "checkmark") }.buttonStyle(.borderedProminent)
      Button(action: reject) { Image(systemName: "xmark") }.help("Reject — it won't be proposed again")
    }
    .padding(.vertical, 4)
  }
}

enum ProjectFormMode: Identifiable {
  case new
  case edit(Project)

  var id: String {
    switch self {
    case .new: "new"
    case .edit(let project): project.slug
    }
  }
}

struct ProjectForm: View {
  let mode: ProjectFormMode
  let save: (String, String?, ProjectStatus?, [String]) -> Void
  @State private var name = ""
  @State private var summary = ""
  @State private var channels = ""
  @State private var status = ProjectStatus.active
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      TextField("Name", text: $name)
      TextField("What the project is about", text: $summary, axis: .vertical).lineLimit(2...6)
      TextField("Slack channels (#jssi, #deals)", text: $channels, axis: .vertical).lineLimit(1...3)
        .help("Channels, public or private, that the Slack check reads for this project; comma-separated")
      if case .edit = mode {
        Picker("Status", selection: $status) {
          ForEach(ProjectStatus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      }
    }
    .padding()
    .frame(width: 440)
    .onAppear {
      if case .edit(let project) = mode {
        name = project.name
        summary = project.summary ?? ""
        channels = project.slackChannels.joined(separator: ", ")
        status = project.status
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          save(name, summary, { if case .edit = mode { status } else { nil } }(), Project.parseChannels(channels))
          dismiss()
        }
        .disabled(name.isBlank)
      }
    }
  }
}

struct NoteSheet: View {
  let projects: [Project]
  let preselected: Project?
  let send: (String, Project?) -> Void
  @State private var text = ""
  @State private var slug: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Note or meeting minutes").font(.headline)
      Text("Claude will read the text, log the gist in the project journal and add tasks where they are explicit.")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Project", selection: $slug) {
        Text("Detect from the text").tag(String?.none)
        ForEach(projects) { Text($0.name).tag(Optional($0.slug)) }
      }
      TextEditor(text: $text).font(.body).frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Send") {
          send(text, projects.first { $0.slug == slug })
          dismiss()
        }
        .keyboardShortcut(.defaultAction).disabled(text.isBlank)
      }
    }
    .padding()
    .frame(width: 520)
    .onAppear { slug = preselected?.slug }
  }
}
