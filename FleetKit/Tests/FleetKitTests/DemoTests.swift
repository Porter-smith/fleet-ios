import XCTest
@testable import FleetKit

/// The demo mode answers the client like a server would, through URLSession.
final class DemoTests: XCTestCase {
    func testServesTheAPI() async throws {
        let client = Demo.client()
        let runs = try await client.runs()
        XCTAssertEqual(runs.count, 6)
        let newest = try XCTUnwrap(runs.compactMap(\.updatedAt).max())
        XCTAssertEqual(newest / 1000, Date().timeIntervalSince1970 - 60, accuracy: 120, "times are moved to now")

        let detail = try await client.run(Demo.busyRun)
        XCTAssertEqual(detail.run.title, "Fix dropped queue messages under load")
        XCTAssertNotNil(detail.capabilities)
        let deploy = try await client.run(Demo.deployRun)
        let sessionId = try XCTUnwrap(deploy.run.sessionId)
        let agents = try await client.agents(sessionId: sessionId, machineId: deploy.run.machineId)
        XCTAssertFalse(agents.isEmpty)
        let harnesses = try await client.harnesses()
        XCTAssertFalse(harnesses.isEmpty)
        let me = try await client.me()
        XCTAssertEqual(me.actor.kind, "admin")
    }

    func testStreamStaysOpenAfterTheReplay() async throws {
        var runs = 0
        var events = 0
        for try await message in Demo.client().stream(Demo.deployRun, after: nil) {
            switch message {
            case .run: runs += 1
            case .event: events += 1
            default: break
            }
            if events == 10 { break }
        }
        XCTAssertGreaterThanOrEqual(runs, 1)
        XCTAssertEqual(events, 10)
    }

    func testUnknownRouteIs404() async {
        do {
            _ = try await Demo.client().run("r_nope")
            XCTFail("expected a 404")
        } catch {}
    }
}
