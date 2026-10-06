import UIKit
import NabcamCore

/// Draw only the newest bounded chat window. Images are supplied by a separate
/// bounded cache; rendering never performs network requests or writes chat to disk.
@MainActor
enum ChatRasterizer {
    static func render(messages: [ChatMessage], emotes: [URL: UIImage], width: Int, height: Int) -> CGImage? {
        guard (64...2048).contains(width), (32...1024).contains(height) else { return nil }
        let scale = CGFloat(width) / 480
        let padding = max(4, 8 * scale)
        let font = UIFont.systemFont(ofSize: max(10, 18 * scale), weight: .medium)
        let availableWidth = CGFloat(width) - padding * 2
        let availableHeight = CGFloat(height) - padding * 2
        guard availableHeight > 0 else { return nil }
        let blocks = messages.suffix(8).map { attributed($0, emotes: emotes, font: font) }
        var selected: [(NSAttributedString, CGFloat)] = []
        var total: CGFloat = 0
        for block in blocks.reversed() {
            let measured = ceil(block.boundingRect(with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            let blockHeight = min(availableHeight, measured)
            let gap = selected.isEmpty ? 0 : 4 * scale
            guard total + blockHeight + gap <= availableHeight else { break }
            selected.append((block, blockHeight))
            total += blockHeight + gap
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { renderer in
            guard !selected.isEmpty else { return }
            let top = CGFloat(height) - total - padding * 2
            UIColor.black.withAlphaComponent(0.4).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: top, width: CGFloat(width), height: total + padding * 2),
                         cornerRadius: 8 * scale).fill()
            renderer.cgContext.saveGState()
            renderer.cgContext.clip(to: CGRect(x: padding, y: top + padding, width: availableWidth, height: total))
            var y = top + padding
            for (block, blockHeight) in selected.reversed() {
                block.draw(with: CGRect(x: padding, y: y, width: availableWidth, height: blockHeight),
                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += blockHeight + 4 * scale
            }
            renderer.cgContext.restoreGState()
        }.cgImage
    }

    private static func attributed(_ message: ChatMessage, emotes: [URL: UIImage], font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let bold = UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
        if !message.badges.isEmpty {
            result.append(NSAttributedString(string: message.badges.joined(separator: " ") + " ",
                attributes: [.font: bold.withSize(font.pointSize * 0.7), .foregroundColor: UIColor.systemPurple]))
        }
        let rgb = UInt32(message.colorHex.dropFirst(), radix: 16) ?? 0xC4A0FF
        let color = UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: 1)
        result.append(NSAttributedString(string: message.sender + ": ", attributes: [.font: bold, .foregroundColor: color]))
        for fragment in message.fragments {
            switch fragment {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white]))
            case .emote(let name, let url):
                if let image = emotes[url] {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = CGRect(x: 0, y: -font.pointSize * 0.2,
                                               width: font.pointSize * 1.3, height: font.pointSize * 1.3)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    result.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: UIColor.white]))
                }
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}
