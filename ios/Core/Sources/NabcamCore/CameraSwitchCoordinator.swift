import Foundation

/// Serializes camera replacement with shutdown. Transport, audio and encoder
/// sessions are deliberately outside this operation and must not be restarted.
@MainActor
public final class CameraSwitchCoordinator {
    public enum Outcome: Sendable, Equatable { case changed, restored, cancelled, unavailable, busy }
    private var operation: Task<Outcome, Never>?
    public var isChanging: Bool { operation != nil }
    public init() {}

    public func run(apply: @escaping @MainActor @Sendable () async throws -> Void,
                    restore: @escaping @MainActor @Sendable () async throws -> Void) async -> Outcome {
        guard operation == nil else { return .busy }
        let task = Task<Outcome, Never> {
            guard !Task.isCancelled else { return .cancelled }
            do {
                try await apply()
                try Task.checkCancellation()
                return .changed
            } catch {
                // Camera APIs may finish an attachment despite task cancellation.
                // Restore before acknowledging Stop so no late camera survives it.
                do { try await restore() }
                catch { return .unavailable }
                return Task.isCancelled ? .cancelled : .restored
            }
        }
        operation = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        operation = nil
        return result
    }

    public func cancelAndWait() async -> Outcome? {
        guard let operation else { return nil }
        operation.cancel()
        return await operation.value
    }
}
