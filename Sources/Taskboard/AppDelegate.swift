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
    updateWidgetVisibility()

    hotKeys = [
      HotKey(keyCode: kVK_ANSI_R, modifiers: shortcut, id: 1) { [weak self] in self?.toggleRecording() },
      HotKey(keyCode: kVK_ANSI_K, modifiers: shortcut, id: 2) { [weak self] in self?.showBoard() },
      HotKey(keyCode: kVK_ANSI_W, modifiers: shortcut, id: 4) { [weak self] in self?.toggleWidget() },
    ]

    // Automatic email checks: looked at every few minutes, run when the interval has passed.
    syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { if self?.model.isAutoSyncDue == true { self?.model.syncEmail(manual: false) } }
    }
  }

  // MARK: - Menu

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(item("Dictate a task", #selector(toggleRecordingAction), key: "r"))
    menu.addItem(item("Open board", #selector(showBoardAction), key: "k"))
    menu.addItem(item("Check email now", #selector(syncEmailAction)))
    menu.addItem(item("Show widget", #selector(toggleWidget), key: "w"))
    menu.addItem(.separator())
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
  @objc private func syncEmailAction() { model.syncEmail(manual: true) }

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
      window.contentView = NSHostingView(rootView: BoardView(model: model))
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

extension AppDelegate: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in menu.items {
      switch item.action {
      case #selector(toggleWidget): item.state = widgetHidden ? .off : .on
      case #selector(toggleLoginItem): item.state = SMAppService.mainApp.status == .enabled ? .on : .off
      case #selector(toggleRecordingAction): item.title = recorder.isRecording ? "Stop recording" : "Dictate a task"
      default: break
      }
    }
  }
}
