import CoreGraphics
import Foundation

/// A rectangle in the analyzed image's own space: origin top-left, every value a
/// fraction between 0 and 1. Annotations are held this way and converted to view
/// points only at draw time, so they stay correct as the view resizes or rotates.
struct NormalizedBox: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case highlight
        case callout
    }

    var id: String
    var kind: Kind
    var box: NormalizedBox
    var label: String
    var candidateID: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, box, label
        case candidateID = "candidate_id"
    }
}

struct AnalysisResult: Codable, Equatable, Sendable {
    var requestID: String
    var summary: String
    var annotations: [Annotation]
    var appliedContextPack: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case summary, annotations
        case appliedContextPack = "applied_context_pack"
    }
}

/// Why no highlight is on screen. Kept as three distinct states rather than an
/// empty array, because "the model named nothing", "it named something we could
/// not place", and "we drew it" need different answers when a user reports that
/// nothing appeared. See docs/lessons-from-app-mac.md section 4.
enum HighlightState: Equatable, Sendable {
    case none
    case unresolvable(String)
    case resolved(count: Int)
}
