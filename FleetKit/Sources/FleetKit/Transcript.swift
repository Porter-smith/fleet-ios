import Foundation

/// One row of the chat, built from a run's events (web/src/lib/chat.ts `itemOf`).
/// A Task/Agent tool call carries its subagent's own items as `children`.
public struct ChatItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case user, assistant, thinking, tool, result, usage, status, error, exit, session, subagent
    }

    public var id: String
    public var seq: Int
    public var at: Double
    public var agent: String?
    public var kind: Kind
    public var text: String = ""
    /// Tool name, status kind, or a user message's source.
    public var name: String?
    public var summary: String?
    public var detail: String?
    public var toolId: String?
    public var output: String?
    public var outputIsError = false
    public var hasOutput = false
    public var isError = false
    public var costUsd: Double?
    public var durationMs: Double?
    public var subtype: String?
    /// Streamed, not finished yet.
    public var isPartial = false
    public var children: [ChatItem] = []
    /// For a Task/Agent call.
    public var subagent: SubagentCall?

    public init(id: String, seq: Int, at: Double = 0, agent: String? = nil, kind: Kind, text: String = "") {
        self.id = id
        self.seq = seq
        self.at = at
        self.agent = agent
        self.kind = kind
        self.text = text
    }
}

/// What an Agent/Task tool call asked for, from its input.
public struct SubagentCall: Hashable, Sendable {
    public var type: String?
    public var description: String?
    public var background: Bool
    /// The agent id its result names ("agentId: ..."), for a background one.
    public var agentId: String?
}

/// A block still being typed out from `delta`s.
public struct Partial: Hashable, Sendable {
    public var key: String
    public var kind: String
    public var agent: String?
    public var text: String
}

/// A run's chat: the events seen so far plus partial blocks, kept in seq order
/// with the web app's rules for when a partial is replaced by its finished event.
public struct ChatState: Sendable {
    public private(set) var events: [RunEvent] = []
    public private(set) var partials: [Partial] = []
    private var seen = Set<Int>()

    public init() {}

    public var firstSeq: Int? { events.first?.seq }
    public var lastSeq: Int { events.last?.seq ?? 0 }
    public var isEmpty: Bool { events.isEmpty && partials.isEmpty }

    /// Adds an event; false when it was already there.
    @discardableResult
    public mutating func apply(_ event: RunEvent) -> Bool {
        guard seen.insert(event.seq).inserted else { return false }
        if let last = events.last, last.seq > event.seq {
            let at = events.firstIndex { $0.seq > event.seq } ?? events.endIndex
            events.insert(event, at: at)
        } else {
            events.append(event)
        }
        dropPartials(for: event)
        return true
    }

    public mutating func apply(_ list: [RunEvent]) {
        for event in list { apply(event) }
    }

    public mutating func apply(_ delta: RunDelta) {
        guard !delta.text.isEmpty else { return }
        if let at = partials.firstIndex(where: { $0.key == delta.key }) {
            partials[at].text += delta.text
        } else {
            partials.append(Partial(key: delta.key, kind: delta.kind.isEmpty ? "text" : delta.kind, agent: delta.agent, text: delta.text))
        }
    }

    public mutating func clearPartials() { partials = [] }

    private static func block(of kind: String) -> String {
        switch kind {
        case "assistant", "text": "text"
        case "thinking", "redacted_thinking": "thinking"
        default: kind
        }
    }

    private mutating func dropPartials(for event: RunEvent) {
        if ["assistant", "thinking", "tool_use"].contains(event.type) {
            let block = Self.block(of: event.type)
            let key = event.data.string("key")
            var gone = key.flatMap { key in partials.firstIndex { $0.key == key } }
            if gone == nil { gone = partials.firstIndex { Self.block(of: $0.kind) == block && $0.agent == event.agent } }
            if let gone { partials.remove(at: gone) }
        }
        if event.type == "exit" || (event.type == "result" && event.agent == nil) {
            partials = []
        } else if event.type == "result" {
            partials.removeAll { $0.agent == event.agent }
        }
    }

    /// The chat as rows, subagent work nested under the tool call that started it.
    public func items() -> [ChatItem] { Transcript.build(events: events, partials: partials) }
}

