import UIKit
import XCTest
import NabcamCore
@testable import NabcamStorageHost

@MainActor
final class ChatRasterizerTests: XCTestCase {
    func testEmptyChatIsTransparentAndInvalidDimensionsAreRejected() throws {
        let image = try XCTUnwrap(ChatRasterizer.render(messages: [], emotes: [:], width: 480, height: 240))
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 240)
        XCTAssertEqual(try pixels(image).filter { $0.3 != 0 }.count, 0)
        XCTAssertNil(ChatRasterizer.render(messages: [], emotes: [:], width: 4096, height: 240))
        XCTAssertNil(ChatRasterizer.render(messages: [], emotes: [:], width: 480, height: 0))
    }

    func testColoredNameAndCachedEmoteAreRendered() throws {
        let url = try XCTUnwrap(URL(string: "https://files.kick.com/emotes/123/fullsize"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let emote = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let message = ChatMessage(id: "fixture", sender: "TestViewer", text: "Hello [emote:123:Wave]",
                                  color: "#00FF00", badgeTypes: ["moderator"])
        let image = try XCTUnwrap(ChatRasterizer.render(messages: [message], emotes: [url: emote], width: 480, height: 240))
        let values = try pixels(image)
        XCTAssertGreaterThan(values.filter { $0.0 > 200 && $0.1 < 30 && $0.2 < 30 }.count, 100)
        XCTAssertGreaterThan(values.filter { $0.1 > 200 && $0.0 < 30 && $0.2 < 30 }.count, 20)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "outgoing-chat-raster"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHistoryIsBoundedToNewestEightMessages() throws {
        let recent = (1...8).map { ChatMessage(id: "\($0)", sender: "Viewer\($0)", text: "hello",
                                             color: nil, badgeTypes: []) }
        let old = ChatMessage(id: "old", sender: "Old", text: "Should not appear", color: nil, badgeTypes: [])
        let a = try XCTUnwrap(ChatRasterizer.render(messages: recent, emotes: [:], width: 480, height: 400))
        let b = try XCTUnwrap(ChatRasterizer.render(messages: [old] + recent, emotes: [:], width: 480, height: 400))
        XCTAssertEqual(UIImage(cgImage: a).pngData(), UIImage(cgImage: b).pngData())
    }

    private func pixels(_ image: CGImage) throws -> [(UInt8, UInt8, UInt8, UInt8)] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { index in
            let offset = index * 4
            return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
        }
    }
}
