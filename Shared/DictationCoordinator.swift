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

    let speech = SpeechService()
    private var stopPollTimer: Timer?

    init() {
        speech.onTranscriptUpdate = { finalized, volatile in
            SharedStore.publishLive(finalized: finalized, volatile: volatile)
        }
        speech.onFinish = { [weak self] _ in
            SharedStore.endLiveSession()
            self?.stopPollTimer?.invalidate()
            self?.stopPollTimer = nil
        }
    }

    /// Opened from the keyboard: start the session, then flash back.
    func activateFromKeyboard() {
        SharedStore.clearStopRequest()
        SharedStore.startLiveSession()
        Task {
            await speech.start()
            guard speech.status == .listening else {
                SharedStore.endLiveSession()
                return
            }
            startStopPolling()
            // Let the audio session settle, then return to the previous app.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Self.useInstantReturn { Self.returnToPreviousApp() }
        }
    }

    private func startStopPolling() {
        stopPollTimer?.invalidate()
        // Keeps firing in the background thanks to the audio background mode.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if SharedStore.isStopRequested() {
                Task { await self.speech.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stopPollTimer = timer
    }

    /// Private API: backgrounds this app, returning to the app that opened us.
    private static func returnToPreviousApp() {
        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else { return }
        UIApplication.shared.perform(selector)
    }
}
