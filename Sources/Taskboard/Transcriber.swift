// On-device transcription of a voice note (Speech framework, macOS 26), adapted from Screenshooter.
// SpeechTranscriber where the language is supported, DictationTranscriber or SFSpeechRecognizer otherwise (Russian).
import AVFoundation
import Foundation
import Speech

enum TranscriberError: LocalizedError {
  case unsupported(String)
  case notAuthorized
  case empty

  var errorDescription: String? {
    switch self {
    case .unsupported(let locale): "Speech recognition for \(locale) isn't available on this Mac"
    case .notAuthorized: "Allow Taskboard in System Settings → Privacy & Security → Speech Recognition"
    case .empty: "No words were recognized in the recording"
    }
  }
}

enum Transcriber {
  static var locale: Locale {
    Locale(identifier: UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "en-US")
  }

  static func transcribe(_ audio: URL) async throws -> String {
    let chosen = locale
    let file = try AVAudioFile(forReading: audio)
    var text: String?
    if let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: chosen) {
      let module = SpeechTranscriber(locale: speechLocale, preset: .transcription)
      text = try? await run(module, file: file, results: module.results.map { ($0.text, $0.isFinal) })
    }
    if text.isBlank, let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: chosen) {
      let module = DictationTranscriber(locale: dictationLocale, preset: .longDictation)
      let file = try AVAudioFile(forReading: audio)
      text = try? await run(module, file: file, results: module.results.map { ($0.text, $0.isFinal) })
    }
    if text.isBlank { text = try await recognize(audio, locale: chosen) }
    guard let text, !text.isBlank else { throw TranscriberError.empty }
    return text
  }

  // On-device SFSpeechRecognizer; needs Speech Recognition permission.
  static func recognize(_ audio: URL, locale: Locale) async throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
      throw TranscriberError.unsupported(locale.identifier)
    }
    guard await requestPermission() else { throw TranscriberError.notAuthorized }
    let request = SFSpeechURLRecognitionRequest(url: audio)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    return try await withCheckedThrowingContinuation { continuation in
      var finished = false
      recognizer.recognitionTask(with: request) { result, error in
        guard !finished else { return }
        if let error {
          finished = true
          continuation.resume(throwing: error)
        } else if let result, result.isFinal {
          finished = true
          continuation.resume(returning: result.bestTranscription.formattedString)
        }
      }
    }
  }

  static func requestPermission() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
      }
    default: return false
    }
  }

  static func run<Results: AsyncSequence & Sendable>(
    _ module: any SpeechModule, file: AVAudioFile, results: Results
  ) async throws -> String where Results.Element == (AttributedString, Bool) {
    // Language models are downloaded on first use; a locale must be reserved before that.
    if await AssetInventory.status(forModules: [module]) != .installed {
      let reserved = await AssetInventory.reservedLocales
      for locale in (module as? any LocaleDependentSpeechModule)?.selectedLocales ?? [] where !reserved.contains(locale) {
        _ = try await AssetInventory.reserve(locale: locale)
      }
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
    }
    let analyzer = SpeechAnalyzer(modules: [module])
    async let parts: [String] = {
      var parts: [String] = []
      for try await (text, isFinal) in results where isFinal {
        let words = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append(words) }
      }
      return parts
    }()
    if let end = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: end)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await parts.joined(separator: " ")
  }
}

extension Optional where Wrapped == String {
  var isBlank: Bool { self?.isBlank ?? true }
}

extension String {
  var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
