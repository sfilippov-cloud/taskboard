// Attached documents and notes: projects/<slug>/docs/, and inbox/ for files not yet filed under a project.
// Text is pulled out of plain text, PDF, RTF and DOCX so Claude can read it; other files are kept as they are.
import Foundation
import PDFKit

public enum DocumentError: LocalizedError {
  case unsupported(String)
  case unreadable(String)
  case noFile(String)

  public var errorDescription: String? {
    switch self {
    case .unsupported(let name): "Can't extract text from “\(name)” (unsupported format); the file is saved as is"
    case .unreadable(let name): "Couldn't read “\(name)”"
    case .noFile(let name): "No file “\(name)”"
    }
  }
}

public enum ProjectDocuments {
  public static var inboxDirectory: URL { BoardStore.directory.appendingPathComponent("inbox", isDirectory: true) }

  public static func directory(slug: String?) -> URL {
    guard let slug else { return inboxDirectory }
    return ProjectLog.directory(slug: slug).appendingPathComponent("docs", isDirectory: true)
  }

  static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "log", "html", "htm", "eml", "yaml", "yml"]
  static let richExtensions: [String: NSAttributedString.DocumentType] = [
    "rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat,
  ]

  // Copies a file into the project's docs (or the inbox) under a date-prefixed unique name.
  @discardableResult
  public static func attach(_ source: URL, slug: String?, now: Date = Date()) throws -> URL {
    let folder = directory(slug: slug)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = uniqueURL(in: folder, name: prefixed(source.lastPathComponent, now))
    try FileManager.default.copyItem(at: source, to: target)
    return target
  }

  // A pasted note becomes a Markdown file next to the documents.
  @discardableResult
  public static func saveNote(_ text: String, slug: String?, now: Date = Date()) throws -> URL {
    let folder = directory(slug: slug)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = text.components(separatedBy: .newlines).first { !$0.isBlank } ?? "note"
    let title = first.prefix(40).map { "/:\\\n".contains($0) ? "-" : String($0) }.joined()
      .trimmingCharacters(in: .whitespaces)
    let target = uniqueURL(in: folder, name: prefixed(title + ".md", now))
    try text.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  // Newest first.
  public static func list(slug: String?) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: directory(slug: slug), includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles])) ?? []
    return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  // Inbox → project docs. Only a bare file name is accepted: no way out of the folder.
  @discardableResult
  public static func file(inboxName name: String, into slug: String) throws -> URL {
    let source = try resolve(name, slug: nil)
    let folder = directory(slug: slug)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = uniqueURL(in: folder, name: source.lastPathComponent)
    try FileManager.default.moveItem(at: source, to: target)
    return target
  }

  public static func resolve(_ name: String, slug: String?) throws -> URL {
    let bare = URL(fileURLWithPath: name).lastPathComponent
    guard bare == name, !name.hasPrefix(".") else { throw DocumentError.noFile(name) }
    let url = directory(slug: slug).appendingPathComponent(bare)
    guard FileManager.default.fileExists(atPath: url.path) else { throw DocumentError.noFile(name) }
    return url
  }

  public static func extractText(_ url: URL, limit: Int = 60_000) throws -> String {
    let ext = url.pathExtension.lowercased()
    var text: String?
    if textExtensions.contains(ext) {
      text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1251))
    } else if ext == "pdf" {
      text = PDFDocument(url: url)?.string
    } else if let type = richExtensions[ext] {
      let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
      text = (try? NSAttributedString(url: url, options: options, documentAttributes: nil))?.string
    } else {
      throw DocumentError.unsupported(url.lastPathComponent)
    }
    guard let text, !text.isBlank else { throw DocumentError.unreadable(url.lastPathComponent) }
    return text.count > limit ? String(text.prefix(limit)) + "\n…[truncated: \(text.count) characters]" : text
  }

  private static func prefixed(_ name: String, _ now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: now) + " " + name
  }

  private static func uniqueURL(in folder: URL, name: String) -> URL {
    var url = folder.appendingPathComponent(name)
    var counter = 2
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent(base + " (\(counter))" + (ext.isEmpty ? "" : "." + ext))
      counter += 1
    }
    return url
  }
}

extension String {
  var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
