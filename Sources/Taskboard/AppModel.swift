// The board as the UI sees it (reloaded when board.json changes on disk) and the voice-note pipeline state.
import Foundation
import Observation
import TaskboardCore

enum Activity: Equatable {
  case idle
  case recording(since: Date)
  case transcribing
  case thinking(String)  // the transcript
  case message(String, isError: Bool)
}

@MainActor
@Observable
final class AppModel {
  private(set) var board = BoardStore.load()
  var activity: Activity = .idle

  @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
  @ObservationIgnored private var messageTimer: Timer?

  init() {
    watch()
  }

  func reload() {
    let fresh = BoardStore.load()
    if fresh != board { board = fresh }
  }

  // Writes go through the store (locked), then the UI reloads.
  func change(_ body: (inout Board) throws -> Void) {
    do {
      try BoardStore.change(body)
    } catch {
      show(error.localizedDescription, isError: true)
    }
    reload()
  }

  func show(_ message: String, isError: Bool = false) {
    activity = .message(message, isError: isError)
    messageTimer?.invalidate()
    messageTimer = Timer.scheduledTimer(withTimeInterval: isError ? 12 : 6, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        if case .message = self?.activity { self?.activity = .idle }
      }
    }
  }

  // board.json is replaced atomically, so the directory is watched, not the file.
  private func watch() {
    try? FileManager.default.createDirectory(at: BoardStore.directory, withIntermediateDirectories: true)
    let fd = open(BoardStore.directory.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.reload() }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }
}
