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
        let addWatermark = app.buttons["Add image watermark"]
        for _ in 0..<12 {
            if fullyVisible(addWatermark, in: app, form: form) { break }
            scroll(form)
        }
        attach("settings-overlays", app: app)
        XCTAssertTrue(addWatermark.exists)
        XCTAssertTrue(addWatermark.isHittable)
        XCTAssertTrue(fullyVisible(addWatermark, in: app, form: form))
        let diagnostics = app.buttons["Share diagnostic timeline"]
        for _ in 0..<8 {
            if fullyVisible(diagnostics, in: app, form: form) { break }
            scroll(form)
        }
        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(fullyVisible(diagnostics, in: app, form: form))
        attach("settings-diagnostics", app: app)
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

    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication, form: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return frame.minY >= app.navigationBars["Settings"].frame.maxY + 8
            && frame.maxY <= form.frame.maxY - 24
    }

    private func scroll(_ form: XCUIElement) {
        let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
    }
}
