import NabcamCore
import SwiftUI

/// A UI-only guide. Never added to MediaMixer or its outgoing overlay graph.
struct PreviewCompositionGrid: View {
    let frameSize: VideoFrameSize

    var body: some View {
        Canvas { context, size in
            guard let picture = PreviewGeometry.fittedRectangle(frame: frameSize,
                width: Double(size.width), height: Double(size.height)) else { return }
            var lines = Path()
            for fraction in [1.0 / 3, 2.0 / 3] {
                let x = picture.x + picture.width * fraction
                let y = picture.y + picture.height * fraction
                lines.move(to: CGPoint(x: x, y: picture.y))
                lines.addLine(to: CGPoint(x: x, y: picture.y + picture.height))
                lines.move(to: CGPoint(x: picture.x, y: y))
                lines.addLine(to: CGPoint(x: picture.x + picture.width, y: y))
            }
            context.stroke(lines, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(lines, with: .color(.white.opacity(0.6)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
