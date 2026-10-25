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
      TextField(project.map { "Запись в журнал «\($0.name)» — Enter" } ?? "Запись в журнал — Enter", text: $newEntry)
        .textFieldStyle(.roundedBorder).onSubmit(append).padding(12)
      if entries.isEmpty {
        Spacer()
        Text("Пока пусто. Записи появляются сами при изменении задач, из заметок и документов.")
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
          ? "Входящие: сюда попадает всё, что перетащено на виджет или в это окно без проекта. Claude разберёт и переложит в проект."
          : "Документы и заметки проекта. Перетащите файл в окно — Claude прочитает и запишет в журнал."
      )
      .font(.caption).foregroundStyle(.secondary).padding(12)
      if files.isEmpty {
        Spacer()
        HStack {
          Spacer()
          Label("Файлов нет", systemImage: "tray").foregroundStyle(.secondary)
          Spacer()
        }
        Spacer()
      } else {
        List(files, id: \.self) { url in
          HStack {
            Image(systemName: "doc.text")
            Text(url.lastPathComponent).lineLimit(1)
            Spacer()
            Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
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
  let save: (String, String?, ProjectStatus?) -> Void
  @State private var name = ""
  @State private var summary = ""
  @State private var status = ProjectStatus.active
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      TextField("Название", text: $name)
      TextField("О чём проект", text: $summary, axis: .vertical).lineLimit(2...6)
      if case .edit = mode {
        Picker("Статус", selection: $status) {
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
        status = project.status
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") {
          save(name, summary, { if case .edit = mode { status } else { nil } }())
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
      Text("Заметка или протокол").font(.headline)
      Text("Claude прочитает текст, запишет итоги в журнал проекта и заведёт задачи, где они названы явно.")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Проект", selection: $slug) {
        Text("Определить по тексту").tag(String?.none)
        ForEach(projects) { Text($0.name).tag(Optional($0.slug)) }
      }
      TextEditor(text: $text).font(.body).frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
      HStack {
        Spacer()
        Button("Отмена") { dismiss() }
        Button("Отправить") {
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
