import XCTest
@testable import NabcamCore

@MainActor
final class CameraSwitchTests: XCTestCase {
    private enum Failure: Error { case unsupported }
    func testSuccessfulChangeDoesNotRestore() async {
        let coordinator = CameraSwitchCoordinator()
        var events: [String] = []
        let result = await coordinator.run(apply: { events.append("attach new camera") },
                                           restore: { events.append("restore old camera") })
        XCTAssertEqual(result, .changed)
        XCTAssertEqual(events, ["attach new camera"])
        XCTAssertFalse(coordinator.isChanging)
    }
    func testConfigurationFailureRestoresPreviousCamera() async {
        let coordinator = CameraSwitchCoordinator()
        var events: [String] = []
        let result = await coordinator.run(apply: {
            events.append("new camera attached")
            throw Failure.unsupported
        }, restore: { events.append("previous camera restored") })
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(events, ["new camera attached", "previous camera restored"])
    }
    func testFailedRollbackRequiresCaptureShutdown() async {
        let coordinator = CameraSwitchCoordinator()
        let result = await coordinator.run(apply: { throw Failure.unsupported }, restore: { throw Failure.unsupported })
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(coordinator.isChanging)
    }
    func testStopWaitsForLateAttachmentAndRollbackAndRejectsConcurrentSwitch() async {
        let coordinator = CameraSwitchCoordinator()
        let entered = AsyncStream<Void>.makeStream()
        let finishAttachment = AsyncStream<Void>.makeStream()
        var events: [String] = []
        let change = Task {
            await coordinator.run(apply: {
                entered.continuation.yield(())
                // An actual device call need not respond to task cancellation.
                // Detached wait models that behavior without touching hardware.
                let pending = Task.detached {
                    for await _ in finishAttachment.stream { break }
                }
                await pending.value
                events.append("late attachment")
            }, restore: { events.append("restore") })
        }
        for await _ in entered.stream { break }
        let duplicate = await coordinator.run(apply: { events.append("unexpected duplicate") }, restore: {})
        XCTAssertEqual(duplicate, .busy)
        let stopEntered = AsyncStream<Void>.makeStream()
        let stopping = Task {
            stopEntered.continuation.yield(())
            let result = await coordinator.cancelAndWait()
            events.append("stop complete")
            return result
        }
        for await _ in stopEntered.stream { break }
        XCTAssertTrue(coordinator.isChanging)
        XCTAssertTrue(events.isEmpty)
        finishAttachment.continuation.yield(())
        let stopped = await stopping.value
        let changed = await change.value
        XCTAssertEqual(stopped, .cancelled)
        XCTAssertEqual(changed, .cancelled)
        XCTAssertEqual(events, ["late attachment", "restore", "stop complete"])
        XCTAssertFalse(coordinator.isChanging)
        let idle = await coordinator.cancelAndWait()
        XCTAssertNil(idle)
    }
}
