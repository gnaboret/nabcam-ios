import XCTest
@testable import NabcamCore

final class StreamDestinationTests: XCTestCase {
    func testFullRTMPURLIsPreserved() throws {
        let value = try StreamDestination(" rtmps://example.com/live/private-key?token=secret ")
        XCTAssertEqual(value.url.absoluteString, "rtmps://example.com/live/private-key?token=secret")
        XCTAssertEqual(value.protocolName, "RTMPS")
    }
    func testSRTOptionsAreNotRewritten() throws {
        let input = "srt://example.com:9000?mode=caller&latency=2500&streamid=abc"
        XCTAssertEqual(try StreamDestination(input).url.absoluteString, input)
    }
    func testSRTLAIsNeverTreatedAsPlainSRT() {
        XCTAssertThrowsError(try StreamDestination("srtla://example.com:9000"))
    }
    func testIncompleteAndNonStreamingURLsAreRejected() {
        for input in ["", "https://example.com/live/key", "rtmp://example.com/live", "srt://example.com", "rtmp://example.com/live/a b", "srt://example.com:0"] {
            XCTAssertThrowsError(try StreamDestination(input), input)
        }
    }
}
