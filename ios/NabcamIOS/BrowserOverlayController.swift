import Combine
import CoreGraphics
import NabcamCore

/// One refresh per page at a time, including delivery to the stream compositor.
/// Slow pages skip refreshes rather than building up a queue behind the stream.
@MainActor
final class BrowserOverlayController: ObservableObject {
    @Published private(set) var frames: [Int: CGImage] = [:]
    @Published private(set) var failedSources: Set<Int> = []
    private(set) var pages: [BrowserOverlayPage] = []
    private var refreshTask: Task<Void, Never>?
    private var delivering: Set<Int> = []
    private var generation: UInt64 = 0
    private weak var host: BrowserOverlayHost?
    private var deliver: (@MainActor (Int, CGImage?) async -> Void)?

    func start(sources: [BrowserOverlayConfiguration], host: BrowserOverlayHost,
               deliver: @escaping @MainActor (Int, CGImage?) async -> Void) throws {
        // Do not tear down a working configuration for an invalid proposal.
        _ = try BrowserOverlayArchive.encode(sources)
        let proposed = try sources.filter(\.enabled).map { try BrowserOverlayPage(source: $0) }
        stop()
        self.host = host
        self.deliver = deliver
        pages = proposed
        host.attach(proposed)
        for page in pages { page.load() }
        guard !pages.isEmpty else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func stop() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        for page in pages { page.stop() }
        pages.removeAll()
        host?.attach([])
        host = nil
        deliver = nil
        frames.removeAll()
        failedSources.removeAll()
        delivering.removeAll()
        // The owner removes the stream compositor on stop. Never deliver an
        // asynchronous clear here that could erase a replacement generation.
    }

    private func refresh() {
        let owner = generation
        for page in pages {
            let id = page.source.id
            guard !delivering.contains(id) else { continue }
            if page.state == .failed {
                guard !failedSources.contains(id) else { continue }
                failedSources.insert(id)
                frames[id] = nil
                send(id: id, image: nil, owner: owner)
            } else if page.state == .ready {
                page.requestSnapshot { [weak self] image in
                    guard let self, self.generation == owner else { return }
                    if page.source.destination != .streamOnly { self.frames[id] = image }
                    self.send(id: id, image: image, owner: owner)
                }
            }
        }
    }

    private func send(id: Int, image: CGImage?, owner: UInt64) {
        guard let deliver else { return }
        delivering.insert(id)
        Task { [weak self] in
            guard let self, self.generation == owner else { return }
            await deliver(id, image)
            guard self.generation == owner else { return }
            self.delivering.remove(id)
        }
    }
}
