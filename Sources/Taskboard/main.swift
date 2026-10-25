import AppKit

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  // A regular app (Dock icon, Cmd-Tab, menu bar) unless "Show in Dock" was turned off in the menu.
  app.setActivationPolicy(AppDelegate.showsInDock ? .regular : .accessory)
  app.run()
}
