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
        let microphoneFrame = app.buttons["MIC ON"].frame
        let cameraFrame = app.buttons["SELFIE"].frame
        settings.tap()
        if app.alerts.buttons["OK"].waitForExistence(timeout: 3) {
            app.alerts.buttons["OK"].tap()
        }
        if !app.navigationBars["Settings"].exists { settings.tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let form = app.descendants(matching: .any).matching(identifier: "settings-form").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        let fps = app.switches["hub-fps-toggle"]
        XCTAssertEqual(fps.value as? String, "1")
        setSwitch(fps, to: "0", app: app, name: "fps")
        let resolution = app.switches["hub-resolution-toggle"]
        XCTAssertEqual(resolution.value as? String, "1")
        setSwitch(resolution, to: "0", app: app, name: "resolution")
        let upload = app.switches["hub-upload-toggle"]
        for _ in 0..<8 {
            if fullyVisible(upload, in: app, form: form) { break }
            scroll(form, toward: upload)
        }
        XCTAssertEqual(upload.value as? String, "0")
        setSwitch(upload, to: "1", app: app, name: "upload")
        let grid = app.switches["hub-grid-toggle"]
        for _ in 0..<8 {
            if fullyVisible(grid, in: app, form: form) { break }
            scroll(form, toward: grid)
        }
        XCTAssertEqual(grid.value as? String, "0")
        setSwitch(grid, to: "1", app: app, name: "grid")
        let flashlightShortcut = app.switches["hub-flashlight-toggle"]
        for _ in 0..<8 {
            if fullyVisible(flashlightShortcut, in: app, form: form) { break }
            scroll(form, toward: flashlightShortcut)
        }
        XCTAssertTrue(fullyVisible(flashlightShortcut, in: app, form: form))
        XCTAssertEqual(flashlightShortcut.value as? String, "0")
        setSwitch(flashlightShortcut, to: "1", app: app, name: "flashlight-shortcut")
        let hubSwap = app.switches["hub-swap-toggle"]
        for _ in 0..<8 {
            if fullyVisible(hubSwap, in: app, form: form) { break }
            scroll(form, toward: hubSwap)
        }
        XCTAssertTrue(fullyVisible(hubSwap, in: app, form: form))
        XCTAssertEqual(hubSwap.value as? String, "0")
        setSwitch(hubSwap, to: "1", app: app, name: "hub")
        app.buttons["Done"].tap()
        let hud = app.descendants(matching: .any).matching(identifier: "status-hud").firstMatch
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["upload-data-readout"].exists,
                       "Preview must not invent broadcast upload measurements")
        XCTAssertLessThan(settings.frame.maxX, hud.frame.minX)
        XCTAssertEqual(app.buttons["MIC ON"].frame, microphoneFrame)
        XCTAssertEqual(app.buttons["SELFIE"].frame, cameraFrame)
        if cameraUnavailable {
            XCTAssertFalse(app.staticTexts["capture-resolution-readout"].exists,
                           "Requested resolution must not be presented as observed camera output")
            XCTAssertFalse(app.buttons["Turn flashlight on"].exists,
                           "A shortcut preference must not invent unsupported camera hardware")
        }
        attach("preview-hub-settings-on-left", app: app)
        settings.tap()
        // Reopening starts at the top. SwiftUI's lazy Form need not expose a
        // lower switch until scrolled into view on a compact landscape phone.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if fullyVisible(fps, in: app, form: form) { break }
            scroll(form, toward: fps)
        }
        XCTAssertEqual(fps.value as? String, "0")
        setSwitch(fps, to: "1", app: app, name: "fps")
        for _ in 0..<8 {
            if fullyVisible(resolution, in: app, form: form) { break }
            scroll(form, toward: resolution)
        }
        XCTAssertEqual(resolution.value as? String, "0")
        setSwitch(resolution, to: "1", app: app, name: "resolution")
        for _ in 0..<8 {
            if fullyVisible(upload, in: app, form: form) { break }
            scroll(form, toward: upload)
        }
        XCTAssertEqual(upload.value as? String, "1")
        setSwitch(upload, to: "0", app: app, name: "upload")
        for _ in 0..<8 {
            if fullyVisible(grid, in: app, form: form) { break }
            scroll(form, toward: grid)
        }
        XCTAssertEqual(grid.value as? String, "1")
        setSwitch(grid, to: "0", app: app, name: "grid")
        for _ in 0..<8 {
            if fullyVisible(flashlightShortcut, in: app, form: form) { break }
            scroll(form, toward: flashlightShortcut)
        }
        XCTAssertEqual(flashlightShortcut.value as? String, "1")
        setSwitch(flashlightShortcut, to: "0", app: app, name: "flashlight-shortcut")
        for _ in 0..<8 {
            if fullyVisible(hubSwap, in: app, form: form) { break }
            scroll(form, toward: hubSwap)
        }
        setSwitch(hubSwap, to: "0", app: app, name: "hub")
        app.buttons["Done"].tap()
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertLessThan(hud.frame.maxX, settings.frame.minX)
        settings.tap()
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let handedness = app.switches["hub-left-handed-toggle"]
        for _ in 0..<8 {
            if fullyVisible(handedness, in: app, form: form) { break }
            scroll(form, toward: handedness)
        }
        setSwitch(handedness, to: "1", app: app, name: "left-handed")
        app.buttons["Done"].tap()
        XCTAssertLessThan(app.buttons["SELFIE"].frame.maxX, app.buttons["MIC ON"].frame.minX)
        XCTAssertLessThan(settings.frame.maxX, hud.frame.minX)
        let chatShortcut = app.buttons["preview-chat-toggle"]
        XCTAssertTrue(chatShortcut.isHittable)
        attach("preview-left-handed", app: app)
        settings.tap()
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if fullyVisible(handedness, in: app, form: form) { break }
            scroll(form, toward: handedness)
        }
        XCTAssertTrue(fullyVisible(handedness, in: app, form: form))
        XCTAssertEqual(handedness.value as? String, "1")
        setSwitch(handedness, to: "0", app: app, name: "left-handed")
        selectPage("camera", app: app)
        attach("settings-camera", app: app)
        if cameraUnavailable {
            XCTAssertFalse(app.switches["Lock focus"].exists)
            XCTAssertFalse(app.switches["Lock exposure"].exists)
        }
        selectPage("connection", app: app)
        let nameField = app.textFields["Connection name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Unsaved test connection")
        selectPage("video", app: app)
        selectPage("connection", app: app)
        XCTAssertEqual(nameField.value as? String, "Unsaved test connection",
                       "Changing settings pages must not discard connection edits")
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
        selectPage("video", app: app)
        let codec = app.descendants(matching: .any).matching(identifier: "video-codec-picker").firstMatch
        for _ in 0..<24 {
            if fullyVisible(codec, in: app, form: form) { break }
            scroll(form, toward: codec)
        }
        XCTAssertTrue(fullyVisible(codec, in: app, form: form))
        XCTAssertTrue(codec.label.contains("H.264") || (codec.value as? String)?.contains("H.264") == true)
        attach("settings-video-codec", app: app)
        selectPage("audio", app: app)
        let audio = app.descendants(matching: .any).matching(identifier: "audio-bitrate-picker").firstMatch
        for _ in 0..<24 {
            if fullyVisible(audio, in: app, form: form) { break }
            scroll(form, toward: audio)
        }
        XCTAssertTrue(fullyVisible(audio, in: app, form: form))
        XCTAssertTrue(audio.label.contains("96 kbps") || (audio.value as? String)?.contains("96 kbps") == true)
        attach("settings-audio", app: app)
        let processing = app.switches["microphone-processing-toggle"]
        for _ in 0..<24 {
            if fullyVisible(processing, in: app, form: form) { break }
            scroll(form, toward: processing)
        }
        XCTAssertTrue(fullyVisible(processing, in: app, form: form))
        XCTAssertEqual(processing.value as? String, "0")
        setSwitch(processing, to: "1", app: app, name: "microphone-processing")
        let gain = app.steppers["microphone-gain-stepper"]
        for _ in 0..<24 {
            if fullyVisible(gain, in: app, form: form) { break }
            scroll(form, toward: gain)
        }
        XCTAssertTrue(fullyVisible(gain, in: app, form: form))
        attach("settings-microphone-processing", app: app)
        selectPage("overlay", app: app)
        XCTAssertTrue(app.textFields["Kick channel name"].exists)
        let outgoingChat = app.switches["stream-chat-toggle"]
        for _ in 0..<12 {
            if fullyVisible(outgoingChat, in: app, form: form) { break }
            scroll(form, toward: outgoingChat)
        }
        XCTAssertTrue(fullyVisible(outgoingChat, in: app, form: form))
        XCTAssertTrue(outgoingChat.isEnabled)
        XCTAssertEqual(outgoingChat.value as? String, "0", "Outgoing chat must be opt-in")
        attach("settings-outgoing-chat", app: app)
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
        let browserSource = app.buttons["browser-source-1"]
        for _ in 0..<24 {
            if fullyVisible(browserSource, in: app, form: form) { break }
            scroll(form, toward: browserSource)
        }
        XCTAssertTrue(fullyVisible(browserSource, in: app, form: form))
        browserSource.tap()
        XCTAssertTrue(app.navigationBars["Browser source 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["browser-source-url"].exists)
        XCTAssertEqual(app.switches["browser-source-enabled"].value as? String, "0")
        attach("settings-browser-source", app: app)
        app.navigationBars.buttons["Settings"].tap()
        selectPage("advanced", app: app)
        // Visit the first row before scrolling down. On compact phones SwiftUI
        // removes offscreen Form rows from the accessibility tree, so a missing
        // row cannot tell the scroll helper whether it is above or below us.
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
        let diagnostics = app.buttons["Share diagnostic timeline"]
        for _ in 0..<24 {
            if fullyVisible(diagnostics, in: app, form: form) { break }
            scroll(form, toward: diagnostics)
        }
        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(fullyVisible(diagnostics, in: app, form: form))
        attach("settings-diagnostics", app: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        attach("preview-hud-simulator-no-camera", app: app)
        chatShortcut.tap()
        XCTAssertTrue(app.buttons["settings-tab-overlay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-tab-overlay"].isSelected)
        XCTAssertTrue(app.textFields["Kick channel name"].exists,
                      "Chat shortcut should open setup when no channel is configured")
        app.buttons["Done"].tap()
        verifyBitrateRelaunch(app: app)
    }

    private func verifyBitrateRelaunch(app: XCUIApplication) {
        app.buttons["Settings"].tap()
        selectPage("video", app: app)
        let form = app.descendants(matching: .any).matching(identifier: "settings-form").firstMatch
        let video = app.buttons["video-bitrate-picker"]
        for _ in 0..<12 {
            if fullyVisible(video, in: app, form: form) { break }
            scroll(form, toward: video)
        }
        XCTAssertTrue(fullyVisible(video, in: app, form: form))
        video.tap()
        app.buttons["2500 kbps"].tap()
        selectPage("audio", app: app)
        let audio = app.buttons["audio-bitrate-picker"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        app.buttons["128 kbps"].tap()
        app.buttons["Done"].tap()
        // Terminate the process: dismissing/reopening Settings alone would also
        // pass with transient @State and would not prove saved preferences.
        app.terminate()
        app.launch()
        let status = app.staticTexts["capture-status"]
        let settled = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Camera unavailable", "Preview · requested")
        let captureSettled = XCTNSPredicateExpectation(predicate: settled, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [captureSettled], timeout: 30), .completed)
        if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
        app.buttons["Settings"].tap()
        selectPage("video", app: app)
        for _ in 0..<12 {
            if fullyVisible(video, in: app, form: form) { break }
            scroll(form, toward: video)
        }
        XCTAssertTrue(fullyVisible(video, in: app, form: form))
        XCTAssertTrue(video.label.contains("2500 kbps") || (video.value as? String)?.contains("2500 kbps") == true)
        attach("settings-video-rate-after-relaunch", app: app)
        selectPage("audio", app: app)
        XCTAssertTrue(audio.label.contains("128 kbps") || (audio.value as? String)?.contains("128 kbps") == true)
        attach("settings-audio-rate-after-relaunch", app: app)
        // Restore defaults so a later test run does not inherit our selections.
        audio.tap()
        app.buttons["96 kbps"].tap()
        selectPage("video", app: app)
        for _ in 0..<12 {
            if fullyVisible(video, in: app, form: form) { break }
            scroll(form, toward: video)
        }
        XCTAssertTrue(fullyVisible(video, in: app, form: form))
        video.tap()
        app.buttons["1600 kbps"].tap()
        app.buttons["Done"].tap()
    }

    private func selectPage(_ name: String, app: XCUIApplication) {
        let tab = app.buttons["settings-tab-\(name)"]
        let tabs = app.scrollViews["settings-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        // Return to the leading edge before searching, so narrow phones and iPads
        // exercise the same real scrollable navigation without coordinate taps.
        for _ in 0..<3 {
            if tab.isHittable { break }
            tabs.swipeRight()
        }
        for _ in 0..<6 {
            if tab.isHittable { break }
            tabs.swipeLeft()
        }
        XCTAssertTrue(tab.isHittable, "Settings page should be reachable: \(name)")
        tab.tap()
        XCTAssertTrue(tab.isSelected)
        XCTAssertTrue(app.buttons["Done"].isHittable)
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

    private func setSwitch(_ row: XCUIElement, to value: String, app: XCUIApplication, name: String = "srtla") {
        XCTAssertTrue(row.isEnabled)
        let originalValue = row.value as? String
        XCTAssertNotEqual(originalValue, value, "The test must exercise a real setting change")
        // SwiftUI exposes both a full-width labelled switch row and the actual
        // trailing UISwitch. Tapping the row's centre may hit only its label.
        let control = row.switches.firstMatch
        if control.exists { control.tap() }
        else { row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: row)
        // Loaded hosted simulators can take several seconds to publish the new
        // accessibility snapshot even when the visible switch already changed.
        // iPad recordings show occasional synthesized taps leave the control
        // unchanged. Retry once at its centre only after confirming the original
        // state; never blindly toggle a control that already changed.
        var result = XCTWaiter.wait(for: [changed], timeout: 20)
        if result != .completed, row.value as? String == originalValue,
           originalValue != value, control.exists, control.isHittable {
            attach("settings-\(name)-unchanged-before-retry", app: app)
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let retried = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: row)
            result = XCTWaiter.wait(for: [retried], timeout: 20)
        }
        attach("settings-\(name)-after-toggle-\(value)", app: app)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(row.value as? String, value)
    }

    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication, form: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return frame.minY >= max(app.navigationBars["Settings"].frame.maxY, form.frame.minY) + 8
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
