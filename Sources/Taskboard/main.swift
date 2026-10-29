import AppKit
import Foundation

// Developer tool, see Snapshot.swift: draw the screens to PNG files and exit.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(flag + 1) {
  let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
  exit(MainActor.assumeIsolated { Snapshot.run(into: folder) })
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  // A regular app (Dock icon, Cmd-Tab, menu bar) unless "Show in Dock" was turned off in the menu.
  app.setActivationPolicy(AppDelegate.showsInDock ? .regular : .accessory)
  app.run()
}
