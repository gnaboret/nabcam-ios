import Foundation
import XCTest
@testable import NabcamStorageHost

final class SrtConnectionOptionsTests: XCTestCase {
    func testCredentialsAreRemovedFromTransportURLAndDescriptions() throws {
        let options = try SrtConnectionOptions(XCTUnwrap(URL(string:
            "srt://127.0.0.1:9000?mode=caller&latency=2500&streamid=%23!%3A%3Ar%3Dchannel%2Fkey&passphrase=fixture%2Bsecret%26value")))
        XCTAssertEqual(options.url.absoluteString, "srt://127.0.0.1:9000?mode=caller&latency=2500")
        XCTAssertEqual(String(describing: options), "SRT options (redacted)")
        XCTAssertEqual(String(reflecting: options), "SRT options (redacted)")
    }

    func testDuplicateOrInvalidCredentialsAreRejectedWithoutEchoingValues() throws {
        for query in ["streamid=one&STREAMID=two", "passphrase=fixture-secret&passphrase=another-secret",
                      "passphrase=short", "passphrase=" + String(repeating: "x", count: 80),
                      "streamid=" + String(repeating: "x", count: 513), "streamid=null%00value", "passphrase=fixture%00secret"] {
            let url = try XCTUnwrap(URL(string: "srt://127.0.0.1:9000?" + query))
            XCTAssertThrowsError(try SrtConnectionOptions(url)) { error in
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertFalse(error.localizedDescription.contains("127.0.0.1"))
            }
        }
    }

    func testOtherOptionsMustSurviveThePinnedURLParser() throws {
        let options = try SrtConnectionOptions(XCTUnwrap(URL(string: "srt://127.0.0.1:9000?latency=%32%35%30%30")))
        XCTAssertEqual(options.url.query, "latency=2500")
        XCTAssertThrowsError(try SrtConnectionOptions(XCTUnwrap(URL(string: "srt://127.0.0.1:9000?packetfilter=x%26y"))))
        XCTAssertThrowsError(try SrtConnectionOptions(XCTUnwrap(URL(string: "srt://127.0.0.1:9000?packetfilter=x?y"))))
        XCTAssertThrowsError(try SrtConnectionOptions(XCTUnwrap(URL(string: "srt://user:secret@127.0.0.1:9000"))))
    }
}
