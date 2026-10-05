import Foundation
import XCTest
@testable import NabcamCore

final class SrtlaRegistrationTests: XCTestCase {
    private let seed = Data(repeating: 0x35, count: 256)
    private var issuedGroup: Data { Data(repeating: 0x35, count: 128) + Data(repeating: 0x91, count: 128) }

    func testOwnerCreatesGroupThenBothPathsJoin() throws {
        var state = try makeState()
        let initial = state.poll(at: 0)
        XCTAssertEqual(initial.map(\.path), [1])
        XCTAssertEqual(initial.first?.bytes, SrtlaWire.control(SrtlaWire.reg1, payload: seed))
        XCTAssertTrue(state.poll(at: 999).isEmpty)
        let join = state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 1, at: 1000)
        XCTAssertEqual(join.map(\.path), [1, 2])
        XCTAssertTrue(join.allSatisfy { $0.bytes == SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup) })
        XCTAssertFalse(state.isRegistered(1))
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 1, at: 1001)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 2, at: 1002)
        XCTAssertTrue(state.isRegistered(1)); XCTAssertTrue(state.isRegistered(2))
        XCTAssertTrue(state.poll(at: 2000).allSatisfy { $0.bytes == SrtlaWire.control(SrtlaWire.keepalive) })
    }

    func testRejectWrongOwnerPrefixLengthAndPrematureConfirmation() throws {
        var state = try makeState()
        _ = state.poll(at: 0)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 1, at: 1)
        XCTAssertFalse(state.isRegistered(1))
        XCTAssertTrue(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 2, at: 2).isEmpty)
        XCTAssertTrue(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: Data(repeating: 1, count: 256)), on: 1, at: 3).isEmpty)
        XCTAssertTrue(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup.dropLast()), on: 1, at: 4).isEmpty)
        XCTAssertEqual(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 1, at: 5).count, 2)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3, payload: Data([0])), on: 1, at: 6)
        XCTAssertFalse(state.isRegistered(1))
    }

    func testSilentOwnerRotatesAndLateReplyCannotStealGroup() throws {
        var state = try makeState()
        _ = state.poll(at: 0)
        XCTAssertEqual(state.poll(at: 4000).map(\.path), [2])
        XCTAssertTrue(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 1, at: 4001).isEmpty)
        XCTAssertEqual(state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 2, at: 4002).map(\.path), [2])
        XCTAssertEqual(state.poll(at: 6000).first(where: { $0.path == 1 })?.bytes,
                       SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup))
    }

    func testHealthyPathSurvivesOtherPathUnknownGroupAndRemoval() throws {
        var state = try registeredState()
        _ = state.receive(SrtlaWire.control(SrtlaWire.unknownGroup), on: 1, at: 100)
        XCTAssertTrue(state.isRegistered(2)); XCTAssertFalse(state.needsNewGroup)
        XCTAssertThrowsError(try state.replaceExpiredGroup(randomSeed: seed))
        state.removePath(1)
        try state.addPath(3)
        XCTAssertEqual(state.poll(at: 1000).first(where: { $0.path == 3 })?.bytes,
                       SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup))
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 1, at: 1001)
        XCTAssertFalse(state.isRegistered(1))
    }

    func testAllUnknownRequiresFreshSeedAndKeepsCooldown() throws {
        var state = try registeredState()
        _ = state.receive(SrtlaWire.control(SrtlaWire.unknownGroup), on: 1, at: 100)
        _ = state.receive(SrtlaWire.control(SrtlaWire.unknownGroup), on: 2, at: 101)
        XCTAssertTrue(state.needsNewGroup)
        XCTAssertTrue(state.poll(at: 2000).isEmpty)
        XCTAssertThrowsError(try state.replaceExpiredGroup(randomSeed: Data()))
        let replacement = Data(repeating: 0x77, count: 256)
        try state.replaceExpiredGroup(randomSeed: replacement)
        XCTAssertTrue(state.poll(at: 2100).isEmpty)
        XCTAssertEqual(state.poll(at: 2101).first?.bytes, SrtlaWire.control(SrtlaWire.reg1, payload: replacement))
    }

    func testServerCooldownRejectsLateConfirmationButNotOtherPath() throws {
        var state = try registeredState()
        _ = state.receive(SrtlaWire.control(SrtlaWire.rejected), on: 1, at: 100)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 1, at: 101)
        XCTAssertFalse(state.isRegistered(1)); XCTAssertTrue(state.isRegistered(2))
        XCTAssertFalse(state.poll(at: 60099).contains(where: { $0.path == 1 }))
        XCTAssertTrue(state.poll(at: 60100).contains(where: { $0.path == 1 }))
    }

    func testReplyTimeoutMonotonicTimeAndBounds() throws {
        var state = try registeredState()
        state.noteValidatedActivity(on: 2, at: 3500)
        _ = state.poll(at: 5000)
        XCTAssertFalse(state.isRegistered(1)); XCTAssertTrue(state.isRegistered(2))
        XCTAssertTrue(state.poll(at: 4999).isEmpty)
        XCTAssertTrue(state.poll(at: Int64.max).isEmpty)
        for id in UInt64(3)...8 { try state.addPath(id) }
        XCTAssertThrowsError(try state.addPath(9))
        XCTAssertThrowsError(try SrtlaRegistration(randomSeed: Data(repeating: 0, count: 255)))
    }

    private func makeState() throws -> SrtlaRegistration {
        var state = try SrtlaRegistration(randomSeed: seed)
        try state.addPath(1); try state.addPath(2)
        return state
    }
    private func registeredState() throws -> SrtlaRegistration {
        var state = try makeState()
        _ = state.poll(at: 0)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg2, payload: issuedGroup), on: 1, at: 1)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 1, at: 2)
        _ = state.receive(SrtlaWire.control(SrtlaWire.reg3), on: 2, at: 3)
        return state
    }
}
