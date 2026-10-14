import XCTest

/// Walks the app and saves screenshots: the runs list, a chat with a nested
/// subagent, the composer and its actions, and the new-run sheet.
///
/// By default the app runs in demo mode (`-FleetDemo`, the bundled fixtures), so
/// no server is needed. To walk a Fleet dev server (`bun scripts/dev-fleet.ts`)
/// instead, set FLEET_URL and FLEET_TOKEN in the test runner's environment; with
/// xcodebuild, pass TEST_RUNNER_FLEET_URL / TEST_RUNNER_FLEET_TOKEN.
/// TEST_RUNNER_SCREENSHOT_DIR also writes each shot there as a PNG.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var outDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SCREENSHOT_DIR"], !dir.isEmpty {
            outDir = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir!, withIntermediateDirectories: true)
        }
        app = XCUIApplication()
        if let url = env["FLEET_URL"], !url.isEmpty, let token = env["FLEET_TOKEN"], !token.isEmpty {
            app.launchEnvironment["FLEET_URL"] = url
            app.launchEnvironment["FLEET_TOKEN"] = token
        } else {
            app.launchArguments = ["-FleetDemo"]
        }
        app.launch()
    }

    func testScreenshotWalk() throws {
        // 1. Runs list, grouped by machine.
        let deploy = element("run:Deploy the fleet-sandbox preview")
        XCTAssertTrue(deploy.waitForExistence(timeout: 30), "the runs should load")
        sleep(1)
        snap("01-runs-list")

        // 2. A chat whose Agent call is opened onto its subagent's work.
        deploy.tap()
        let subagent = element("subagent.toolu_agent_check")
        XCTAssertTrue(subagent.waitForExistence(timeout: 20), "the Agent call should draw as a subagent row")
        reveal(subagent)
        subagent.tap()
        sleep(1)
        snap("02-chat-subagent")
        back()

        // 3. The composer on a run mid-turn: Queue, Send now, Interrupt.
        let busy = element("run:Fix dropped queue messages under load")
        XCTAssertTrue(busy.waitForExistence(timeout: 10))
        busy.tap()
        let field = element("composer.field")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            field.typeText("Also cover the retry path when the socket drops")
        }
        sleep(1)
        snap("03-composer")

        // 4. The run actions menu, each with its reason.
        let more = element("composer.more")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        sleep(1)
        snap("04-composer-actions")
        // Close the menu by tapping the chat above it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        back()

        // 5. The new-run sheet.
        let plus = element("newRun.open")
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        let prompt = element("newRun.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "machines with harnesses should load")
        prompt.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            prompt.typeText("Add a health check to the sandbox deploy")
        }
        sleep(1)
        snap("05-new-run")
    }

    // ---- helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls the chat up until the element is on screen.
    private func reveal(_ element: XCUIElement) {
        var tries = 0
        while !element.isHittable && tries < 6 {
            app.swipeDown()
            tries += 1
        }
    }

    private func back() {
        let button = app.navigationBars.buttons.firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() }
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let outDir {
            try? shot.pngRepresentation.write(to: outDir.appendingPathComponent("\(name).png"))
        }
    }
}
