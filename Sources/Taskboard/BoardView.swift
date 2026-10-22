// The full kanban: three columns, drag cards between them, double-click to edit, right-click for more.
import AppKit
import SwiftUI
import TaskboardCore

struct BoardView: View {
  let model: AppModel
  @State private var newTitle = ""
  @State private var editing: BoardTask?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Новая задача — Enter", text: $newTitle)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Text("⌃⌥⌘T — голосом").font(.caption).foregroundStyle(.secondary)
      }
      .padding(12)
      HStack(alignment: .top, spacing: 12) {
        ForEach(Column.allCases, id: \.self) { column in
          ColumnView(column: column, model: model, edit: { editing = $0 })
        }
      }
      .padding([.horizontal, .bottom], 12)
    }
    .frame(minWidth: 760, minHeight: 420)
    .sheet(item: $editing) { task in
      EditTaskView(task: task) { updated in
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
  }

  private func add() {
    let title = newTitle
    guard !title.isBlank else { return }
    model.change { $0.add(title: title, source: "manual") }
    newTitle = ""
  }
}

struct ColumnView: View {
  let column: Column
  let model: AppModel
  let edit: (BoardTask) -> Void
  @State private var targeted = false

  var body: some View {
    let tasks = model.board.tasks(in: column)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(column.title).font(.headline)
        Text("\(tasks.count)").foregroundStyle(.secondary)
      }
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(tasks) { task in
            CardView(task: task)
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
    Button("Изменить…") { edit(task) }
    ForEach(Column.allCases.filter { $0 != task.column }, id: \.self) { target in
      Button("→ \(target.title)") { model.change { board in _ = try board.update(task.id) { $0.column = target } } }
    }
    Menu("Приоритет") {
      ForEach(Priority.allCases, id: \.self) { priority in
        Button(priority.label) { model.change { board in _ = try board.update(task.id) { $0.priority = priority } } }
      }
    }
    Divider()
    Button("Скопировать") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString([task.title, task.notes].compactMap { $0 }.joined(separator: "\n\n"), forType: .string)
    }
    Button("Удалить", role: .destructive) { model.change { board in _ = try board.remove(task.id) } }
  }
}

struct CardView: View {
  let task: BoardTask

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        if task.priority == .high { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption) }
        Text(task.title).fontWeight(task.priority == .high ? .semibold : .regular)
          .strikethrough(task.column == .done, color: .secondary)
        Spacer(minLength: 0)
        Text("#\(task.id)").font(.caption2).foregroundStyle(.tertiary)
      }
      if let notes = task.notes {
        Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
      }
      HStack(spacing: 6) {
        if let project = task.project {
          Text(project).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        Image(systemName: task.source == "voice" ? "mic" : task.source == "claude" ? "sparkles" : "keyboard")
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
  let save: (BoardTask) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      TextField("Название", text: $task.title)
      TextField("Проект", text: Binding(get: { task.project ?? "" }, set: { task.project = $0.isBlank ? nil : $0 }))
      Picker("Приоритет", selection: $task.priority) {
        ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      TextField(
        "Заметки", text: Binding(get: { task.notes ?? "" }, set: { task.notes = $0.isBlank ? nil : $0 }),
        axis: .vertical
      )
      .lineLimit(4...12)
    }
    .padding()
    .frame(width: 460)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") {
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
    case .low: "Низкий"
    case .normal: "Обычный"
    case .high: "Высокий"
    }
  }
}
