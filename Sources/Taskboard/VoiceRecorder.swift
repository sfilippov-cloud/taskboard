// Records the microphone into voice/<date>.m4a until stopped.
import AVFoundation
import Foundation
import TaskboardCore

@MainActor
final class VoiceRecorder {
  private var recorder: AVAudioRecorder?
  private(set) var url: URL?

  var isRecording: Bool { recorder?.isRecording ?? false }

  static func requestPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
  }

  func start() throws {
    try FileManager.default.createDirectory(at: BoardStore.voiceDirectory, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let url = BoardStore.voiceDirectory.appendingPathComponent(formatter.string(from: Date()) + ".m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
    self.recorder = recorder
    self.url = url
  }

  // The finished file, or nil when nothing was recording.
  func stop() -> URL? {
    guard let recorder else { return nil }
    recorder.stop()
    self.recorder = nil
    return url
  }

  func cancel() {
    recorder?.stop()
    recorder?.deleteRecording()
    recorder = nil
    url = nil
  }
}
