import Foundation
import XCTest
@testable import NabcamCore

final class SrtlaEndpointTests: XCTestCase {
    func testReceiverAndLocalOptionsStaySeparate() throws {
        let query = "mode=caller&latency=2500&streamid=%23!%3A%3Ar%3Dchannel%2Fkey&passphrase=test%2Bsecret%26value"
        let endpoint = try SrtlaEndpoint(" srtla://example.invalid:9000?" + query + " ")
        XCTAssertEqual(endpoint.host, "example.invalid")
        XCTAssertEqual(endpoint.port, 9000)
        XCTAssertEqual(try endpoint.localSRTURL(port: 12345).absoluteString, "srt://127.0.0.1:12345?" + query)
        XCTAssertFalse(String(describing: endpoint).contains("secret"))
        XCTAssertFalse(String(reflecting: endpoint).contains("example.invalid"))
    }
    func testIPv6BareAddressAndTrailingSlash() throws {
        XCTAssertEqual(try SrtlaEndpoint("[2001:db8::1]:9000").host, "2001:db8::1")
        XCTAssertEqual(try SrtlaEndpoint("receiver.invalid:9000").port, 9000)
        XCTAssertEqual(try SrtlaEndpoint("srt://receiver.invalid:9000/").localSRTURL(port: 8000).absoluteString,
                       "srt://127.0.0.1:8000")
    }
    func testMalformedReceiverAndWrongModesAreRejected() {
        for input in ["", "https://host:9000", "srtla://host", "srtla://host:0", "srtla://host:65536",
                      "srtla://user:password@host:9000", "srtla://host:9000/path", "srtla://host:9000#key",
                      "srtla://host:9000?mode=listener", "srtla://host:9000?mode=caller&mode=rendezvous",
                      "srtla://host:9000?adapter=0.0.0.0", "srtla://host:9000?mode=caller&adapter=127.0.0.1",
                      "srtla://host:9000?ADAPTER=0.0.0.0", "srtla://host:9000?port=12345",
                      "srtla://host:9000?streamid=unescaped space", String(repeating: "a", count: 8193)] {
            XCTAssertThrowsError(try SrtlaEndpoint(input))
        }
    }
    func testLocalPortMustExistAndLiveBroadcastStillRejectsSRTLA() throws {
        let endpoint = try SrtlaEndpoint("srtla://host:9000")
        XCTAssertThrowsError(try endpoint.localSRTURL(port: 0))
        XCTAssertThrowsError(try StreamDestination("srtla://host:9000"))
    }
}
