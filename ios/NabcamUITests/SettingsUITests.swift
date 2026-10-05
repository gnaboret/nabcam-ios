import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    func testSettingsCanBeOpenedScrolledAndClosed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "Capture permission dialogs") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()
        XCUIDevice.shared.orientation = .landscapeRight
        // Finish both permission requests and the resulting real capture attempt
        // before opening Settings. A second permission alert can otherwise arrive
        // during a drag, followed by the simulator's camera-unavailable alert.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<6 {
            if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 3) {
                springboard.alerts.buttons["Allow"].tap()
            }
            if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
            let status = app.staticTexts["capture-status"]
            if status.exists && (status.label == "Camera unavailable" || status.label.hasPrefix("Preview · requested")) { break }
        }
        let settled = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Camera unavailable", "Preview · requested")
        expectation(for: settled, evaluatedWith: app.staticTexts["capture-status"])
        waitForExpectations(timeout: 15)
        if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
        // Simulator capture may be unavailable; acknowledge the real error rather
        // than replacing production capture with a fake-success test mode.
        let cameraUnavailable = app.staticTexts["capture-status"].label == "Camera unavailable"
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        if app.alerts.buttons["OK"].waitForExistence(timeout: 3) {
            app.alerts.buttons["OK"].tap()
        }
        if !app.navigationBars["Settings"].exists { settings.tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let form = app.descendants(matching: .any).matching(identifier: "settings-form").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        attach("settings-camera", app: app)
        if cameraUnavailable {
            XCTAssertFalse(app.switches["Lock focus"].exists)
            XCTAssertFalse(app.switches["Lock exposure"].exists)
        }
        let relayToggle = app.switches["experimental-srtla-toggle"]
        for _ in 0..<24 {
            if fullyVisible(relayToggle, in: app, form: form) { break }
            scroll(form, toward: relayToggle)
        }
        XCTAssertTrue(fullyVisible(relayToggle, in: app, form: form))
        XCTAssertEqual(relayToggle.value as? String, "0", "Experimental SRTLA must be off on a fresh launch")
        attach("settings-srtla-before-toggle", app: app)
        setSwitch(relayToggle, to: "1", app: app)
        let relayNotice = app.staticTexts["srtla-experimental-notice"]
        for _ in 0..<12 {
            if fullyVisible(relayNotice, in: app, form: form) { break }
            scroll(form, toward: relayNotice)
        }
        XCTAssertTrue(relayNotice.exists)
        XCTAssertTrue(relayNotice.label.contains("cannot select both SIMs"))
        XCTAssertTrue(relayNotice.label.contains("unverified"))
        attach("settings-experimental-srtla", app: app)
        for _ in 0..<12 {
            if fullyVisible(relayToggle, in: app, form: form) { break }
            scroll(form, toward: relayToggle)
        }
        setSwitch(relayToggle, to: "0", app: app)
        let codec = app.descendants(matching: .any).matching(identifier: "video-codec-picker").firstMatch
        for _ in 0..<24 {
            if fullyVisible(codec, in: app, form: form) { break }
            scroll(form, toward: codec)
        }
        XCTAssertTrue(fullyVisible(codec, in: app, form: form))
        XCTAssertTrue(codec.label.contains("H.264") || (codec.value as? String)?.contains("H.264") == true)
        attach("settings-video-codec", app: app)
        let audio = app.descendants(matching: .any).matching(identifier: "audio-bitrate-picker").firstMatch
        for _ in 0..<24 {
            if fullyVisible(audio, in: app, form: form) { break }
            scroll(form, toward: audio)
        }
        XCTAssertTrue(fullyVisible(audio, in: app, form: form))
        XCTAssertTrue(audio.label.contains("96 kbps") || (audio.value as? String)?.contains("96 kbps") == true)
        attach("settings-audio", app: app)
        let addWatermark = app.buttons["Add image watermark"]
        for attempt in 0..<40 {
            if fullyVisible(addWatermark, in: app, form: form) { break }
            scroll(form, toward: addWatermark)
            if attempt % 10 == 9 { attach("overlay-scroll-\(attempt + 1)", app: app) }
        }
        attach("settings-overlays", app: app)
        XCTAssertTrue(addWatermark.exists)
        XCTAssertTrue(addWatermark.isHittable)
        XCTAssertTrue(fullyVisible(addWatermark, in: app, form: form))
        let diagnostics = app.buttons["Share diagnostic timeline"]
        for _ in 0..<24 {
            if fullyVisible(diagnostics, in: app, form: form) { break }
            scroll(form, toward: diagnostics)
        }
        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(fullyVisible(diagnostics, in: app, form: form))
        attach("settings-diagnostics", app: app)
        let acknowledgments = app.buttons["Open-source acknowledgments"]
        for _ in 0..<24 {
            if fullyVisible(acknowledgments, in: app, form: form) { break }
            scroll(form, toward: acknowledgments)
        }
        XCTAssertTrue(fullyVisible(acknowledgments, in: app, form: form))
        acknowledgments.tap()
        let notices = app.staticTexts["third-party-notices"]
        XCTAssertTrue(notices.waitForExistence(timeout: 5))
        XCTAssertTrue(notices.label.contains("HaishinKit 2.2.5"))
        XCTAssertTrue(notices.label.contains("OpenSSL 3.3.2"))
        attach("settings-acknowledgments", app: app)
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        attach("preview-hud-simulator-no-camera", app: app)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func setSwitch(_ row: XCUIElement, to value: String, app: XCUIApplication) {
        XCTAssertTrue(row.isEnabled)
        // SwiftUI exposes both a full-width labelled switch row and the actual
        // trailing UISwitch. Tapping the row's centre may hit only its label.
        let control = row.switches.firstMatch
        if control.exists { control.tap() }
        else { row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: row)
        let result = XCTWaiter.wait(for: [changed], timeout: 5)
        attach("settings-srtla-after-toggle-\(value)", app: app)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(row.value as? String, value)
    }

    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication, form: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return frame.minY >= app.navigationBars["Settings"].frame.maxY + 8
            && frame.maxY <= form.frame.maxY - 24
    }

    private func scroll(_ form: XCUIElement, toward element: XCUIElement) {
        // Search with a larger stroke, then use small positioning corrections.
        // The leading inset avoids dragging through text fields and pickers.
        // Keep intermediate screenshots so stalled gestures can be distinguished
        // from simply exhausting the search before reaching a lazy Form row.
        let reverse = element.exists && element.frame.midY < form.frame.midY
        let startY = element.exists ? 0.6 : 0.8
        let endY = element.exists ? (reverse ? 0.78 : 0.42) : 0.4
        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: startY))
        let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: endY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
}
