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

    /// Which pipeline the image came from. The prompt tells the model to read
    /// through glare and skew for a camera photograph, which is wrong advice
    /// for a screen capture arriving over the wire — it is already flat, sharp
    /// and complete.
    var sourceKind: String = "camera"
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

    func analyze(imageData: Data, tapPoint: CGPoint?, region: CGRect? = nil) {
        guard let captured = UIImage(data: imageData) else {
            phase = .failed("The captured photo could not be read.")
            return
        }

        // A camera JPEG stores its pixels in the sensor's orientation and leaves a
        // rotation flag for the viewer to apply. That splits the picture into two
        // coordinate spaces: the bytes we upload, and the upright image we draw
        // annotations on. Measured 2026-08-14 — the model reads the rotated image
        // while the dimensions derived from the file describe the stored one, so
        // it divides by the wrong axis and every box lands at the wrong height.
        //
        // Baking the rotation into the pixels here collapses the two spaces into
        // one before anything depends on either, and the same pass caps the size
        // the model has to work at.
        guard let (image, uploadData) = prepared(captured) else {
            phase = .failed("The captured photo could not be prepared for analysis.")
            return
        }

        task?.cancel()
        capturedImage = image
        streamingText = ""
        result = nil
        highlightState = .none
        phase = .analyzing

        let askedQuestion = question

        task = Task { [client] in
            // Measuring the text first costs a moment before the network call and
            // buys coordinates the model does not have to invent. It runs off the
            // main thread and degrades to an empty list, so a failure here only
            // returns the model to estimating.
            let request = AnalyzeClient.Request(
                image: uploadData,
                question: question.isEmpty ? nil : question,
                tapPoint: tapPoint,
                region: region,
                turns: turns,
                contextPackID: contextPackID,
                sourceKind: sourceKind,
                candidates: await TextGrounding.candidates(in: uploadData)
            )
            if Task.isCancelled { return }

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

    /// The longest side of the picture that gets analyzed.
    ///
    /// Measured 2026-08-14, photographing a Mac screen with an iPhone 13. At the
    /// camera's own 3024x4032 the model put 3 boxes of 11 on target and missed by
    /// as much as 0.45 of the image height. The same photo at 1/2, 1/3 and 1/4
    /// placed 18 of 18 within 0.005. The error is bimodal — the model either
    /// finds the control or points a long way below it — so full resolution is a
    /// cliff to stay clear of rather than a dial to trade off.
    ///
    /// 1536 sits between two sizes measured perfect (2016 and 1344) and well
    /// above 672, where one box in seven drifted. Legibility does not pay for it:
    /// the footer version "2026.6.880.0" was read back correctly at every size
    /// down to 672, which is the opposite of what was assumed when this pipeline
    /// was built to send frames at full size.
    private static let maxAnalyzedEdge: CGFloat = 1536

    /// Returns the picture to analyze, together with JPEG bytes of exactly that
    /// picture — one image behind both, so what the model measures and what the
    /// overlay draws on cannot drift apart.
    ///
    /// Drawing into a fresh context applies the rotation flag to the pixels and
    /// caps the size in the same pass. Annotations come back normalized, and a
    /// uniform scale leaves those untouched, so the smaller image can serve as
    /// both the upload and the canvas the highlights are drawn on.
    private func prepared(_ image: UIImage) -> (UIImage, Data)? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }

        let scale = min(1, Self.maxAnalyzedEdge / longest)
        let size = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let redrawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let data = redrawn.jpegData(compressionQuality: 0.9) else { return nil }
        return (redrawn, data)
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
