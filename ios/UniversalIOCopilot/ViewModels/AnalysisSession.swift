import SwiftUI
import UIKit

/// Drives one round of "look at this screen and tell me what to do".
@MainActor
@Observable
final class AnalysisSession {
    enum Phase: Equatable {
        case framing
        case analyzing
        case answered
        case failed(String)
    }

    private(set) var phase: Phase = .framing

    /// The frame the current answer refers to. Kept frozen while an answer is on
    /// screen so annotations stay attached to the image they were computed from.
    private(set) var capturedImage: UIImage?
    private(set) var streamingText = ""
    private(set) var result: AnalysisResult?
    private(set) var highlightState: HighlightState = .none

    var question = ""
    var contextPackID: String?

    private var turns: [AnalyzeClient.Turn] = []
    private var task: Task<Void, Never>?
    private let client: AnalyzeClient

    init(client: AnalyzeClient = AnalyzeClient()) {
        self.client = client
    }

    var isBusy: Bool { phase == .analyzing }

    func reset() {
        task?.cancel()
        task = nil
        phase = .framing
        capturedImage = nil
        streamingText = ""
        result = nil
        highlightState = .none
        question = ""
        turns.removeAll()
    }

    /// Surfaces a failure that happened before analysis could start, so the
    /// user gets a reason rather than a screen that never changes.
    func fail(_ reason: String) {
        task?.cancel()
        task = nil
        phase = .failed(reason)
    }

    func analyze(imageData: Data, tapPoint: CGPoint?) {
        guard let image = UIImage(data: imageData) else {
            phase = .failed("The captured photo could not be read.")
            return
        }

        task?.cancel()
        capturedImage = image
        streamingText = ""
        result = nil
        highlightState = .none
        phase = .analyzing

        let request = AnalyzeClient.Request(
            image: imageData,
            question: question.isEmpty ? nil : question,
            tapPoint: tapPoint,
            turns: turns,
            contextPackID: contextPackID
        )
        let askedQuestion = question

        task = Task { [client] in
            do {
                for try await event in client.analyze(request) {
                    if Task.isCancelled { return }
                    switch event {
                    case .delta(let text):
                        streamingText += text
                    case .result(let value):
                        apply(value, askedQuestion: askedQuestion)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func apply(_ value: AnalysisResult, askedQuestion: String) {
        result = value
        streamingText = value.summary
        highlightState = value.annotations.isEmpty
            ? .none
            : .resolved(count: value.annotations.count)
        phase = .answered

        if !askedQuestion.isEmpty {
            turns.append(.init(role: "user", text: askedQuestion))
        }
        turns.append(.init(role: "assistant", text: value.summary))
        question = ""
    }
}
