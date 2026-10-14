import XCTest
@testable import FleetKit

final class DecodingTests: XCTestCase {
    func testMe() throws {
        let me = try Fixture.decode(MeResponse.self, "me")
        XCTAssertEqual(me.actor.kind, "admin")
        XCTAssertTrue(me.actor.missingScopes.isEmpty, "admin has every scope")
    }

    func testMachines() throws {
        let machines = try Fixture.decode(MachinesResponse.self, "machines").machines
        XCTAssertEqual(Set(machines.map(\.name)), ["MacBook Pro", "claude", "Mac mini"])
        let mini = try XCTUnwrap(machines.first { $0.name == "Mac mini" })
        XCTAssertFalse(mini.isReachable)
        XCTAssertNotNil(mini.lastError)
        let lxc = try XCTUnwrap(machines.first { $0.name == "claude" })
        XCTAssertEqual(lxc.harnesses["claude"]?.installed, true)
        XCTAssertEqual(lxc.harnesses["codex"]?.installed, true)
    }

    func testRuns() throws {
        let runs = try Fixture.decode(RunsResponse.self, "runs").runs
        XCTAssertGreaterThanOrEqual(runs.count, 6)
        XCTAssertFalse(runs.contains { $0.status == .unknown })
        let held = try XCTUnwrap(runs.first { $0.pendingPermission != nil })
        XCTAssertEqual(held.pendingPermission?.tool, "Bash")
        XCTAssertTrue(held.needsYou)
        let ended = runs.filter(\.isEnded)
        XCTAssertEqual(Set(ended.map(\.id)), ["r_devmini01", "r_devlxc01"])
        let long = try XCTUnwrap(runs.first { $0.title == "Fix dropped queue messages under load" })
        XCTAssertTrue(long.turnOpen)
        XCTAssertGreaterThan(long.stats?.tokens ?? 0, 0)
    }

    func testRunDetailCarriesMidTurnInput() throws {
        let detail = try Fixture.decode(RunDetail.self, "run_detail")
        XCTAssertEqual(detail.run.title, "Deploy the fleet-sandbox preview")
        XCTAssertEqual(detail.capabilities?.midTurnInput, true)
        XCTAssertTrue(detail.capabilities?.models.contains("claude-opus-5-5") ?? false)
        let held = try Fixture.decode(RunDetail.self, "run_detail_permission")
        XCTAssertEqual(held.run.pendingPermission?.requestId, "req-hold-1")
        XCTAssertEqual(held.run.pendingPermission?.input?["command"]?.string, "bun run db:migrate --env preview")
    }

    func testTranscriptPage() throws {
        let page = try Fixture.decode(TranscriptPage.self, "transcript_subagent")
        XCTAssertEqual(page.total, page.events.count)
        XCTAssertNil(page.next)
        let call = try XCTUnwrap(page.events.first { $0.type == "tool_use" && $0.data.string("name") == "Agent" })
        XCTAssertEqual(call.data.string("id"), "toolu_agent_check")
    }

    func testHarnessesReposAndAgents() throws {
        let machines = try Fixture.decode(HarnessesResponse.self, "harnesses").machines
        XCTAssertFalse(machines.isEmpty)
        XCTAssertNotNil(machines.first?.harnesses["claude"])
        XCTAssertNoThrow(try Fixture.decode(ReposResponse.self, "repos"))
        let agents = try Fixture.decode(AgentsResponse.self, "agents").agents
        XCTAssertEqual(agents.first?.id, "d4e5f6a7b8c9d0e1f")
        XCTAssertEqual(agents.first?.type, "Explore")
        XCTAssertEqual(agents.first?.isRunning, false)
        let transcript = try Fixture.decode(SessionTranscript.self, "agent_transcript")
        XCTAssertEqual(transcript.agent?.id, "d4e5f6a7b8c9d0e1f")
        XCTAssertFalse(transcript.events.isEmpty)
    }

    func testUnknownValuesDoNotFailTheList() throws {
        let json = #"{"runs":[{"id":"r_new","status":"hibernating","machineId":"m","harness":"claude","createdAt":1,"turnOpen":false,"queued":0,"brandNewField":{"x":1}}]}"#
        let runs = try JSONDecoder().decode(RunsResponse.self, from: Data(json.utf8)).runs
        XCTAssertEqual(runs.first?.status, .unknown)
    }

    func testErrorBodies() {
        XCTAssertEqual(FleetClient.failure(status: 409, body: Data(#"{"error":"codex can't queue"}"#.utf8)), .conflict("codex can't queue"))
        XCTAssertEqual(FleetClient.failure(status: 401, body: Data(#"{"error":"bad token"}"#.utf8)), .unauthorized("bad token"))
        XCTAssertEqual(FleetClient.failure(status: 500, body: Data("oops".utf8)), .http(500, "oops"))
    }

    func testNormalizeURL() {
        XCTAssertEqual(FleetClient.normalize("fleet.home.arpa/")?.absoluteString, "https://fleet.home.arpa")
        XCTAssertEqual(FleetClient.normalize(" http://127.0.0.1:8793 ")?.absoluteString, "http://127.0.0.1:8793")
        XCTAssertNil(FleetClient.normalize(""))
        XCTAssertNil(FleetClient.normalize("ftp://x"))
    }
}
