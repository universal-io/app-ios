import SwiftUI

/// The transparent layer that draws highlights over the image.
///
/// Annotations arrive in normalized image coordinates and are converted here,
/// at draw time, through `OverlayGeometry` — so they follow the image when the
/// view resizes or the device rotates instead of drifting off target.
struct AnnotationOverlay: View {
    let annotations: [Annotation]
    let imageSize: CGSize

    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let geometry = OverlayGeometry(imageSize: imageSize, viewSize: proxy.size)

            ForEach(annotations) { annotation in
                let rect = geometry.rect(for: annotation.box)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(pulse ? 1.0 : 0.55)

                    if !annotation.label.isEmpty {
                        Text(annotation.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                            .fixedSize()
                            .position(labelPosition(for: rect, in: proxy.size))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// Puts the label above the box, or below it when the box is near the top edge.
    private func labelPosition(for rect: CGRect, in size: CGSize) -> CGPoint {
        let above = rect.minY - 16
        return CGPoint(x: min(max(rect.midX, 60), size.width - 60), y: above < 20 ? rect.maxY + 16 : above)
    }
}
