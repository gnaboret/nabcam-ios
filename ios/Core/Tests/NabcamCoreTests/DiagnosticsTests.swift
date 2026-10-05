import XCTest
@testable import NabcamCore

final class DiagnosticsTests: XCTestCase {
    func testRelayTrafficDescribesMeasurementBoundariesAndRetryCounts() {
        var meter = DatagramRateMeter()
        meter.record(bytes: 1000, retransmission: true, at: 100)
        var log = StreamDiagnostics()
        log.append(.srtlaPath(link: .cellular, socketID: 7, traffic: meter.snapshot(at: 100),
                             relayRTTMs: 42.5, rttAgeMs: 120))
        let report = log.report()
        XCTAssertTrue(report.contains("Cellular socket 7: local UDP submissions total 1000 bytes / 1 packets"))
        XCTAssertTrue(report.contains("retry total 1000 bytes / 1 packets"))
        XCTAssertTrue(report.contains("50ms: 160.0 kbps"))
        XCTAssertTrue(report.contains("1000ms: 8.0 kbps"))
        XCTAssertTrue(report.contains("42.5 ms (sample age 120 ms)"))
        XCTAssertTrue(report.contains("not receiver throughput"))
        XCTAssertTrue(report.contains("bursts between samples may be missed"))
        XCTAssertFalse(report.contains("://"))
    }
    func testSrtlaQueueSnapshotContainsOnlyOperationalCounts() {
        var log = StreamDiagnostics()
        log.append(.srtla(registeredPaths: 2, queuedPackets: 8, queuedBytes: 10656,
                          oldestMediaMs: 37, overflows: 1, socketReplacements: 3))
        let report = log.report()
        XCTAssertTrue(report.contains("Experimental SRTLA: 2 registered paths"))
        XCTAssertTrue(report.contains("queue 8 packets / 10656 bytes; oldest media 37 ms"))
        XCTAssertTrue(report.contains("overflow 1; socket replacements 3"))
        XCTAssertFalse(report.contains("srtla://"))
    }
    func testAudioInterruptionTimeline() {
        var log = StreamDiagnostics()
        log.append(.audioInterruption(began: true), at: Date(timeIntervalSince1970: 10))
        log.append(.stopped, at: Date(timeIntervalSince1970: 11))
        log.append(.audioInterruption(began: false), at: Date(timeIntervalSince1970: 12))
        let report = log.report()
        XCTAssertEqual(log.count, 3)
        XCTAssertTrue(report.contains("#1 1970-01-01T00:00:10.000Z — iOS microphone interruption: began"))
        XCTAssertTrue(report.contains("#2 1970-01-01T00:00:11.000Z — Publish stopped"))
        XCTAssertTrue(report.contains("#3 1970-01-01T00:00:12.000Z — iOS microphone interruption: ended"))
    }
    func testBoundedAndChronologicalSequence() {
        var log = StreamDiagnostics()
        for i in 0..<310 { log.append(.connecting(bitrateKbps: i), at: Date(timeIntervalSince1970: Double(310 - i))) }
        XCTAssertEqual(log.count, 300)
        let text = log.report()
        XCTAssertFalse(text.contains("#1 "))
        XCTAssertTrue(text.contains("#11 "))
        XCTAssertTrue(text.contains("#310 "))
        XCTAssertLessThan(text.range(of: "#11 ")!.lowerBound, text.range(of: "#310 ")!.lowerBound)
    }
    func testTimestampPrecisionAndClear() {
        var log = StreamDiagnostics()
        log.append(.captureRequested(.fullHD60), at: Date(timeIntervalSince1970: 1.125))
        XCTAssertTrue(log.report().contains("1970-01-01T00:00:01.125Z"))
        XCTAssertTrue(log.report().contains("1080p · 60 FPS"))
        log.clear()
        XCTAssertEqual(log.count, 0)
        XCTAssertFalse(log.report().contains("#1 "))
    }
}
