// A system-wide keyboard shortcut (Carbon hot keys work without Accessibility permission).
import Carbon

final class HotKey {
  private static var actions: [UInt32: () -> Void] = [:]
  private static var handlerInstalled = false
  private var reference: EventHotKeyRef?

  init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
    Self.actions[id] = action
    Self.installHandler()
    let hotKeyID = EventHotKeyID(signature: OSType(0x5453_4B42), id: id)  // "TSKB"
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
  }

  deinit {
    if let reference { UnregisterEventHotKey(reference) }
  }

  private static func installHandler() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        HotKey.actions[hotKeyID.id]?()
        return noErr
      }, 1, &pressed, nil, nil)
  }
}
