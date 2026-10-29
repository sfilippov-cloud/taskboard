// Menu bar item, global shortcuts and the voice-note pipeline: record → transcribe → Claude → board.
import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import TaskboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private let recorder = VoiceRecorder()
  private var statusItem: NSStatusItem!
  private var widget: WidgetPanel!
  private var boardWindow: NSWindow?
  private var hotKeys: [HotKey] = []
  private var cancelKey: HotKey?
  private var busy = false
  private var syncTimer: Timer?

  private let shortcut = controlKey | optionKey | cmdKey

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.menu = buildMenu()
    updateIcon()

    widget = WidgetPanel(
      model: model, openBoard: { [weak self] in self?.showBoard() }, hide: { [weak self] in self?.toggleWidget() })
    widget.pin()
    model.onActivityChange = { [weak self] in
      self?.updateWidgetVisibility()
      self?.updateIcon()
    }
    model.onBoardChange = { [weak self] in self?.updateBadges() }
    MailOpener.onProblem = { [weak self] text in self?.model.show(text, isError: true) }
    updateBadges()
    updateWidgetVisibility()
    NSApp.mainMenu = buildMainMenu()
    watchTextSizeKey()
    if Self.opensBoardAtLaunch { showBoard() }

    hotKeys = [
      HotKey(keyCode: kVK_ANSI_R, modifiers: shortcut, id: 1) { [weak self] in self?.toggleRecording() },
      HotKey(keyCode: kVK_ANSI_K, modifiers: shortcut, id: 2) { [weak self] in self?.showBoard() },
      HotKey(keyCode: kVK_ANSI_W, modifiers: shortcut, id: 4) { [weak self] in self?.toggleWidget() },
    ]

    // Automatic email checks: looked at every few minutes, run when the interval has passed.
    syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        for kind in SyncKind.allCases where self?.model.isAutoSyncDue(kind) == true { self?.model.sync(kind, manual: false) }
      }
    }
  }

  // MARK: - Menu

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(item("Dictate a task", #selector(toggleRecordingAction), key: "r"))
    menu.addItem(item("Open board", #selector(showBoardAction), key: "k"))
    menu.addItem(item(SyncKind.email.menuTitle, #selector(syncEmailAction)))
    menu.addItem(item(SyncKind.slack.menuTitle, #selector(syncSlackAction)))
    menu.addItem(item("Show widget", #selector(toggleWidget), key: "w"))
    menu.addItem(.separator())
    menu.addItem(item("Show in Dock", #selector(toggleDock)))
    menu.addItem(item("Open board at launch", #selector(toggleOpenBoardAtLaunch)))
    menu.addItem(item("Open emails in Mail", #selector(toggleOpenEmailInMail)))
    menu.addItem(item("Launch at login", #selector(toggleLoginItem)))
    menu.addItem(item("Data folder", #selector(openDataFolder)))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    return menu
  }

  private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option, .command] }
    item.target = self
    return item
  }

  // Proposals wait for a yes or no, and are easy to miss: the count goes on the Dock icon and next to the
  // menu bar icon, and disappears when the queue is empty.
  private func updateBadges() {
    let count = model.board.proposals.count
    NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    statusItem.button?.title = count > 0 ? " \(count)" : ""
    statusItem.button?.imagePosition = count > 0 ? .imageLeading : .imageOnly
    statusItem.button?.toolTip = count > 0 ? "\(count) proposal\(count == 1 ? "" : "s") waiting" : nil
  }

  private func updateIcon() {
    let symbol: String
    switch model.activity {
    case .recording: symbol = "mic.fill"
    case .transcribing, .thinking, .ingesting: symbol = "ellipsis.circle"
    default: symbol = "checklist"
    }
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Taskboard")
    statusItem.button?.contentTintColor = if case .recording = model.activity { .systemRed } else { nil }
  }

  private func setActivity(_ activity: Activity) {
    model.activity = activity
    updateIcon()
  }

  @objc private func toggleRecordingAction() { toggleRecording() }
  @objc private func showBoardAction() { showBoard() }
  @objc private func syncEmailAction() { model.sync(.email, manual: true) }
  @objc private func syncSlackAction() { model.sync(.slack, manual: true) }

  // Hidden by the user; still shown while a voice note is recorded and processed.
  private var widgetHidden: Bool {
    get { !(UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true) }
    set { UserDefaults.standard.set(!newValue, forKey: "widgetVisible") }
  }

  @objc private func toggleWidget() {
    widgetHidden.toggle()
    updateWidgetVisibility()
  }

  private func updateWidgetVisibility() {
    if !widgetHidden || model.activity != .idle {
      widget.orderFrontRegardless()
    } else {
      widget.orderOut(nil)
    }
  }

  // MARK: - Dock

  static var showsInDock: Bool { UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true }
  static var opensBoardAtLaunch: Bool { UserDefaults.standard.object(forKey: "openBoardAtLaunch") as? Bool ?? true }

  @objc private func toggleDock() {
    let show = !Self.showsInDock
    UserDefaults.standard.set(show, forKey: "showInDock")
    NSApp.setActivationPolicy(show ? .regular : .accessory)
    // Switching policy deactivates the app; bring the board back if it is open so nothing seems to vanish.
    if boardWindow?.isVisible == true { NSApp.activate() }
  }

  @objc private func toggleOpenEmailInMail() {
    UserDefaults.standard.set(!MailOpener.usesMail, forKey: "openEmailInMail")
  }

  @objc private func toggleOpenBoardAtLaunch() {
    UserDefaults.standard.set(!Self.opensBoardAtLaunch, forKey: "openBoardAtLaunch")
  }

  // Closing the board window leaves the app (widget, menu bar, hotkeys) running; the Dock icon brings it back.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showBoard() }
    return true
  }

  // MARK: - Main menu (a regular app has one: Cmd+C/V/Z in text fields, Cmd+W, Cmd+Q and Window all live here)

  private func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    func add(_ menu: NSMenu, title: String) {
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      holder.submenu = menu
      main.addItem(holder)
    }
    func standard(_ title: String, _ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = mask
      return item
    }

    let app = NSMenu(title: "Taskboard")
    let about = NSMenuItem(title: "About Taskboard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(about)
    app.addItem(.separator())
    app.addItem(item("Show in Dock", #selector(toggleDock)))
    app.addItem(item("Open board at launch", #selector(toggleOpenBoardAtLaunch)))
    app.addItem(item("Open emails in Mail", #selector(toggleOpenEmailInMail)))
    app.addItem(item("Launch at login", #selector(toggleLoginItem)))
    app.addItem(.separator())
    app.addItem(standard("Hide Taskboard", #selector(NSApplication.hide(_:)), "h"))
    app.addItem(standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
    app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
    app.addItem(.separator())
    app.addItem(standard("Quit Taskboard", #selector(NSApplication.terminate(_:)), "q"))
    add(app, title: "Taskboard")

    let actions = NSMenu(title: "Actions")
    actions.addItem(item("Open board", #selector(showBoardAction), key: "k"))
    actions.addItem(item("Dictate a task", #selector(toggleRecordingAction), key: "r"))
    actions.addItem(.separator())
    for (kind, selector) in [
      (SyncKind.email, #selector(syncEmailAction)), (SyncKind.slack, #selector(syncSlackAction)),
    ] { actions.addItem(item(kind.menuTitle, selector)) }
    actions.addItem(.separator())
    actions.addItem(item("Show widget", #selector(toggleWidget), key: "w"))
    actions.addItem(item("Data folder", #selector(openDataFolder)))
    add(actions, title: "Actions")

    let edit = NSMenu(title: "Edit")
    edit.addItem(standard("Undo", Selector(("undo:")), "z"))
    edit.addItem(standard("Redo", Selector(("redo:")), "z", [.command, .shift]))
    edit.addItem(.separator())
    edit.addItem(standard("Cut", #selector(NSText.cut(_:)), "x"))
    edit.addItem(standard("Copy", #selector(NSText.copy(_:)), "c"))
    edit.addItem(standard("Paste", #selector(NSText.paste(_:)), "v"))
    edit.addItem(standard("Select All", #selector(NSText.selectAll(_:)), "a"))
    add(edit, title: "Edit")

    let view = NSMenu(title: "View")
    view.addItem(standard("Bigger Text", #selector(biggerText), "+"))
    view.addItem(standard("Smaller Text", #selector(smallerText), "-"))
    view.addItem(standard("Default Text Size", #selector(defaultTextSize), "0"))
    add(view, title: "View")

    let window = NSMenu(title: "Window")
    window.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    window.addItem(standard("Close", #selector(NSWindow.performClose(_:)), "w"))
    window.addItem(.separator())
    window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
    add(window, title: "Window")
    NSApp.windowsMenu = window
    return main
  }

  @objc private func biggerText() { TextScale.shared.larger() }
  @objc private func smallerText() { TextScale.shared.smaller() }
  @objc private func defaultTextSize() { TextScale.shared.reset() }

  // ⌘= is the unshifted ⌘+ on most keyboards; the menu item only matches the shifted one.
  private func watchTextSizeKey() {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "="
      else { return event }
      MainActor.assumeIsolated { TextScale.shared.larger() }
      return nil
    }
  }

  @objc private func toggleLoginItem() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled { try service.unregister() } else { try service.register() }
    } catch {
      model.show("Launch at login: \(error.localizedDescription)", isError: true)
    }
  }

  @objc private func openDataFolder() {
    try? FileManager.default.createDirectory(at: BoardStore.directory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(BoardStore.directory)
  }

  func showBoard() {
    if boardWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Tasks"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: BoardView(model: model).textScaled())
      window.setFrameAutosaveName("Board")
      if !window.setFrameUsingName("Board") { window.center() }
      boardWindow = window
    }
    NSApp.activate()
    boardWindow?.makeKeyAndOrderFront(nil)
  }

  // MARK: - Voice note

  func toggleRecording() {
    if recorder.isRecording {
      finishRecording()
    } else if !busy {
      Task { await startRecording() }
    }
  }

  private func startRecording() async {
    guard await VoiceRecorder.requestPermission() else {
      model.show("No microphone access: System Settings → Privacy & Security → Microphone", isError: true)
      return
    }
    do {
      try recorder.start()
    } catch {
      model.show("Couldn't start recording: \(error.localizedDescription)", isError: true)
      return
    }
    NSSound(named: "Tink")?.play()
    setActivity(.recording(since: Date()))
    cancelKey = HotKey(keyCode: kVK_Escape, modifiers: 0, id: 3) { [weak self] in self?.cancelRecording() }
  }

  private func cancelRecording() {
    cancelKey = nil
    recorder.cancel()
    NSSound(named: "Funk")?.play()
    model.show("Recording cancelled")
    updateIcon()
  }

  private func finishRecording() {
    cancelKey = nil
    guard let audio = recorder.stop() else { return }
    NSSound(named: "Pop")?.play()
    busy = true
    Task {
      await process(audio)
      busy = false
      updateIcon()
    }
  }

  private func process(_ audio: URL) async {
    setActivity(.transcribing)
    let transcript: String
    do {
      transcript = try await Transcriber.transcribe(audio)
      try? transcript.write(to: audio.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
      try? FileManager.default.removeItem(at: audio)
    } catch {
      model.show("Transcription: \(error.localizedDescription). Recording: \(audio.lastPathComponent)", isError: true)
      return
    }

    setActivity(.thinking(transcript))
    let before = BoardStore.load()
    do {
      let summary = try await ClaudeRunner.process(transcript: transcript)
      model.reload()
      if BoardStore.load() == before {
        saveRaw(transcript)
        model.show("Claude changed nothing (\(summary)) — the note was saved as a task", isError: true)
      } else {
        model.show(summary)
      }
    } catch {
      // Never lose a note: without Claude it lands on the board as is.
      saveRaw(transcript)
      model.show("\(error.localizedDescription) — the note was saved as a task as is", isError: true)
    }
  }

  private func saveRaw(_ transcript: String) {
    let title = transcript.count > 80 ? String(transcript.prefix(80)) + "…" : transcript
    model.change(source: "voice") { $0.add(title: title, notes: transcript, source: "voice") }
  }
}

extension AppDelegate: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(toggleWidget): item.state = widgetHidden ? .off : .on
    case #selector(toggleLoginItem): item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    case #selector(toggleDock): item.state = Self.showsInDock ? .on : .off
    case #selector(toggleOpenBoardAtLaunch): item.state = Self.opensBoardAtLaunch ? .on : .off
    case #selector(toggleOpenEmailInMail): item.state = MailOpener.usesMail ? .on : .off
    case #selector(toggleRecordingAction): item.title = recorder.isRecording ? "Stop recording" : "Dictate a task"
    case #selector(biggerText): return TextScale.shared.canGrow
    case #selector(smallerText): return TextScale.shared.canShrink
    case #selector(defaultTextSize): return !TextScale.shared.isDefault
    default: break
    }
    return true
  }
}

extension AppDelegate: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in menu.items {
      switch item.action {
      case #selector(toggleWidget): item.state = widgetHidden ? .off : .on
      case #selector(toggleLoginItem): item.state = SMAppService.mainApp.status == .enabled ? .on : .off
      case #selector(toggleDock): item.state = Self.showsInDock ? .on : .off
      case #selector(toggleOpenBoardAtLaunch): item.state = Self.opensBoardAtLaunch ? .on : .off
      case #selector(toggleOpenEmailInMail): item.state = MailOpener.usesMail ? .on : .off
      case #selector(toggleRecordingAction): item.title = recorder.isRecording ? "Stop recording" : "Dictate a task"
      default: break
      }
    }
  }
}
