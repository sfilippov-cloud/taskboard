// Opens an email in the Mail app. The Gmail connector doesn't give a message's RFC 822 Message-ID (which Mail's
// message:// links need) except inside the full raw message, so the message is found in Mail by what we do know — its
// subject, sender and date — through Mail's scripting, and its Message-ID is read from Mail itself. If Mail can't be
// asked or doesn't have the message, the Gmail web link opens instead — and the app says why (and logs it), so that a
// silent fallback never hides a missing permission or an account that isn't in Mail.
import AppKit
import Foundation
import TaskboardCore

enum MailOpener {
  // "Open emails in Mail": on by default; off sends every email link to the browser.
  static var usesMail: Bool { UserDefaults.standard.object(forKey: "openEmailInMail") as? Bool ?? true }

  // Where problems are shown (the app wires it to the widget's message line).
  @MainActor static var onProblem: ((String) -> Void)?

  enum Outcome: Equatable {
    case found(String)
    case notFound
    case noAccounts
    case notAllowed
    case timedOut
    case failed(Int)

    var label: String {
      switch self {
      case .found: "found"
      case .notFound: "notFound"
      case .noAccounts: "noAccounts"
      case .notAllowed: "notAllowed"
      case .timedOut: "timedOut"
      case .failed(let code): "failed(\(code))"
      }
    }

    // What to tell the user when the web link had to be used instead; nil when Mail opened the message.
    var problem: String? {
      switch self {
      case .found: nil
      case .notFound:
        "Couldn't find that email in Mail — is the Gmail account added to Mail and synced? Opened the web link instead."
      case .noAccounts: "Mail has no accounts set up. Opened the web link instead."
      case .notAllowed:
        "macOS hasn't allowed Taskboard to control Mail (System Settings → Privacy & Security → Automation → Taskboard → Mail). Opened the web link instead."
      case .timedOut: "Mail took too long to search. Opened the web link instead."
      case .failed(let code): "The Mail lookup failed (error \(code)). Opened the web link instead."
      }
    }
  }

  private static let queue = DispatchQueue(label: "taskboard.mail-finder")

  @MainActor
  static func open(webURL: URL, mail: MailRef?) {
    guard usesMail, let mail else {
      NSWorkspace.shared.open(webURL)
      return
    }
    queue.async {
      let started = Date()
      let outcome = find(mail)
      log(outcome, mail: mail, seconds: Date().timeIntervalSince(started))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if case .found(let id) = outcome, let url = MailRef.messageURL(forMessageID: id) {
            NSWorkspace.shared.open(url)
          } else {
            NSWorkspace.shared.open(webURL)
            if let problem = outcome.problem { onProblem?(problem) }
          }
        }
      }
    }
  }

  // The values go in as handler arguments, never spliced into the script text: a subject comes from somebody else's email.
  // Every mailbox of every account is searched (Gmail's "All Mail" is named in the account's language, so no names are
  // assumed), the inbox first, narrowed by the date window when there is one.
  static let script = """
    on find_message(theSubject, theFrom, startEpoch, endEpoch)
      with timeout of 25 seconds
        set theNow to current date
        set nowEpoch to (do shell script "date +%s") as integer
        set d1 to theNow - (nowEpoch - startEpoch)
        set d2 to theNow - (nowEpoch - endEpoch)
        tell application "Mail"
          if (count of accounts) is 0 then return "NOACCOUNTS"
          repeat with acct in accounts
            set boxes to {}
            try
              set end of boxes to inbox of acct
            end try
            try
              repeat with top in (every mailbox of acct)
                set end of boxes to top
                try
                  repeat with child in (every mailbox of top)
                    set end of boxes to child
                  end repeat
                end try
              end repeat
            end try
            repeat with mb in boxes
              try
                if endEpoch > 0 then
                  set hits to (messages of mb whose date received is greater than or equal to d1 and date received is less than or equal to d2 and subject contains theSubject)
                else
                  set hits to (messages of mb whose subject contains theSubject)
                end if
                repeat with m in hits
                  if theFrom is "" or (sender of m) contains theFrom then return message id of m
                end repeat
              end try
            end repeat
          end repeat
        end tell
        return ""
      end timeout
    end find_message
    """

  private static func find(_ mail: MailRef) -> Outcome {
    guard let compiled = NSAppleScript(source: script) else { return .failed(0) }
    var error: NSDictionary?
    guard compiled.compileAndReturnError(&error) else { return .failed((error?[NSAppleScript.errorNumber] as? Int) ?? 0) }

    // A message's own date is when it was sent; Mail stamps when it arrived: a day and a half either way is plenty.
    let (start, end): (Int, Int) =
      mail.date.map { (Int($0.timeIntervalSince1970) - 129_600, Int($0.timeIntervalSince1970) + 129_600) } ?? (0, 0)
    let list = NSAppleEventDescriptor.list()
    for (position, value) in [mail.coreSubject, mail.fromAddress ?? ""].enumerated() {
      list.insert(NSAppleEventDescriptor(string: value), at: position + 1)
    }
    list.insert(NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: start)), at: 3)
    list.insert(NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: end)), at: 4)

    // A call to a handler: 'ascr'/'psbr' with the name (lowercase) in 'snam' and the arguments as the direct object.
    let event = NSAppleEventDescriptor(
      eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: NSAppleEventDescriptor.currentProcess(),
      returnID: -1, transactionID: 0)
    event.setParam(NSAppleEventDescriptor(string: "find_message"), forKeyword: 0x736E_616D)
    event.setParam(list, forKeyword: 0x2D2D_2D2D)
    let result = compiled.executeAppleEvent(event, error: &error)
    if let error {
      switch (error[NSAppleScript.errorNumber] as? Int) ?? 0 {
      case -1743: return .notAllowed
      case -1712: return .timedOut
      case let code: return .failed(code)
      }
    }
    switch result.stringValue ?? "" {
    case "": return .notFound
    case "NOACCOUNTS": return .noAccounts
    case let id: return .found(id)
    }
  }

  // One line per lookup in mail-open.log in the data folder: what happened, never what the email says.
  private static func log(_ outcome: Outcome, mail: MailRef, seconds: Double) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = String(
      format: "%@ · %@ · subject %d chars · from %@ · date %@ · %.1fs\n", formatter.string(from: Date()), outcome.label,
      mail.coreSubject.count, mail.fromAddress == nil ? "no" : "yes", mail.date == nil ? "no" : "yes", seconds)
    let url = BoardStore.directory.appendingPathComponent("mail-open.log")
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
}
