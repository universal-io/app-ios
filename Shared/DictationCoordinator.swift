import Foundation
import UIKit

/// Orchestrates the Wispr-style flow in the host app:
/// - one-time activation from the keyboard starts a background recording session,
/// - then the app flashes back to the previous app so dictation feels in-place,
/// - a background timer watches for a stop request from the keyboard.
@MainActor
@Observable
final class DictationCoordinator {
    /// A/B switch for the return-to-previous-app behavior.
    /// `false` = stay put; the system shows a "‹ <app>" chip that returns to the
    ///           *correct* previous app in one tap (App Store safe).
    /// `true`  = private `suspend` selector — but it drops to the Home screen,
    ///           not the previous app, so it is worse here. Kept only as a knob.
    private static let useInstantReturn = false
    private static let pausedSessionTimeout: TimeInterval = 5 * 60

    let speech = SpeechService()
    private var stopPollTimer: Timer?
    private var heartbeatTimer: Timer?
    private var isPublishingTranscript = false
    private var pausedAt: Date?

    init() {
        speech.onTranscriptUpdate = { [weak self] finalized, volatile in
            guard self?.isPublishingTranscript == true else { return }
            SharedStore.publishLive(finalized: finalized, volatile: volatile)
        }
        speech.onFinish = { [weak self] _ in
            self?.isPublishingTranscript = false
            self?.pausedAt = nil
            SharedStore.endLiveSession()
            self?.stopSessionTimers()
        }
    }

    /// Opened from the keyboard: start the session, then flash back.
    func activateFromKeyboard() {
        SharedStore.clearStopRequest()
        SharedStore.startLiveSession()
        isPublishingTranscript = true
        pausedAt = nil
        Task {
            await speech.start()
            guard speech.status == .listening else {
                SharedStore.endLiveSession()
                stopSessionTimers()
                return
            }
            startSessionTimers()
            // Let the audio session settle, then return to the previous app.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Self.useInstantReturn { Self.returnToPreviousApp() }
        }
    }

    private func startSessionTimers() {
        startHeartbeat()
        startStopPolling()
    }

    private func stopSessionTimers() {
        stopPollTimer?.invalidate()
        stopPollTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            SharedStore.heartbeatLiveSession()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func startStopPolling() {
        stopPollTimer?.invalidate()
        // Keeps firing in the background thanks to the audio background mode.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if SharedStore.isStopRequested() {
                Task { await self.speech.stop() }
                return
            }

            switch SharedStore.readCommand() {
            case .pause:
                pauseSession()
            case .resume:
                resumeSession()
            case .end:
                SharedStore.clearCommand()
                Task { await self.speech.stop() }
            case .none:
                break
            }

            if let pausedAt,
               Date().timeIntervalSince(pausedAt) > Self.pausedSessionTimeout {
                Task { await self.speech.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stopPollTimer = timer
    }

    private func pauseSession() {
        isPublishingTranscript = false
        pausedAt = Date()
        speech.resetTranscript()
        SharedStore.pauseLiveSession()
        SharedStore.clearCommand()
    }

    private func resumeSession() {
        isPublishingTranscript = false
        pausedAt = nil
        speech.resetTranscript()
        isPublishingTranscript = true
        SharedStore.resumeLiveSession()
        SharedStore.clearCommand()
    }

    /// Private API: backgrounds this app, returning to the app that opened us.
    private static func returnToPreviousApp() {
        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else { return }
        UIApplication.shared.perform(selector)
    }
}
