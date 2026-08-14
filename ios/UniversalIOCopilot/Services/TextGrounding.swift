import UIKit
import Vision

/// Measures where the words on the screen actually are, so the model does not
/// have to estimate it.
///
/// The server has always accepted a list of measured rectangles and tells the
/// model to copy the matching one verbatim rather than guess — that path was
/// built for the Mac companion's accessibility tree and sat unused in camera
/// mode, where no such tree exists. Text recognition is the nearest thing to a
/// ruler that works on a photograph.
///
/// Measured 2026-08-14 on a photo of a Mac screen: the model placed a highlight
/// 0.049 below a popup it named, while recognition put the same popup within
/// 0.002 of the truth. That is the difference this closes — and it closes it by
/// measurement, so it does not depend on the image happening to be a size the
/// model reads well.
enum TextGrounding {
    /// Enough to cover a dense screen without burying the real target. The
    /// server truncates at 500; the limit here is about the model's attention,
    /// not the wire.
    private static let maxElements = 80

    /// Recognition returns a score for how sure it is of the reading. Anything
    /// this uncertain is more likely furniture in the background than a control.
    private static let minimumConfidence: Float = 0.3

    /// Reads the same bytes that are uploaded, so both describe one image and
    /// the coordinates cannot drift apart.
    static func candidates(in jpeg: Data) async -> [AnalyzeClient.Candidate] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Screens in this product are read in whatever language they ship
            // in; correcting toward a dictionary would rewrite product names.
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = false

            do {
                try VNImageRequestHandler(data: jpeg, options: [:]).perform([request])
            } catch {
                // Grounding is an improvement, not a requirement: without it the
                // model still answers from the picture alone.
                return []
            }

            return (request.results ?? [])
                .prefix(maxElements)
                .enumerated()
                .compactMap { index, observation -> AnalyzeClient.Candidate? in
                    guard let best = observation.topCandidates(1).first,
                          best.confidence >= minimumConfidence
                    else { return nil }

                    let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }

                    // Vision measures up from the bottom-left. Everything else in
                    // this product measures down from the top-left, the way the
                    // model is told to.
                    let found = observation.boundingBox
                    return AnalyzeClient.Candidate(
                        id: "text-\(index)",
                        role: "text",
                        label: text,
                        box: CGRect(
                            x: found.minX,
                            y: 1 - found.maxY,
                            width: found.width,
                            height: found.height
                        )
                    )
                }
        }.value
    }
}
