import CoreGraphics

/// Converts between normalized image coordinates and view points.
///
/// The image is displayed aspect-fit, so it rarely fills the view: there are
/// bars on two sides. Every conversion has to account for that offset, in both
/// directions — a highlight drawn without it lands off-target, and a tap
/// reported without it tells the model to look at the wrong place. This is the
/// single place that correction lives.
struct OverlayGeometry: Equatable {
    var imageSize: CGSize
    var viewSize: CGSize

    /// The part of the view the image actually covers.
    var contentRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return .zero }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func rect(for box: NormalizedBox) -> CGRect {
        let content = contentRect
        guard !content.isEmpty else { return .zero }

        return CGRect(
            x: content.minX + box.x * content.width,
            y: content.minY + box.y * content.height,
            width: box.w * content.width,
            height: box.h * content.height
        )
    }

    /// Puts a normalized point back where it came from, so what was sent can be
    /// drawn next to what came back. Same correction as the reverse direction —
    /// a marker computed any other way would prove nothing about the transform
    /// it is meant to check.
    func viewPoint(forNormalized point: CGPoint) -> CGPoint {
        let content = contentRect
        return CGPoint(
            x: content.minX + point.x * content.width,
            y: content.minY + point.y * content.height
        )
    }

    /// Nil when the tap landed on a letterbox bar rather than on the image.
    func normalizedPoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let content = contentRect
        guard content.contains(point) else { return nil }

        return CGPoint(
            x: (point.x - content.minX) / content.width,
            y: (point.y - content.minY) / content.height
        )
    }

    /// Normalizes without rejecting. A stroke drawn around something near the
    /// edge runs over the letterbox, and dropping those points would redraw it
    /// as a different shape than the one the finger made.
    func clampedNormalizedPoint(fromViewPoint point: CGPoint) -> CGPoint {
        let content = contentRect
        guard !content.isEmpty else { return .zero }

        return CGPoint(
            x: min(max((point.x - content.minX) / content.width, 0), 1),
            y: min(max((point.y - content.minY) / content.height, 0), 1)
        )
    }

    /// The part of a drawn region that falls on the image. Nil when the stroke
    /// missed the picture entirely, which is the same answer a tap on the bars
    /// gets.
    func normalizedRect(fromViewRect rect: CGRect) -> CGRect? {
        let content = contentRect
        guard !content.isEmpty else { return nil }

        let overlap = rect.intersection(content)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }

        return CGRect(
            x: (overlap.minX - content.minX) / content.width,
            y: (overlap.minY - content.minY) / content.height,
            width: overlap.width / content.width,
            height: overlap.height / content.height
        )
    }
}
