import AVFoundation
import Foundation
import HaishinKit
import SRTHaishinKit

/// Retain one per broadcaster, not one per Start tap. HaishinKit owns the global
/// libsrt runtime; retaining its connection avoids overlapping global cleanup
/// with a replacement connection. A successful close resets its underlying socket.
actor SrtPublishSession: Session {
    enum PublishError: Error { case busy, notConfigured, unsupportedMode }
    private enum State { case idle, connecting, live, closing }
    let connection: SRTConnection
    let mediaStream: SRTStream
    private var options: SrtConnectionOptions?
    private var expectedMedias: Set<AVMediaType> = [.audio, .video]
    private var mode: SessionMode = .publish
    private var state = State.idle
    private var generation: UInt64 = 0
    private var connectTask: Task<Void, Error>?
    private var closeTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private let updates = AsyncStream<SessionReadyState>.makeStream(bufferingPolicy: .bufferingNewest(8))

    var readyState: AsyncStream<SessionReadyState> { updates.stream }
    var stream: any StreamConvertible { mediaStream }
    var connected: Bool {
        get async {
            guard state == .live else { return false }
            return await connection.connected
        }
    }

    init() {
        let client = SRTConnection()
        connection = client
        mediaStream = SRTStream(connection: client)
        updates.continuation.yield(.closed)
    }

    init(uri: URL, mode: SessionMode, configuration: (any SessionConfiguration)?) {
        let client = SRTConnection()
        connection = client
        mediaStream = SRTStream(connection: client)
        self.mode = mode
        options = try? SrtConnectionOptions(uri)
        updates.continuation.yield(.closed)
    }

    func configure(_ uri: URL, expectedMedias: Set<AVMediaType> = [.audio, .video]) throws {
        guard state == .idle else { throw PublishError.busy }
        options = try SrtConnectionOptions(uri)
        self.expectedMedias = expectedMedias
    }

    // Intentional: reconnect is user-controlled. The broadcaster must create a
    // fresh relay for a new session rather than silently replay queued media.
    func setMaxRetryCount(_ maxRetryCount: Int) {}

    func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
        guard state == .idle else { throw PublishError.busy }
        guard mode == .publish else { throw PublishError.unsupportedMode }
        guard let options else { throw PublishError.notConfigured }
        state = .connecting
        generation &+= 1
        let attempt = generation
        updates.continuation.yield(.connecting)
        let client = connection
        let output = mediaStream
        let expected = expectedMedias
        let task = Task {
            try Task.checkCancellation()
            try await options.apply(to: client)
            try Task.checkCancellation()
            try await client.connect(options.url)
            try Task.checkCancellation()
            await output.setExpectedMedias(expected)
            await output.publish()
            try Task.checkCancellation()
        }
        connectTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == attempt, state == .connecting else { throw CancellationError() }
            connectTask = nil
            state = .live
            updates.continuation.yield(.open)
            monitorTask = Task { [weak self, client] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    if await client.connected == false {
                        await self?.didDisconnect(attempt: attempt, callback: disconnected)
                        return
                    }
                }
            }
        } catch {
            // A concurrent Stop owns cleanup after incrementing generation. Do
            // not let an old connection completion close a later publish attempt.
            if generation == attempt { await close() }
            if Task.isCancelled || task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func close() async {
        if let closeTask { await closeTask.value; return }
        guard state != .idle else { return }
        state = .closing
        generation &+= 1
        let closingGeneration = generation
        updates.continuation.yield(.closing)
        monitorTask?.cancel(); monitorTask = nil
        let pending = connectTask
        pending?.cancel()
        connectTask = nil
        let client = connection
        let output = mediaStream
        let task = Task {
            // close() during pre-connect can be a no-op in HaishinKit. Wait for
            // the bounded native attempt, then close AGAIN so no late connection
            // survives Stop. configure() stays unavailable throughout this work.
            await client.close()
            _ = try? await pending?.value
            await output.close()
            await client.close()
        }
        closeTask = task
        await task.value
        guard generation == closingGeneration else { return }
        closeTask = nil
        state = .idle
        updates.continuation.yield(.closed)
    }

    private func didDisconnect(attempt: UInt64, callback: @Sendable () -> Void) async {
        guard generation == attempt, state == .live else { return }
        await close()
        callback()
    }

    deinit {
        connectTask?.cancel()
        monitorTask?.cancel()
        updates.continuation.finish()
    }
}
