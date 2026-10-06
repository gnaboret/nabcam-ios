import XCTest
@testable import NabcamCore

final class SrtLatencySettingTests: XCTestCase {
    func testAbsentDefaultAndExplicitSetting() throws {
        let setting = try SrtLatencySetting("srt://example.test:9000")
        XCTAssertNil(setting.milliseconds)
        XCTAssertEqual(try setting.replacing(with: 2500), "srt://example.test:9000?latency=2500")
        XCTAssertEqual(try SrtLatencySetting(setting.replacing(with: 2500)).replacing(with: nil), "srt://example.test:9000")
    }
    func testCredentialsAndOtherOptionsRemainEncodedExactly() throws {
        let tail = "streamid=%23%21%3A%3Ar%3Da%26b%2Bc%25%3F&passphrase=synthetic%2Bsecret&conntimeo=7000"
        for scheme in ["srt", "srtla"] {
            let input = "\(scheme)://example.test:9000?latency=120&\(tail)"
            let setting = try SrtLatencySetting(input)
            XCTAssertEqual(setting.milliseconds, 120)
            XCTAssertEqual(try setting.replacing(with: 2500), "\(scheme)://example.test:9000?\(tail)&latency=2500")
            XCTAssertEqual(try setting.replacing(with: nil), "\(scheme)://example.test:9000?\(tail)")
            XCTAssertFalse(String(describing: setting).contains("secret"))
        }
    }
    func testDirectionalAndDuplicateOptionsAreNotOverwritten() {
        for query in ["peerlatency=500", "rcvlatency=500", "latency=100&latency=200", "LATENCY=100&latency=200", "latency=-1", "latency=abc", "latency=2147483648"] {
            XCTAssertThrowsError(try SrtLatencySetting("srt://example.test:9000?\(query)"))
        }
    }
    func testBoundsAndUnsupportedTransport() throws {
        XCTAssertThrowsError(try SrtLatencySetting("rtmps://example.test/live/key"))
        let setting = try SrtLatencySetting("srt://example.test:9000?latency=15000")
        XCTAssertEqual(setting.milliseconds, 15000) // preserve existing custom URL value
        XCTAssertThrowsError(try setting.replacing(with: -1))
        XCTAssertThrowsError(try setting.replacing(with: 10001))
        XCTAssertEqual(try SrtLatencySetting(setting.replacing(with: 0)).milliseconds, 0)
    }
}
