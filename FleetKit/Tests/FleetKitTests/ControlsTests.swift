import XCTest
@testable import FleetKit

final class ControlsTests: XCTestCase {
    private func run(_ patch: [String: Any] = [:]) throws -> Run {
        var json: [String: Any] = ["id": "r_1", "machineId": "m", "harness": "claude", "status": "idle", "createdAt": 1, "turnOpen": false, "queued": 0, "origin": "fleet"]
        json.merge(patch) { $1 }
        return try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private let claude = HarnessCapabilities(midTurnInput: true)

    func testIdleRunSendsNow() throws {
        let controls = Controls(run: try run(), caps: claude)
        XCTAssertTrue(controls.send.enabled)
        XCTAssertTrue(controls.queue.enabled)
        XCTAssertFalse(controls.interrupt.enabled)
        XCTAssertEqual(controls.interrupt.reason, "No turn in progress")
        XCTAssertEqual(controls.primary.mode, "auto")
    }

    func testMidTurnWithoutMidTurnInputQueues() throws {
        var caps = claude
        caps.midTurnInput = false
        let controls = Controls(run: try run(["status": "running", "turnOpen": true]), caps: caps)
        XCTAssertFalse(controls.send.enabled)
        XCTAssertTrue(controls.interrupt.enabled)
        XCTAssertEqual(controls.primary.mode, "queue")
        XCTAssertEqual(controls.primary.label, "Queue")
    }

    func testQueuedMessagesKeepTheOrder() throws {
        let controls = Controls(run: try run(["status": "running", "turnOpen": true, "queued": 2]), caps: claude)
        XCTAssertFalse(controls.send.enabled)
        XCTAssertTrue(controls.send.reason.hasPrefix("2 queued messages waiting"))
    }

    func testEndedRunOnlyRestarts() throws {
        let controls = Controls(run: try run(["status": "failed", "endedAt": 5]), caps: claude)
        XCTAssertFalse(controls.send.enabled)
        XCTAssertFalse(controls.queue.enabled)
        XCTAssertFalse(controls.stop.enabled)
        XCTAssertEqual(controls.send.reason, "The run has failed. Restart to continue.")
        XCTAssertTrue(controls.restart.enabled)
    }

    func testExternalSession() throws {
        let controls = Controls(run: try run(["origin": "external", "status": "running", "turnOpen": true]), caps: claude)
        XCTAssertFalse(controls.send.enabled)
        XCTAssertFalse(controls.queue.enabled)
        XCTAssertFalse(controls.interrupt.enabled)
        XCTAssertTrue(controls.stop.enabled)
        XCTAssertFalse(controls.restart.enabled)
    }

    func testUnknownCapabilities() throws {
        let controls = Controls(run: try run(), caps: nil)
        XCTAssertFalse(controls.send.enabled)
        XCTAssertTrue(controls.send.reason.contains("doesn't know"))
        XCTAssertTrue(controls.restart.enabled)
    }

    func testFormat() {
        XCTAssertEqual(Format.modelLabel("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(Format.modelLabel("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(Format.modelLabel("opus"), "Opus (latest)")
        XCTAssertEqual(Format.modelLabel("gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(Format.modelLabel(nil), "Default model")
        XCTAssertEqual(Format.duration(seconds: 530), "8m 50s")
        XCTAssertEqual(Format.duration(seconds: 3900), "1h 5m")
        XCTAssertEqual(Format.tokenCount(950), "950")
        XCTAssertEqual(Format.tokenCount(272_480), "272.5k")
        XCTAssertEqual(Format.tokenCount(1_260_000), "1.3M")
        XCTAssertEqual(Format.tokenCount(2000), "2k")
    }
}
