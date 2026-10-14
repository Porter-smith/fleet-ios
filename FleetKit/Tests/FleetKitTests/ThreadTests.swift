import XCTest
@testable import FleetKit

/// The chat's rows, as web/src/fleet-chat/model.ts builds them.
final class ThreadTests: XCTestCase {
    private func events(_ name: String) throws -> (run: Run?, events: [RunEvent]) {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var run: Run?
        var events: [RunEvent] = []
        for line in splitter.push(try Fixture.data(name, "txt")) {
            guard let message = parser.push(line: line), let decoded = RunStreamMessage.decode(message) else { continue }
            switch decoded {
            case .run(let value): run = value
            case .event(let value): events.append(value)
            default: break
            }
        }
        return (run, events)
    }

    private func event(_ seq: Int, _ type: String, _ data: [String: JSONValue], at: Double? = nil) -> RunEvent {
        RunEvent(runId: "r_1", seq: seq, at: at ?? Double(seq) * 100, type: type, agent: nil, data: data)
    }

    func testDeployRunShowsTheAgentTheCommandsAndTheRefusal() throws {
        let rows = ChatThread.items(events: try events("stream_subagent").events)
        XCTAssertEqual(rows.map(\.kind), [.note, .user, .assistant, .user, .assistant, .spawn, .tools, .permission])

        let spawn = try XCTUnwrap(rows.first { $0.kind == .spawn })
        XCTAssertEqual(spawn.agents.first?.name, "Check the preview config")
        XCTAssertEqual(spawn.agents.first?.agentId, "a1b2c3d4e")
        XCTAssertEqual(spawn.agents.first?.pending, false)

        let tools = try XCTUnwrap(rows.first { $0.kind == .tools })
        XCTAssertEqual(tools.calls.first?.kind, .bash)
        XCTAssertEqual(tools.calls.first?.target, "porter deploy fleet-sandbox --env preview")
        XCTAssertEqual(tools.calls.first?.failed, true)
        XCTAssertEqual(ChatThread.summarize(tools.calls), "Ran 1 command (1 failed)")

        let refused = try XCTUnwrap(rows.last)
        XCTAssertEqual(refused.tool, "Bash")
        XCTAssertEqual(refused.command, "porter deploy fleet-sandbox --env preview")
    }

    func testHeldQuestionOpensItsCard() throws {
        let stream = try events("stream_question")
        let run = try XCTUnwrap(stream.run)
        XCTAssertEqual(run.pendingPermission?.tool, "AskUserQuestion")
        let rows = ChatThread.items(events: stream.events, pendingPermission: run.pendingPermission)
        XCTAssertEqual(rows.map(\.kind), [.user, .thinking, .tools, .assistant, .question])
        XCTAssertEqual(rows[1].seconds, 3)
        XCTAssertEqual(ChatThread.summarize(rows[2].calls), "Read 1 file, searched 1 time")
        XCTAssertEqual(rows[2].calls.first?.count, 128)
        let question = rows[4]
        XCTAssertTrue(question.open)
        XCTAssertNil(question.answer)
        XCTAssertEqual(question.text, "Which database should the queue table use?")
        XCTAssertEqual(question.options.map(\.label), ["Postgres", "SQLite"])
    }

    func testHeldPermissionIsTheLastRow() throws {
        let stream = try events("stream_permission")
        let run = try XCTUnwrap(stream.run)
        let rows = ChatThread.items(events: stream.events, pendingPermission: run.pendingPermission)
        let last = try XCTUnwrap(rows.last)
        XCTAssertEqual(last.kind, .permissionRequest)
        XCTAssertEqual(last.requestId, "req-hold-1")
        XCTAssertEqual(last.tool, "Bash")
        XCTAssertEqual(last.command, "bun run db:migrate --env preview")
    }

