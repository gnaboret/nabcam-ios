import Combine
import CoreGraphics
import NabcamCore
import UIKit
@preconcurrency import WebKit

/// Owns a single untrusted widget. The host must attach the view to a window
/// before requesting snapshots. Never put page URLs or errors in diagnostics.
@MainActor
final class BrowserOverlayPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum State: Equatable { case idle, loading, ready, failed, stopped }
    let source: BrowserOverlayConfiguration
    let view: WKWebView
    @Published private(set) var state: State = .idle
    private(set) var snapshotInFlight = false
    private var generation: UInt64 = 0
    private var snapshotID: UInt64 = 0
    private var timeout: Task<Void, Never>?

    init(source: BrowserOverlayConfiguration) throws {
        self.source = try source.validated()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: source.contentWidth, height: source.contentHeight), configuration: configuration)
        super.init()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    func load() {
        guard state != .stopped, source.enabled,
              let url = BrowserOverlayConfiguration.allowedURL(source.url) else { return }
        state = .loading
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    func stop() {
        generation &+= 1
        state = .stopped
        timeout?.cancel(); timeout = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    /// No queued work: the caller skips a refresh while a snapshot is outstanding.
    /// A stalled WebKit request fails this page, rather than admitting more work.
    @discardableResult
    func requestSnapshot(_ completion: @escaping @MainActor (CGImage?) -> Void) -> Bool {
        guard state == .ready, !snapshotInFlight, view.window != nil, let size = source.snapshotSize else { return false }
        snapshotInFlight = true
        snapshotID &+= 1
        let request = snapshotID
        let owner = generation
        let config = WKSnapshotConfiguration()
        config.rect = view.bounds
        config.snapshotWidth = NSNumber(value: size.width)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.snapshotID == request, self.snapshotInFlight else { return }
            self.state = .failed
            self.view.stopLoading()
            // Keep inFlight set until WebKit completes; never pile up requests.
        }
        view.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { completion(nil); return }
            guard self.snapshotID == request else { completion(nil); return }
            self.timeout?.cancel(); self.timeout = nil
            self.snapshotInFlight = false
            guard self.generation == owner, self.state == .ready, let original = image?.cgImage,
                  let context = CGContext(data: nil, width: size.width, height: size.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { completion(nil); return }
            // WKSnapshotConfiguration uses points. Explicitly bound physical
            // pixels even on Retina devices; preserve transparent backgrounds.
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            completion(context.makeImage())
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard state != .stopped else { return }
        generation &+= 1
        state = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state != .stopped, state != .failed else { return }
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        state = .ready
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if state != .stopped { state = .failed }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if state != .stopped { state = .failed }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if state != .stopped { state = .failed }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = state != .stopped && navigationAction.targetFrame != nil &&
            navigationAction.request.url.flatMap { BrowserOverlayConfiguration.allowedURL($0.absoluteString) } != nil
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, navigationAction.targetFrame?.isMainFrame == true, state != .stopped { state = .failed }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let validStatus = (navigationResponse.response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? true
        let allowed = state != .stopped && validStatus && navigationResponse.canShowMIMEType
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, navigationResponse.isForMainFrame, state != .stopped { state = .failed }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
}
