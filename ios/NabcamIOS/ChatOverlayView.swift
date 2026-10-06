import NabcamCore
import SwiftUI

struct ChatOverlayView: View {
    @ObservedObject var chat: StreamChatService
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !chat.isConnected || chat.messages.isEmpty {
                Text(chat.status).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(chat.messages.suffix(8)) { message in
                ChatFlowLayout(spacing: 3) {
                    ForEach(Array(message.badges.enumerated()), id: \.offset) { _, badge in
                        Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
                    }
                    Text(message.sender + ":").fontWeight(.bold).foregroundStyle(Color(chatHex: message.colorHex))
                    ForEach(Array(message.fragments.enumerated()), id: \.offset) { _, fragment in
                        switch fragment {
                        case .text(let text):
                            ForEach(Array(text.split(whereSeparator: { $0.isWhitespace }).enumerated()), id: \.offset) { _, word in
                                Text(String(word)).foregroundStyle(.white)
                            }
                        case .emote(let name, let url):
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                                placeholder: { Text(name).font(.system(size: 8)) }
                                .frame(width: 24, height: 24).accessibilityLabel(name)
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .shadow(color: .black, radius: 2, x: 1, y: 1)
        .padding(8).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}

/// Wrap inline badges, names, words and emotes without inserting a web view into capture.
private struct ChatFlowLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(width: proposal.width ?? 300, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(width: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                 proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let width = max(1, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}

private extension Color {
    init(chatHex: String) {
        let rgb = UInt32(chatHex.dropFirst(), radix: 16) ?? 0xC4A0FF
        self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