    func testAnsweredQuestionTakesTheResult() {
        let rows = ChatThread.items(events: [
            event(1, "tool_use", ["id": .string("t1"), "name": .string("AskUserQuestion"), "input": .object(["questions": .array([.object(["question": .string("Pick one"), "options": .array([.string("A"), .string("B")])])])])]),
            event(2, "tool_result", ["toolUseId": .string("t1"), "text": .string(#"User has answered your questions: "Pick one"="B"."#)]),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].answer, "B")
        XCTAssertFalse(rows[0].open)
    }

    func testEditsShowTheirDiff() {
        let edit = ChatThread.editOf(name: "Edit", detail: #"{"file_path":"a.ts","old_string":"one\ntwo\nthree","new_string":"one\n2\nthree"}"#, summary: nil)
        XCTAssertEqual(edit.path, "a.ts")
        XCTAssertEqual(edit.diff, [" one", "-two", "+2", " three"])
        XCTAssertEqual(edit.added, 1)
        XCTAssertEqual(edit.removed, 1)

        let write = ChatThread.editOf(name: "Write", detail: #"{"file_path":"b.ts","content":"x\ny\n"}"#, summary: nil)
        XCTAssertTrue(write.created)
        XCTAssertEqual(write.diff, ["+x", "+y"])

        // The server cuts stored input at 2000 characters: what there is, without counts.
        let cut = ChatThread.editOf(name: "Edit", detail: #"{"file_path":"c.ts","old_string":"a\nb","new_string":"a\nc\"#, summary: nil)
        XCTAssertEqual(cut.path, "c.ts")
        XCTAssertNil(cut.added)
        XCTAssertEqual(cut.diff, ["-a", "-b", "+a", "+c", "…"])
    }

    func testFieldOfReadsCutJSON() {
        XCTAssertEqual(ChatThread.fieldOf(#"{"command":"ls \"a b\"","x":1}"#, "command")?.text, #"ls "a b""#)
        XCTAssertEqual(ChatThread.fieldOf(#"{"command":"ls \"a b\"","x":1}"#, "command")?.whole, true)
        let cut = ChatThread.fieldOf(#"{"command":"echo hi\n"#, "command")
        XCTAssertEqual(cut?.whole, false)
        XCTAssertNil(ChatThread.fieldOf("{}", "command"))
    }

    func testSummaries() {
        func call(_ kind: ToolCall.Kind, _ name: String, failed: Bool = false) -> ToolCall {
            ToolCall(kind: kind, id: UUID().uuidString, name: name, target: "", failed: failed, pending: false)
        }
        XCTAssertEqual(ChatThread.summarize([call(.bash, "Bash"), call(.bash, "Bash", failed: true), call(.fetch, "WebFetch")]), "Ran 2 commands (1 failed), fetched 1 page")
        XCTAssertEqual(ChatThread.summarize([call(.other, "TodoWrite"), call(.other, "Skill"), call(.other, "Skill")]), "Updated the todo list, used Skill 2 times")
    }

    func testRespondCarriesTheAnswer() {
        XCTAssertEqual(FleetClient.respondBody(decision: .allowOnce, answer: "Postgres"), ["decision": "allow_once", "answer": "Postgres"])
        XCTAssertEqual(FleetClient.respondBody(decision: .deny, message: "not now"), ["decision": "deny", "message": "not now"])
    }

    func testNewChatHoldsPermissionsAndGatesClaudeOptions() throws {
        let claude = NewRun.chat(machineId: "m", harness: "claude", prompt: "hi", effort: "high")
        XCTAssertEqual(claude.holdPermissions, true)
        XCTAssertEqual(claude.permissionMode, "acceptEdits")
        XCTAssertEqual(claude.effort, "high")

        let codex = NewRun.chat(machineId: "m", harness: "codex", prompt: "hi", permissionMode: "plan", effort: "high")
        XCTAssertEqual(codex.holdPermissions, true)
        XCTAssertNil(codex.permissionMode)
        XCTAssertNil(codex.effort)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as? [String: Any])
        XCTAssertEqual(body["holdPermissions"] as? Bool, true)
        XCTAssertNil(body["permissionMode"])
    }

    func testLabels() {
        XCTAssertEqual(ChatThread.relTime(30_000), "now")
        XCTAssertEqual(ChatThread.relTime(5 * 60_000), "5m")
        XCTAssertEqual(ChatThread.relTime(3 * 3_600_000), "3h")
        XCTAssertEqual(ChatThread.effortLabel("xhigh"), "XHigh")
        XCTAssertEqual(ChatThread.permissionLabel("acceptEdits"), "Accept edits")
        XCTAssertEqual(ChatThread.permissionLabel(nil), "Default permissions")
    }
}
