import XCTest

/// Walks the app and saves screenshots: the threads list, a chat with a subagent
/// and its transcript, a held permission prompt, a question, the composer mid-turn,
/// and the new-chat composer.
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
        // 1. Threads: running and waiting first, then the rest by machine.
        let deploy = element("run:Deploy the fleet-sandbox preview")
        XCTAssertTrue(deploy.waitForExistence(timeout: 30), "the runs should load")
        sleep(1)
        snap("01-threads")
        let plus = element("newRun.open")

        // 2. A chat whose Agent call draws as a subagent row, then that subagent's transcript.
        deploy.tap()
        let subagent = element("subagent.toolu_agent_check")
        XCTAssertTrue(subagent.waitForExistence(timeout: 20), "the Agent call should draw as a subagent row")
        reveal(subagent)
        sleep(1)
        snap("02-chat")
        subagent.tap()
        XCTAssertTrue(element("agent.transcript").waitForExistence(timeout: 20), "the subagent's transcript should open")
        sleep(1)
        snap("03-subagent")
        let done = element("sheet.done")
        if done.waitForExistence(timeout: 5) { done.tap() }
        sleep(1)
        back(until: plus)

        // 3. A held permission prompt: Allow once, Allow this tool, Deny.
        open("run:Run the fleet-sandbox migrations", until: "permission")
        snap("04-permission")
        back(until: plus)

        // 4. A question the agent asks, with its options.
        open("run:Should the queue table use Postgres or SQLite?", until: "question")
        snap("05-question")
        back(until: plus)

        // 5. The composer on a run mid-turn: Queue and Send now (the main one), and Stop.
        open("run:Fix dropped queue messages under load", until: "composer.field")
        let field = element("composer.field")
        field.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            field.typeText("Also cover the retry path when the socket drops")
        }
        sleep(1)
        snap("06-composer")
        back(until: plus)

        // 6. A new chat: the hero composer.
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "back should reach the threads list")
        plus.tap()
        let prompt = element("newRun.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "machines with harnesses should load")
        prompt.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            prompt.typeText("Add a health check to the sandbox deploy")
        }
        sleep(1)
        snap("07-new-chat")
    }

    /// Opens a thread from the list and waits for an element of its chat.
    private func open(_ row: String, until id: String) {
        let link = element(row)
        XCTAssertTrue(link.waitForExistence(timeout: 10), "\(row) should be listed")
        link.tap()
        XCTAssertTrue(element(id).waitForExistence(timeout: 20), "\(id) should show")
        sleep(1)
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

    /// Taps back until `target` shows, a few times at most.
    private func back(until target: XCUIElement) {
        for _ in 0..<3 where !target.waitForExistence(timeout: 2) {
            back()
        }
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
