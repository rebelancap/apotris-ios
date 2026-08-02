import XCTest

/// End-to-end gesture verification: real synthesized touches through the
/// real gesture engine into the real game core, asserted via the debug HUD
/// (g=gameplay, pawn=x,y, rot, pc=pieces placed). Charter rule 6: every
/// input claim gets an artifact — these tests are the artifact generator.
final class ApotrisUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launchApp(scheme: String = "gestures",
                           extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-showDebugHUD", "YES",
            "-controlScheme", scheme,
            "-hapticsEnabled", "NO",
        ] + extraArgs
        app.launch()
        let hud = app.staticTexts["debugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 20), "debug HUD missing")
        return app
    }

    private func hud(_ app: XCUIApplication) -> String {
        app.staticTexts["debugHUD"].label
    }

    private func hudInt(_ app: XCUIApplication, _ key: String) -> Int? {
        let text = hud(app)
        guard let range = text.range(of: "\(key)=") else { return nil }
        let tail = text[range.upperBound...]
        let token = tail.prefix(while: { $0 == "-" || $0.isNumber })
        return Int(token)
    }

    private func pawnX(_ app: XCUIApplication) -> Int? {
        let text = hud(app)
        guard let range = text.range(of: "pawn=") else { return nil }
        let tail = text[range.upperBound...]
        let parts = tail.split(separator: " ").first?.split(separator: ",")
        return parts?.first.flatMap { Int($0) }
    }

    private func inGameplay(_ app: XCUIApplication) -> Bool {
        hud(app).hasPrefix("g=1")
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func center(_ app: XCUIApplication, _ dx: Double, _ dy: Double)
        -> XCUICoordinate
    {
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }

    /// Tap = menu Confirm; swipe down = menu Down. Walks from the title into
    /// a running Marathon game using only real touches.
    @discardableResult
    private func reachGameplay(_ app: XCUIApplication) -> Bool {
        settle(2.5)
        for attempt in 0..<12 {
            if inGameplay(app) { return true }
            if attempt > 0 && attempt % 4 == 3 {
                // Stuck on a value row: step down to the next menu row.
                center(app, 0.5, 0.40).press(
                    forDuration: 0.05,
                    thenDragTo: center(app, 0.5, 0.55),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
            } else {
                center(app, 0.5, 0.45).tap()
            }
            settle(1.4)
        }
        return inGameplay(app)
    }

    private func screenshotArtifact(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Tests

    func testMenuTapsReachGameplay() {
        let app = launchApp()
        XCTAssertTrue(reachGameplay(app), "taps never reached gameplay: \(hud(app))")
        screenshotArtifact(app, "gameplay")
    }

    /// Hard-drop to spawn a fresh piece high in the board, so gravity and
    /// lock delay cannot race the assertion window.
    private func freshPiece(_ app: XCUIApplication) {
        flick(app)
        settle(0.6)
    }

    /// A decisive synthetic flick: short (~90 pt) at high velocity so the
    /// classifier decides inside its 120 ms window. XCUITest's `.fast`
    /// spreads long drags over too much time and correctly reads as a
    /// soft drop (asymmetric-cost rule).
    private func flick(_ app: XCUIApplication) {
        center(app, 0.5, 0.38).press(
            forDuration: 0.005,
            thenDragTo: center(app, 0.5, 0.49),
            withVelocity: 3000, thenHoldForDuration: 0.0)
    }

    func testHorizontalDragMovesPiece() {
        let app = launchApp()
        XCTAssertTrue(reachGameplay(app))
        settle(1.0)
        freshPiece(app)

        guard let before = pawnX(app) else { return XCTFail("no pawn in HUD") }
        // Drag right ~4 cells (cellPt 16 → 64pt; screen ~402pt wide → ~0.16).
        center(app, 0.35, 0.40).press(
            forDuration: 0.02,
            thenDragTo: center(app, 0.35 + 0.16, 0.40),
            withVelocity: 400, thenHoldForDuration: 0.02)
        settle(0.35)
        guard let after = pawnX(app) else { return XCTFail("no pawn after") }
        XCTAssertGreaterThanOrEqual(after, before + 2,
            "drag right should move piece ≥2 cells (\(before) → \(after)) hud=\(hud(app))")

        // And back left.
        center(app, 0.6, 0.40).press(
            forDuration: 0.02,
            thenDragTo: center(app, 0.6 - 0.16, 0.40),
            withVelocity: 400, thenHoldForDuration: 0.02)
        settle(0.35)
        guard let after2 = pawnX(app) else { return XCTFail("no pawn after2") }
        XCTAssertLessThanOrEqual(after2, after - 2,
            "drag left should move piece back (\(after) → \(after2))")
        screenshotArtifact(app, "after-drags")
    }

    func testFlickHardDrops() {
        let app = launchApp()
        XCTAssertTrue(reachGameplay(app))
        settle(1.0)

        guard let piecesBefore = hudInt(app, "pc") else {
            return XCTFail("no pc in HUD")
        }
        // Fast downward flick — must classify as hard drop.
        flick(app)
        settle(0.8)
        guard let piecesAfter = hudInt(app, "pc") else {
            return XCTFail("no pc after")
        }
        XCTAssertGreaterThan(piecesAfter, piecesBefore,
            "flick should hard-drop and place a piece (\(piecesBefore) → \(piecesAfter))")
    }

    func testTapRotates() {
        let app = launchApp()
        XCTAssertTrue(reachGameplay(app))
        settle(1.0)

        var rotated = false
        var log = ""
        for _ in 0..<4 { // O piece may not change rotation; try a few pieces
            freshPiece(app)
            let before = hudInt(app, "rot")
            center(app, 0.75, 0.40).tap()
            settle(0.4)
            let after = hudInt(app, "rot")
            log += "(\(before ?? -9)→\(after ?? -9)) "
            if before != nil, after != nil, before! != after! {
                rotated = true
                break
            }
        }
        XCTAssertTrue(rotated, "tap right half should rotate CW: \(log) hud=\(hud(app))")
    }

    func testSettingsSheetTogglesScheme() {
        let app = launchApp() // gestures scheme: no d-pad initially
        settle(2.0)
        XCTAssertFalse(app.descendants(matching: .any)["gbDpad"].firstMatch.exists)

        app.buttons["chipSettings"].firstMatch.tap()
        // Anchor on the Controls section itself: rows further down the Form are
        // lazily rendered, so anything below the fold may not exist yet.
        let gbOption = app.buttons["GB Buttons"].firstMatch
        XCTAssertTrue(gbOption.waitForExistence(timeout: 5), "settings sheet missing")

        gbOption.tap() // segmented picker option
        app.buttons["Done"].firstMatch.tap()
        settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["gbDpad"].firstMatch
            .waitForExistence(timeout: 5),
            "switching scheme should show the GB overlay")
        screenshotArtifact(app, "settings-scheme-switch")
    }

    /// The Audio section: the five-mode picker reaches every option, selecting
    /// one updates the explanation, and the volume row is present. The session
    /// side of the same change is asserted from the app's own log (see
    /// "[apotris] audio: session -> Playback opts N").
    func testAudioSettingsSection() {
        // Pin the mode: this test changes it, and the change persists, so an
        // unpinned re-run would start from whatever the last run selected.
        let app = launchApp(extraArgs: ["-audioMode", "2", "-gameVolume", "1.0"])
        settle(2.0)
        app.buttons["chipSettings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["GB Buttons"].firstMatch.waitForExistence(timeout: 5),
                      "settings sheet missing")

        // The Audio section sits below the fold of the medium detent, and Form
        // rows are lazily rendered — scroll until it exists.
        let modeRow = app.staticTexts["Other app audio"].firstMatch
        for _ in 0..<4 where !modeRow.exists {
            app.swipeUp()
            settle(0.4)
        }
        if !modeRow.exists {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "settings-hierarchy"
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(modeRow.exists, "Audio section missing from settings")

        // Default mode is "Lower Other Audio" — its sentence is the footer.
        XCTAssertTrue(app.staticTexts[
            "Music and podcasts drop to the background; game audio stays full."]
            .firstMatch.waitForExistence(timeout: 5),
            "default audio mode explanation missing")
        XCTAssertTrue(app.staticTexts["Game volume"].firstMatch.exists,
                      "game volume row missing")
        screenshotArtifact(app, "settings-audio-section")

        tapText(app, "Other app audio")
        settle(1.5)
        screenshotArtifact(app, "settings-audio-modes")

        for raw in 0..<5 {
            let row = app.descendants(matching: .any)["audioMode\(raw)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "picker missing mode row \(raw)")
        }
        // Each option carries its explanation as a caption — the captions are
        // the point of this screen, so assert one is actually rendered.
        let caption = "Game audio goes silent while another app is playing."
        let captioned = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", caption))
            .firstMatch
        XCTAssertTrue(captioned.exists, "option captions missing from the picker")

        app.descendants(matching: .any)["audioMode4"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[
            "Game audio goes silent while another app is playing."]
            .firstMatch.waitForExistence(timeout: 5),
            "selecting a mode should update the explanation")

        app.buttons["Done"].firstMatch.tap()
        settle(1.0)
        XCTAssertTrue(inGameplay(app) || hud(app).hasPrefix("g="),
                      "app should still be running after the audio change")
    }

    /// Form rows render as buttons on some OS versions and plain cells on
    /// others; tapping the label's text hits the row either way.
    private func tapText(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
        } else {
            app.staticTexts[label].firstMatch.tap()
        }
    }

    func testBackgroundResumeKeepsRunning() {
        let app = launchApp()
        settle(2.0)
        let f1 = hudInt(app, "f") ?? -1
        XCUIDevice.shared.press(.home)
        settle(1.5)
        app.activate()
        settle(2.0)
        let f2 = hudInt(app, "f") ?? -1
        XCTAssertGreaterThan(f2, f1,
            "frames must keep advancing after background→resume (\(f1) → \(f2))")
    }

    func testGBButtonsMovePiece() {
        let app = launchApp(scheme: "both")
        XCTAssertTrue(reachGameplay(app))
        settle(1.0)
        screenshotArtifact(app, "gb-buttons-layout")

        let dpad = app.descendants(matching: .any)["gbDpad"].firstMatch
        if !dpad.exists {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "hierarchy"
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(dpad.exists, "d-pad overlay missing in buttons scheme")
        freshPiece(app)
        guard let before = pawnX(app) else { return XCTFail("no pawn") }
        dpad.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        settle(0.4)
        guard let after = pawnX(app) else { return XCTFail("no pawn after") }
        XCTAssertEqual(after, before + 1,
            "d-pad right tap should move exactly 1 cell (\(before) → \(after))")
    }
}
