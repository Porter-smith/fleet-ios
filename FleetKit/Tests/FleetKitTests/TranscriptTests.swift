import XCTest
@testable import FleetKit

final class TranscriptTests: XCTestCase {
    func testNestsSubagentWorkUnderItsAgentCall() throws {
        let page = try Fixture.decode(TranscriptPage.self, "transcript_subagent")
        var state = ChatState()
        state.apply(page.events)
        let items = state.items()
        XCTAssertFalse(items.contains { $0.agent != nil }, "subagent rows are nested, not top level")
        XCTAssertFalse(items.contains { $0.kind == .subagent })

        let call = try XCTUnwrap(items.first { $0.toolId == "toolu_agent_check" })
        XCTAssertEqual(call.subagent?.type, "Explore")
        XCTAssertEqual(call.subagent?.description, "Check the preview config")
        XCTAssertEqual(call.subagent?.agentId, "a1b2c3d4e5f60718")
        XCTAssertTrue(call.hasOutput)
        XCTAssertEqual(call.children.map(\.kind), [.tool, .assistant])
        XCTAssertEqual(call.children.first?.name, "Read")
        XCTAssertEqual(call.children.first?.hasOutput, true, "the subagent's tool result is paired with its call")

        let deploy = try XCTUnwrap(items.first { $0.toolId == "toolu_deploy" })
        XCTAssertTrue(deploy.outputIsError)
        XCTAssertFalse(items.contains { $0.name == "Result" }, "every result found its call")
        XCTAssertFalse(items.contains { $0.kind == .usage }, "allowed usage signals are not drawn")
    }

    func testAgentWorkWithoutItsCallBecomesAGroup() {
        let events = [
            RunEvent(seq: 1, type: "user", data: ["text": .string("hi")]),
            RunEvent(seq: 2, type: "assistant", agent: "toolu_gone", data: ["text": .string("sub says")]),
            RunEvent(seq: 3, type: "assistant", data: ["text": .string("main says")]),
        ]
        let items = Transcript.build(events: events)
        XCTAssertEqual(items.map(\.kind), [.user, .subagent, .assistant])
        XCTAssertEqual(items[1].children.first?.text, "sub says")
    }

    func testDeltasAreReplacedByTheirFinishedEvent() {
        var state = ChatState()
        state.apply(RunEvent(seq: 1, type: "user", data: ["text": .string("go")]))
        state.apply(RunDelta(key: "msg_1:0", text: "Hel"))
        state.apply(RunDelta(key: "msg_1:0", text: "lo"))
        XCTAssertEqual(state.items().last?.text, "Hello")
        XCTAssertEqual(state.items().last?.isPartial, true)
        state.apply(RunEvent(seq: 2, type: "assistant", data: ["key": .string("msg_1:0"), "text": .string("Hello")]))
        XCTAssertTrue(state.partials.isEmpty)
        XCTAssertEqual(state.items().map(\.text), ["go", "Hello"])
    }

    func testFinishedEventDropsOldestPartialOfItsKindWhenKeysDiffer() {
        var state = ChatState()
        state.apply(RunDelta(key: "a", kind: "thinking", text: "hmm"))
        state.apply(RunDelta(key: "b", kind: "text", text: "x"))
        state.apply(RunDelta(key: "c", kind: "text", text: "y", agent: "toolu_1"))
        state.apply(RunEvent(seq: 1, type: "assistant", data: ["key": .string("other"), "text": .string("x")]))
        XCTAssertEqual(state.partials.map(\.key), ["a", "c"])
        state.apply(RunEvent(seq: 2, type: "result", agent: "toolu_1", data: [:]))
        XCTAssertEqual(state.partials.map(\.key), ["a"])
        state.apply(RunEvent(seq: 3, type: "result", data: [:]))
        XCTAssertTrue(state.partials.isEmpty)
    }

    func testDedupesAndOrdersBySeq() {
        var state = ChatState()
        XCTAssertTrue(state.apply(RunEvent(seq: 5, type: "assistant", data: ["text": .string("five")])))
        XCTAssertTrue(state.apply(RunEvent(seq: 3, type: "assistant", data: ["text": .string("three")])))
        XCTAssertFalse(state.apply(RunEvent(seq: 5, type: "assistant", data: ["text": .string("five")])))
        XCTAssertEqual(state.events.map(\.seq), [3, 5])
        XCTAssertEqual(state.firstSeq, 3)
        XCTAssertEqual(state.lastSeq, 5)
    }

    func testHidesNoiseAndLabelsInterruptedTurns() {
        let events = [
            RunEvent(seq: 1, type: "status", data: ["kind": .string("turn_started")]),
            RunEvent(seq: 2, type: "status", data: ["kind": .string("title"), "text": .string("x")]),
            RunEvent(seq: 3, type: "status", data: ["kind": .string("interrupted"), "text": .string("Interrupted")]),
            RunEvent(seq: 4, type: "result", data: ["isError": .bool(true), "subtype": .string("error_during_execution")]),
        ]
        let items = Transcript.build(events: events)
        XCTAssertEqual(items.map(\.kind), [.status, .result])
        XCTAssertEqual(items.last?.subtype, "interrupted")
    }

    func testAgentCallFromAClippedDetail() {
        let call = Transcript.subagentCall(detail: #"{"description": "Survey", "subagent_type": "Explore", "run_in_background": true, "prompt": "Look at ev"#, input: nil)
        XCTAssertEqual(call, SubagentCall(type: "Explore", description: "Survey", background: true, agentId: nil))
    }
}
