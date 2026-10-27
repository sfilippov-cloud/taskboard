// Opens an email in the Mail app. The Gmail connector doesn't give a message's RFC 822 Message-ID (which Mail's
// message:// links need) except inside the full raw message, so the message is found in Mail by what we do know — its
// subject, sender and date — through Mail's scripting, and its Message-ID is read from Mail itself. If Mail can't be
// asked (no permission, the account isn't in Mail, not found in time), the Gmail web link opens instead.
import AppKit
import Foundation
import TaskboardCore

enum MailOpener {
  // "Open emails in Mail": on by default; off sends every email link to the browser.
  static var usesMail: Bool { UserDefaults.standard.object(forKey: "openEmailInMail") as? Bool ?? true }

  private static let queue = DispatchQueue(label: "taskboard.mail-finder")

  static func open(webURL: URL, mail: MailRef?) {
    guard usesMail, let mail else {
      NSWorkspace.shared.open(webURL)
      return
    }
    queue.async {
      let id = findMessageID(mail)
      DispatchQueue.main.async {
        if let id, let url = MailRef.messageURL(forMessageID: id) { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(webURL) }
      }
    }
  }

  // The values go in as handler arguments, never spliced into the script text: a subject comes from somebody else's email.
  static let script = """
    on find_message(theSubject, theFrom, startEpoch, endEpoch)
      with timeout of 25 seconds
        set theNow to current date
        set nowEpoch to (do shell script "date +%s") as integer
        tell application "Mail"
          repeat with acct in accounts
            repeat with boxPath in {"INBOX", "[Gmail]/All Mail", "All Mail"}
              try
                set mb to mailbox (contents of boxPath) of acct
                if endEpoch > 0 then
                  set d1 to theNow - (nowEpoch - startEpoch)
                  set d2 to theNow - (nowEpoch - endEpoch)
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

  private static func findMessageID(_ mail: MailRef) -> String? {
    guard let compiled = NSAppleScript(source: script) else { return nil }
    var error: NSDictionary?
    guard compiled.compileAndReturnError(&error) else { return nil }

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
    guard error == nil, let id = result.stringValue, !id.isEmpty else { return nil }
    return id
  }
}
