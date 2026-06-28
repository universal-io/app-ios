import Foundation
import Speech
import AVFoundation

/// Live speech-to-text built on the iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`
/// stack (on-device). Exposes a finalized transcript plus the in-progress
/// "volatile" hypothesis so the UI can show text as it is spoken.
///
/// For Milestone 2 this lives in the host app: the microphone permission must be
/// requested here (a keyboard extension cannot present permission dialogs), and
/// this is the recording host of the app-assisted design.
@MainActor
@Observable
final class SpeechService {
    enum Status: Equatable {
        case idle
        case preparing
        case listening
        case denied
        case unavailable(String)
    }

    enum SpeechError: LocalizedError {
        case audioUnavailable

        var errorDescription: String? {
            switch self {
            case .audioUnavailable: return "マイクを準備できませんでした。もう一度お試しください。"
            }
        }
    }

    private(set) var status: Status = .idle
    /// Text the analyzer has committed (won't change).
    private(set) var finalizedText: String = ""
    /// In-progress hypothesis for what is currently being said.
    private(set) var volatileText: String = ""

    var transcript: String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Called when a recording session ends, with the final transcript. The app
    /// uses this to hand the result off to the keyboard via the shared store.
    var onFinish: ((String) -> Void)?

    /// Called on every recognition update (finalized, volatile) so the app can
    /// stream the live transcript to the keyboard via the shared store.
    var onTranscriptUpdate: ((String, String) -> Void)?

    private let locale = Locale(identifier: "ja-JP")
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?

    func toggle() async {
        if status == .listening {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard status != .listening else { return }
        status = .preparing
        finalizedText = ""
        volatileText = ""

        guard await requestPermissions() else {
            status = .denied
            return
        }

        do {
            try await beginTranscribing()
            status = .listening
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    func stop() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        // Commit whatever was still volatile.
        finalizedText += volatileText
        volatileText = ""

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = .idle

        let final = transcript
        if !final.isEmpty { onFinish?(final) }
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { return false }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return speechStatus == .authorized
    }

    // MARK: - Transcription

    private func beginTranscribing() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // Make sure the on-device model for this locale is installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += piece
                        self.volatileText = ""
                    } else {
                        self.volatileText = piece
                    }
                    self.onTranscriptUpdate?(self.finalizedText, self.volatileText)
                }
            } catch {
                self.status = .unavailable(error.localizedDescription)
            }
        }

        try configureAudioSession()
        try installMicTap()

        try await analyzer.start(inputSequence: stream)
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func installMicTap() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // On the very first run the mic hardware may not be warmed up yet and
        // reports an invalid format; installing a tap with it raises an
        // uncatchable exception. Bail cleanly instead of crashing.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechError.audioUnavailable
        }

        // Capture everything the realtime tap needs as locals, so the closure
        // never touches main-actor state. Build the converter once up front.
        let continuation = inputContinuation
        let analyzerFormat = analyzerFormat
        let converter: AVAudioConverter? = {
            guard let analyzerFormat, analyzerFormat != inputFormat else { return nil }
            return AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Runs on a realtime audio thread. `buffer` is only valid for the
            // duration of this call, so convert and yield synchronously here —
            // no actor hops. AsyncStream continuations are thread-safe.
            if let converter, let analyzerFormat {
                guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
                continuation?.yield(AnalyzerInput(buffer: converted))
            } else {
                continuation?.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
