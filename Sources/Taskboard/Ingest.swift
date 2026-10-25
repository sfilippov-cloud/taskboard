// Documents and notes: stored in the project (or the inbox), then Claude reads them, writes the journal
// and, where the text is explicit, adds tasks. A failed Claude run never loses the file: it's already saved.
import Foundation
import TaskboardCore

extension AppModel {
  func ingest(urls: [URL], project: Project?) {
    let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
    guard !files.isEmpty else {
      show("Folders aren't supported — drop files instead", isError: true)
      return
    }
    enqueue { [self] in
      for url in files {
        do {
          let stored = try ProjectDocuments.attach(url, slug: project?.slug)
          await digest(stored, project: project)
        } catch {
          show("Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)", isError: true)
        }
      }
    }
  }

  func ingest(note: String, project: Project?) {
    guard !note.isBlank else { return }
    enqueue { [self] in
      do {
        let stored = try ProjectDocuments.saveNote(note, slug: project?.slug)
        await digest(stored, project: project)
      } catch {
        show("Couldn't save the note: \(error.localizedDescription)", isError: true)
      }
    }
  }

  // One at a time: Claude runs would otherwise fight over the status line.
  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = ingestQueue
    ingestQueue = Task { @MainActor in
      await previous?.value
      await work()
    }
  }

  private func digest(_ stored: URL, project: Project?) async {
    let name = stored.lastPathComponent
    let text: String
    do {
      text = try ProjectDocuments.extractText(stored)
    } catch {
      journal("File “\(name)” saved without being read: \(error.localizedDescription)", project: project)
      show(error.localizedDescription)
      return
    }

    activity = .ingesting(name)
    let place =
      project.map { "Project: \($0.name) (the document is already in its folder)." }
      ?? "No project given: the document is in the inbox (file \"\(name)\")."
    // The closing tag inside the text must not end the data block early.
    let safe = text.replacingOccurrences(of: "</document>", with: "</ document>")
    let prompt = "Document “\(name)”.\n\(place)\n\nContents:\n<document>\n\(safe)\n</document>"
    do {
      let summary = try await ClaudeRunner.process(document: prompt)
      reload()
      show(summary)
    } catch {
      journal("File “\(name)” saved, but Claude couldn't read it: \(error.localizedDescription)", project: project)
      show("\(error.localizedDescription) — the file is saved; you can retry the analysis later", isError: true)
    }
  }

  private func journal(_ text: String, project: Project?) {
    try? BoardStore.change(source: "document") { _ in ProjectLog.append(text, source: "document", project: project) }
  }
}
