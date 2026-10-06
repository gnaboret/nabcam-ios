import CoreGraphics
import HaishinKit
import NabcamCore

/// Used only when browser sources need independent preview/stream placement.
/// This mixer receives existing camera frames; no device or audio is attached.
@MainActor
final class BrowserPreviewComposition {
    let mixer = MediaMixer()
    private var bridge: PreviewVideoBridge?
    private var sourceMixer: MediaMixer?
    private var images: StreamWatermarks?
    private var clock: StreamClock?
    private var browser: StreamBrowserOverlays?
    private var clockTask: Task<Void, Never>?

    func start(sourceMixer: MediaMixer, preset: VideoPreset,
               watermarks: [WatermarkConfiguration], clockEnabled: Bool,
               clockCorner: ClockCorner, sources: [BrowserOverlayConfiguration]) async throws {
        await stop()
        do {
            await mixer.setMonitoringEnabled(false)
            var settings = await mixer.videoMixerSettings
            settings.mode = .offscreen
            await mixer.setVideoMixerSettings(settings)
            try await mixer.setFrameRate(preset.fps)
            let images = try await StreamWatermarks(configurations: watermarks, width: preset.width, height: preset.height)
            self.images = images
            try await images.install(on: mixer.screen, width: preset.width, height: preset.height)
            if clockEnabled {
                let clock = await StreamClock()
                self.clock = clock
                try await clock.install(on: mixer.screen, corner: clockCorner, width: preset.width, height: preset.height)
                clockTask = Task {
                    while !Task.isCancelled {
                        await clock.update()
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
            }
            // Reuse exactly the same raster layout/opacity path as the stream,
            // selecting only widgets whose destination includes the preview.
            let previewSources = sources.filter { $0.destination != .streamOnly }.map { source in
                var copy = source
                copy.destination = .both
                return copy
            }
            let browser = await StreamBrowserOverlays()
            self.browser = browser
            try await browser.install(on: mixer.screen, sources: previewSources, width: preset.width, height: preset.height)
            await mixer.startRunning()
            let bridge = PreviewVideoBridge(destination: mixer)
            self.bridge = bridge
            self.sourceMixer = sourceMixer
            await sourceMixer.addOutput(bridge)
        } catch {
            await stop()
            throw error
        }
    }

    func update(id: Int, image: CGImage?) async {
        await browser?.update(id: id, image: image)
    }

    func stop() async {
        clockTask?.cancel()
        clockTask = nil
        if let bridge {
            await sourceMixer?.removeOutput(bridge)
            await bridge.stop()
        }
        bridge = nil
        sourceMixer = nil
        await mixer.stopRunning()
        await browser?.remove()
        await images?.remove()
        await clock?.remove()
        browser = nil
        images = nil
        clock = nil
    }
}