public enum Transcript {
    static let resultMax = 4000
    static let agentTool = try! NSRegularExpression(pattern: "^(task|agent)$", options: [.caseInsensitive])
    static let agentIdIn = try! NSRegularExpression(pattern: #"agentId:\s*([\w-]{4,80})"#)

    static func isAgentTool(_ name: String) -> Bool {
        agentTool.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func agentId(in text: String) -> String? {
        guard let match = agentIdIn.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func clip(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "… (\(text.count - max) more characters)"
    }

    /// What one stored event draws as, or nil for what it doesn't draw.
    public static func item(of event: RunEvent) -> ChatItem? {
        let d = event.data
        func str(_ key: String) -> String { d.string(key) ?? "" }
        var item = ChatItem(id: "seq:\(event.seq)", seq: event.seq, at: event.at, agent: event.agent, kind: .status)
        switch event.type {
        case "init":
            var parts: [String] = []
            if !str("model").isEmpty { parts.append("model \(str("model"))") }
            if !str("cwd").isEmpty { parts.append("in \(str("cwd"))") }
            if !str("sessionId").isEmpty { parts.append("session \(str("sessionId").prefix(8))") }
            item.kind = .session
            item.text = "Session started" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
        case "user":
            guard !str("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            item.kind = .user
            item.text = str("text")
            item.name = d.string("source")
        case "assistant":
            guard !str("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            item.kind = .assistant
            item.text = str("text")
        case "thinking":
            item.kind = .thinking
            item.text = clip(str("text"), resultMax)
        case "tool_use":
            item.kind = .tool
            item.name = str("name").isEmpty ? "tool" : str("name")
            item.toolId = str("id")
            item.summary = str("summary")
            item.detail = str("detail").isEmpty ? (d["input"].flatMap(pretty) ?? "") : str("detail")
            if isAgentTool(item.name ?? "") { item.subagent = subagentCall(detail: item.detail ?? "", input: d["input"]) }
        case "tool_result":
            // Paired with its tool call by `build`; drawn alone only when the call isn't loaded.
            item.kind = .tool
            item.name = "Result"
            item.toolId = nil
            item.summary = str("toolUseId")
            let body = str("text").isEmpty ? (d["content"].flatMap(pretty) ?? "") : str("text")
            item.output = clip(body, resultMax)
            item.outputIsError = d.bool("isError") == true
            item.hasOutput = true
        case "result":
            item.kind = .result
            item.isError = d.bool("isError") == true
            item.costUsd = d.number("costUsd")
            item.durationMs = d.number("durationMs")
            item.subtype = d.bool("interrupted") == true ? "interrupted" : d.string("subtype")
            item.text = str("text")
        case "usage":
            let status = str("status")
            if status == "allowed" { return nil }
            let window = str("window").isEmpty ? str("reachedType") : str("window")
            var message = str("message").isEmpty ? str("text") : str("message")
            if message.isEmpty {
                if status == "allowed_warning" { message = "Nearing the \(window.isEmpty ? "usage" : window) limit" }
                else if status == "rejected" { message = window.isEmpty ? "A usage limit was reached" : "The \(window) limit was reached" }
                else { message = "Usage signal" }
            }
            item.kind = .usage
            item.text = message
            item.isError = status != "allowed_warning"
        case "status":
            let kind = str("kind")
            if kind == "title" || kind == "turn_started" { return nil }
            if kind == "control" {
                guard d.bool("ok") == false else { return nil }
                item.kind = .error
                item.text = "A control request failed: \(str("error").isEmpty ? "no reason given" : str("error"))"
                return item
            }
            let text = str("text").isEmpty ? str("message") : str("text")
            guard !text.isEmpty else { return nil }
            item.kind = .status
            item.text = text
            item.name = kind.isEmpty ? nil : kind
        case "error":
            item.kind = .error
            item.text = [str("message"), str("text"), str("error")].first { !$0.isEmpty } ?? "Error"
        case "exit":
            item.kind = .exit
            let code = d["code"]?.int ?? d["exitCode"]?.int
            let reason = str("error").isEmpty ? str("message") : str("error")
            item.text = "Exited" + (code.map { " with code \($0)" } ?? "") + (reason.isEmpty ? "" : ": \(reason)")
            item.isError = (code ?? 0) != 0 || !reason.isEmpty
        default:
            return nil
        }
        return item
    }

    static func pretty(_ value: JSONValue) -> String? {
        if let string = value.string { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func subagentCall(detail: String, input: JSONValue?) -> SubagentCall {
        var fields = input?.object
        if fields == nil, let data = detail.data(using: .utf8) {
            fields = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object
        }
        if let fields {
            return SubagentCall(type: fields.string("subagent_type"), description: fields.string("description"), background: fields.bool("run_in_background") == true)
        }
        // The detail is clipped, so it may not parse: read the fields by pattern.
        func field(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""),
                  let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
                  let range = Range(match.range(at: 1), in: detail) else { return nil }
            return String(detail[range])
        }
        let background = detail.range(of: #""run_in_background"\s*:\s*true"#, options: .regularExpression) != nil
        return SubagentCall(type: field("subagent_type"), description: field("description"), background: background)
    }

    /// Rows for a run: tool results folded into their calls, each subagent's
    /// events nested under the Task/Agent call whose id they carry as `agent`,
    /// and partials at the end of their own thread.
    public static func build(events: [RunEvent], partials: [Partial] = []) -> [ChatItem] {
        var threads: [String: [ChatItem]] = [:] // "" is the main thread
        var order: [String] = []
        var toolAt: [String: (thread: String, index: Int)] = [:]

        func append(_ item: ChatItem, to thread: String) {
            if threads[thread] == nil { threads[thread] = []; order.append(thread) }
            threads[thread]!.append(item)
        }

        for event in events {
            guard var row = item(of: event) else { continue }
            let thread = event.agent ?? ""
            if event.type == "tool_result", let toolUseId = event.data.string("toolUseId"), let at = toolAt[toolUseId] {
                var call = threads[at.thread]![at.index]
                call.output = row.output
                call.outputIsError = row.outputIsError
                call.hasOutput = true
                if call.subagent != nil, let output = row.output { call.subagent?.agentId = agentId(in: output) }
                threads[at.thread]![at.index] = call
                continue
            }
            if row.kind == .user, row.name != nil, let last = threads[thread]?.last(where: { $0.kind == .user }),
               let lastName = last.name, lastName != row.name,
               last.text.trimmingCharacters(in: .whitespacesAndNewlines) == row.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                continue // the same message noted by fleet and echoed by the harness: keep the first
            }
            if row.kind == .result, row.isError, event.agent == nil, interruptedTurn(threads[thread] ?? []) {
                row.subtype = "interrupted"
            }
            append(row, to: thread)
            if row.kind == .tool, let id = row.toolId, !id.isEmpty {
                toolAt[id] = (thread, threads[thread]!.count - 1)
            }
        }

        for partial in partials {
            let thread = partial.agent ?? ""
            let seq = (threads[thread]?.last?.seq ?? events.last?.seq ?? 0)
            var item = ChatItem(id: "partial:\(partial.key)", seq: seq, agent: partial.agent, kind: .assistant, text: partial.text)
            switch partial.kind {
            case "thinking", "redacted_thinking": item.kind = .thinking
            case "tool_use": item.kind = .tool; item.name = "tool"; item.summary = partial.text
            default: break
            }
            item.isPartial = true
            append(item, to: thread)
        }

        var used = Set<String>([""])
        func assemble(_ thread: String, depth: Int) -> [ChatItem] {
            var list = threads[thread] ?? []
            guard depth < 8 else { return list }
            for index in list.indices where list[index].kind == .tool {
                guard let id = list[index].toolId, threads[id] != nil, !used.contains(id) else { continue }
                used.insert(id)
                list[index].children = assemble(id, depth: depth + 1)
            }
            return list
        }
        var root = assemble("", depth: 0)

        // A subagent whose call isn't loaded (older than the page, or a background
        // agent's later work): its own group, where its first event falls.
        for thread in order where !used.contains(thread) {
            used.insert(thread)
            let children = assemble(thread, depth: 1)
            guard let first = children.first else { continue }
            var group = ChatItem(id: "agent:\(thread)", seq: first.seq, at: first.at, agent: nil, kind: .subagent, text: "Subagent")
            group.toolId = thread
            group.children = children
            let at = root.firstIndex { $0.seq > first.seq && !$0.isPartial } ?? root.endIndex
            root.insert(group, at: at)
        }
        return root
    }

    /// Claude ends an interrupted turn with an error result: after an interrupt note in the same turn, call it that.
    static func interruptedTurn(_ items: [ChatItem]) -> Bool {
        for item in items.reversed() {
            if item.kind == .result { return false }
            if item.kind == .status, let name = item.name, name == "interrupt" || name == "interrupted" { return true }
        }
        return false
    }
}
