import XCTest
@testable import FleetKit

final class SSETests: XCTestCase {
    func testSplitsOnLFCRLFAndCRKeepingBlankLines() {
        var splitter = LineSplitter()
        let lines = splitter.push(Array("a\nb\r\nc\rd\n\n\r\n\re".utf8))
        XCTAssertEqual(lines, ["a", "b", "c", "d", "", "", ""])
        XCTAssertEqual(splitter.finish(), "e")
        XCTAssertNil(splitter.finish())
    }

    func testCRLFSplitAcrossChunks() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.push(Array("one\r".utf8)), ["one"])
        XCTAssertEqual(splitter.push(Array("\ntwo\r\n".utf8)), ["two"])
    }

    func testMultibyteCharacterSplitAcrossChunks() {
        var splitter = LineSplitter()
        let bytes = Array("café ✓\n".utf8)
        XCTAssertEqual(splitter.push(bytes[..<4]), [])
        XCTAssertEqual(splitter.push(bytes[4...]), ["café ✓"])
    }

    func testParserFieldsCommentsAndMultilineData() {
        var parser = SSEParser()
        var out: [SSEMessage] = []
        for line in [": open", "", "event: run", "data: {\"a\":1}", "", "data: one", "data:two", "id: 7", "", "event: ping", "", "retry: 10", "data", ""] {
            if let message = parser.push(line: line) { out.append(message) }
        }
        XCTAssertEqual(out, [
            SSEMessage(event: "run", data: "{\"a\":1}"),
            SSEMessage(event: "message", data: "one\ntwo", id: "7"),
            SSEMessage(event: "message", data: "", id: "7"),
        ])
    }

    /// A real capture of GET /api/runs/:id/stream (scripts/dev-fleet.ts's long turn).
    func testDecodesARealLiveStream() throws {
        let messages = try decodeStream(Fixture.data("stream_live", "txt"))
        let runs = messages.compactMap(\.run)
        let events = messages.compactMap(\.event)
        let deltas = messages.compactMap(\.delta)
        XCTAssertFalse(runs.isEmpty)
        XCTAssertFalse(events.isEmpty)
        XCTAssertFalse(deltas.isEmpty)
        XCTAssertEqual(runs.first?.status, .running)
        XCTAssertEqual(runs.first?.turnOpen, true)
        XCTAssertTrue(deltas.allSatisfy { !$0.key.isEmpty && !$0.text.isEmpty })
        XCTAssertEqual(events.map(\.seq), events.map(\.seq).sorted())
    }

    func testDecodesTheReplayOfARunWithASubagent() throws {
        let messages = try decodeStream(Fixture.data("stream_subagent", "txt"))
        guard let run = messages.first?.run else { return XCTFail("the stream starts with the run") }
        XCTAssertEqual(run.title, "Deploy the fleet-sandbox preview")
        let events = messages.compactMap(\.event)
        XCTAssertTrue(events.contains { $0.agent == "toolu_agent_check" })
    }

    private func decodeStream(_ data: Data) throws -> [RunStreamMessage] {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var out: [RunStreamMessage] = []
        for line in splitter.push(data) {
            if let message = parser.push(line: line), let decoded = RunStreamMessage.decode(message) { out.append(decoded) }
        }
        return out
    }
}

private extension RunStreamMessage {
    var run: Run? {
        guard case .run(let value) = self else { return nil }
        return value
    }
    var event: RunEvent? {
        guard case .event(let value) = self else { return nil }
        return value
    }
    var delta: RunDelta? {
        guard case .delta(let value) = self else { return nil }
        return value
    }
}
