import Foundation

// Fleet chat's rows, ported from web/src/fleet-chat/model.ts (`threadItems` and its
// helpers): bubbles, prose, "Ran N commands" groups, edits with their diff, thinking,
// "Started N agents", questions, refused permissions and the live permission prompt.
// A subagent's own steps are left to the Background tasks sheet.

/// One call in a "Ran 2 commands, read 1 file" row.
public struct ToolCall: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case bash, read, search, fetch, other }

    public var kind: Kind
    public var id: String
    /// The tool's name (for `other`).
    public var name: String
    /// The command, path, pattern, url, or (for `other`) the call's summary.
    public var target: String
    public var output: String?
    /// Lines read (read) or results found (search).
    public var count: Int?
    public var failed = false
    public var pending = true

    public init(kind: Kind, id: String, name: String, target: String, output: String? = nil, count: Int? = nil, failed: Bool = false, pending: Bool = true) {
        self.kind = kind
        self.id = id
        self.name = name
        self.target = target
        self.output = output
        self.count = count
        self.failed = failed
        self.pending = pending
    }
}

public struct QuestionOption: Hashable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// A subagent a turn started, from its Agent/Task call.
public struct SpawnedAgent: Hashable, Sendable, Identifiable {
    public var toolUseId: String
    /// From the call's result ("agentId: ..."), matched against the session's agents.
    public var agentId: String?
    public var name: String
    public var type: String?
    public var background: Bool
    public var pending: Bool
    public var id: String { toolUseId }
}

/// One row of the chat, as the web's Fleet chat draws it.
public struct ThreadItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case user, assistant, thinking, tools, edit, question, permission, permissionRequest, spawn, note
    }

    public enum Tone: String, Hashable, Sendable { case muted, bad, attn }

    public var id: String
    public var kind: Kind
    /// A message, a thought, a note, or the question asked.
    public var text = ""
    /// A user message typed here and not in the run yet: "sending" or "queued".
    public var local: String?
    public var streaming = false
    /// How long a thought took, when known.
    public var seconds: Int?
    public var calls: [ToolCall] = []
    // edit
    public var path = ""
    /// nil when the stored input was cut short (the diff shown is partial).
    public var added: Int?
    public var removed: Int?
    public var diff: [String] = []
    public var created = false
    public var failed = false
    public var pending = false
    // question
    public var options: [QuestionOption] = []
    public var answer: String?
    /// The chat waits on this question now, so an answer is a reply.
    public var open = false
    // permission, permission request
    public var tool = ""
    public var command = ""
    public var reason = ""
    public var requestId = ""
    public var title: String?
    // spawn
    public var agents: [SpawnedAgent] = []
    // note
    public var tone: Tone = .muted

    public init(id: String, kind: Kind, text: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum ChatThread {
    // ---- tool kinds

    static let commandTools: Set<String> = ["bash", "shell", "exec", "exec_command", "command", "local_shell", "run_command", "powershell"]
    static let readTools: Set<String> = ["read", "notebookread", "view", "read_file"]
    static let searchTools: Set<String> = ["grep", "glob", "ls", "search", "find", "toolsearch"]
    static let fetchTools: Set<String> = ["webfetch", "fetch", "websearch"]
    static let editTools: Set<String> = ["edit", "multiedit", "write", "notebookedit", "str_replace_editor", "apply_patch", "write_file", "edit_file"]
    static let agentTools: Set<String> = ["task", "agent"]

    public static func isEdit(_ name: String) -> Bool { editTools.contains(name.lowercased()) }
    public static func isAgent(_ name: String) -> Bool { agentTools.contains(name.lowercased()) }
    public static func isAsk(_ name: String) -> Bool { name.lowercased() == "askuserquestion" }

    // ---- reading a call's input

    /// A tool call's input from its stored JSON (the server cuts it at 2000 characters, so it may not parse).
    public static func inputOf(_ detail: String?) -> [String: JSONValue]? {
        guard let detail, !detail.isEmpty, let data = detail.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.object
    }

    /// One string field from JSON that may be cut short: its text, and whether it was whole.
    public static func fieldOf(_ detail: String?, _ key: String) -> (text: String, whole: Bool)? {
        guard let detail, !detail.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: "\"\(escaped)\"\\s*:\\s*\""),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              let range = Range(match.range, in: detail) else { return nil }
        let chars = Array(detail[range.upperBound...])
        var raw = ""
        var at = 0
        while at < chars.count {
            let char = chars[at]
            if char == "\\" {
                raw.append(char)
                if at + 1 < chars.count { raw.append(chars[at + 1]) }
                at += 2
                continue
            }
            if char == "\"" { return (unescape(raw) ?? raw, true) }
            raw.append(char)
            at += 1
        }
        // Cut short: an odd run of trailing backslashes is half an escape.
        var trimmed = raw
        var slashes = 0
        while trimmed.hasSuffix("\\") { trimmed.removeLast(); slashes += 1 }
        trimmed += String(repeating: "\\", count: slashes - slashes % 2)
        return (unescape(trimmed) ?? raw, false)
    }

    static func unescape(_ raw: String) -> String? {
        guard let data = "\"\(raw)\"".data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    static func str(_ value: JSONValue?) -> String { value?.string ?? "" }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values { if let value, !value.isEmpty { return value } }
        return nil
    }

    /// Lines of a text, a final newline dropped; "" has none.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        return body.components(separatedBy: "\n")
    }

    // ---- edits

    public struct Edit: Hashable, Sendable {
        public var path: String
        public var created: Bool
        public var diff: [String]
        public var added: Int?
        public var removed: Int?
    }

    /// The diff of one edit: lines removed and added, the lines both share at the ends left out.
    public static func diffOf(_ before: String, _ after: String) -> (diff: [String], added: Int, removed: Int) {
        let a = lines(before)
        let b = lines(after)
        var head = 0
        while head < a.count && head < b.count && a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head && tail < b.count - head && a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let removed = Array(a[head..<(a.count - tail)])
        let added = Array(b[head..<(b.count - tail)])
        var diff: [String] = []
        if head > 0 { diff.append(" " + a[head - 1]) }
        diff += removed.map { "-" + $0 }
        diff += added.map { "+" + $0 }
        if tail > 0 { diff.append(" " + a[a.count - tail]) }
        return (diff, added.count, removed.count)
    }

    /// What an Edit, MultiEdit or Write call changed.
    public static func editOf(name: String, detail: String?, summary: String?, input given: [String: JSONValue]? = nil) -> Edit {
        let input = given ?? inputOf(detail)
        let path = firstNonEmpty(str(input?["file_path"]), str(input?["path"]), str(input?["notebook_path"]), fieldOf(detail, "file_path")?.text, summary) ?? "a file"
        let created = ["write", "write_file"].contains(name.lowercased())
        if let input {
            if let edits = input["edits"]?.array {
                var diff: [String] = []
                var added = 0
                var removed = 0
                for (index, edit) in edits.enumerated() {
                    let part = diffOf(str(edit["old_string"]), str(edit["new_string"]))
                    if index > 0 { diff.append("@@") }
                    diff += part.diff
                    added += part.added
                    removed += part.removed
                }
                return Edit(path: path, created: created, diff: diff, added: added, removed: removed)
            }
            if created {
                let body = lines(str(input["content"]))
                return Edit(path: path, created: true, diff: body.map { "+" + $0 }, added: body.count, removed: 0)
            }
            let part = diffOf(str(input["old_string"]), str(input["new_string"]))
            return Edit(path: path, created: created, diff: part.diff, added: part.added, removed: part.removed)
        }
        // Cut short: show what there is, without counts.
        let before = fieldOf(detail, "old_string")
        let after = fieldOf(detail, "new_string") ?? fieldOf(detail, "content")
        let diff = lines(before?.text ?? "").map { "-" + $0 } + lines(after?.text ?? "").map { "+" + $0 } + ["…"]
        return Edit(path: path, created: created, diff: diff, added: nil, removed: nil)
    }

    // ---- tool calls

    /// The call a tool_use stands for in a "Ran N commands" row.
    public static func callOf(id: String, name: String, detail: String?, summary: String?, input given: [String: JSONValue]? = nil) -> ToolCall {
        let input = given ?? inputOf(detail)
        let lower = name.lowercased()
        let summary = summary ?? ""
        if commandTools.contains(lower) {
            let command = firstNonEmpty(str(input?["command"]), str(input?["cmd"]), fieldOf(detail, "command")?.text) ?? summary
            return ToolCall(kind: .bash, id: id, name: name, target: command)
        }
        if readTools.contains(lower) {
            return ToolCall(kind: .read, id: id, name: name, target: firstNonEmpty(str(input?["file_path"]), str(input?["path"])) ?? summary)
        }
        if searchTools.contains(lower) {
            return ToolCall(kind: .search, id: id, name: name, target: firstNonEmpty(str(input?["pattern"]), str(input?["query"])) ?? summary)
        }
        if fetchTools.contains(lower) {
            return ToolCall(kind: .fetch, id: id, name: name, target: firstNonEmpty(str(input?["url"]), str(input?["query"])) ?? summary)
        }
        return ToolCall(kind: .other, id: id, name: name, target: summary)
    }

    /// A call with its result.
    public static func withResult(_ call: ToolCall, text: String, isError: Bool) -> ToolCall {
        var call = call
        let count = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        call.failed = isError
        call.pending = false
        switch call.kind {
        case .bash, .other:
            call.output = text.isEmpty ? nil : text
        case .read:
            call.count = isError ? nil : count
        case .search:
            let lower = text.lowercased()
            call.count = isError ? nil : (lower.hasPrefix("no files") || lower.hasPrefix("no matches")) ? 0 : count
        case .fetch:
            break
        }
        return call
    }

    /// "Ran 2 commands (1 failed), read 1 file": what a run of tool calls did.
    public static func summarize(_ calls: [ToolCall]) -> String {
        func count(_ kind: ToolCall.Kind) -> Int { calls.filter { $0.kind == kind }.count }
        let failed = calls.filter { $0.kind == .bash && $0.failed }.count
        var parts: [String] = []
        if count(.bash) > 0 { parts.append("ran \(plural(count(.bash), "command"))" + (failed > 0 ? " (\(failed) failed)" : "")) }
        if count(.read) > 0 { parts.append("read \(plural(count(.read), "file"))") }
        if count(.search) > 0 { parts.append("searched \(plural(count(.search), "time"))") }
        if count(.fetch) > 0 { parts.append("fetched \(plural(count(.fetch), "page"))") }
        var names: [String] = []
        var uses: [String: Int] = [:]
        for call in calls where call.kind == .other {
            if uses[call.name] == nil { names.append(call.name) }
            uses[call.name, default: 0] += 1
        }
        for name in names {
            let n = uses[name] ?? 1
            parts.append(name.lowercased() == "todowrite" ? "updated the todo list" : "used \(name)" + (n > 1 ? " \(n) times" : ""))
        }
        let text = parts.joined(separator: ", ")
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The first question of an AskUserQuestion call.
    public static func questionOf(detail: String?, summary: String?, input given: [String: JSONValue]? = nil) -> (question: String, options: [QuestionOption]) {
        let input = given ?? inputOf(detail)
        let first = input?["questions"]?.array?.first?.object ?? input
        let question = firstNonEmpty(str(first?["question"]), fieldOf(detail, "question")?.text, summary) ?? "A question"
        let options: [QuestionOption] = (first?["options"]?.array ?? []).map { option in
            if let label = option.string { return QuestionOption(label: label) }
            let description = str(option["description"])
            return QuestionOption(label: firstNonEmpty(str(option["label"])) ?? "Option", description: description.isEmpty ? nil : description)
        }
        return (question, options)
    }

    static let answerPattern = try! NSRegularExpression(pattern: #""([^"]+)"\s*=\s*"([^"]*)""#)

    /// Claude Code records a question's answer as the tool's result: `"question"="answer"`.
    public static func answerIn(_ text: String, isError: Bool) -> String? {
        if let match = answerPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 2), in: text) {
            return String(text[range])
        }
        if isError { return nil }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return trimmed.isEmpty ? nil : trimmed
    }

    // ---- the rows

    /// A main-thread event as the web's ChatItem has it.
    struct Step {
        var key: String
        var kind: String
        var at: Double
        var text = ""
        var name: String?
        var id = ""
        var toolUseId = ""
        var summary: String?
        var detail: String?
        var input: [String: JSONValue]?
        var isError = false
        var subtype: String?
        var denied: [String] = []
        var errors: [String] = []
        var code: Int?
    }

    static func step(_ event: RunEvent) -> Step? {
        let d = event.data
        func s(_ key: String) -> String { d.string(key) ?? "" }
        var step = Step(key: "seq:\(event.seq)", kind: event.type, at: event.at)
        switch event.type {
        case "init":
            break
        case "user":
            guard !s("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            step.text = s("text")
            step.name = s("source").isEmpty ? nil : s("source")
        case "assistant":
            guard !s("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            step.text = s("text")
        case "thinking":
            step.text = Transcript.clip(s("text"), Transcript.resultMax)
        case "tool_use":
            step.id = s("id")
            step.name = s("name").isEmpty ? "tool" : s("name")
            step.summary = s("summary")
            step.detail = s("detail").isEmpty ? (d["input"].flatMap(Transcript.pretty) ?? "") : s("detail")
            step.input = d["input"]?.object ?? inputOf(step.detail)
        case "tool_result":
            step.toolUseId = s("toolUseId")
            step.isError = d.bool("isError") == true
            let body = s("text").isEmpty ? (d["content"].flatMap(Transcript.pretty) ?? "") : s("text")
            step.text = Transcript.clip(body, Transcript.resultMax)
        case "result":
            step.isError = d.bool("isError") == true
            step.subtype = d.bool("interrupted") == true ? "interrupted" : (s("subtype").isEmpty ? nil : s("subtype"))
            step.text = s("text")
            step.denied = (d["denied"]?.array ?? []).map { entry in
                entry.string ?? firstNonEmpty(str(entry["tool_name"]), str(entry["name"])) ?? "tool"
            }
            step.errors = (d["errors"]?.array ?? []).map { $0.string ?? Transcript.pretty($0) ?? "" }
        case "exit":
            step.code = d["code"]?.int ?? d["exitCode"]?.int
            step.text = firstNonEmpty(s("error"), s("message")) ?? ""
        case "status", "error", "usage":
            guard let item = Transcript.item(of: event) else { return nil }
            step.kind = item.kind == .error ? "error" : event.type
            step.text = item.text
            step.name = item.name
            step.isError = item.isError
        default:
            return nil
        }
        return step
    }

    /// The main thread's steps, with the web's echo and interrupt rules.
    static func steps(_ events: [RunEvent]) -> [Step] {
        var out: [Step] = []
        for event in events where event.agent == nil {
            guard var step = step(event) else { continue }
            if step.kind == "user", let name = step.name,
               let last = out.last(where: { $0.kind == "user" }), let lastName = last.name, lastName != name,
               last.text.trimmingCharacters(in: .whitespacesAndNewlines) == step.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                continue // the same message noted by fleet and echoed by the harness: keep the first
            }
            if step.kind == "result", step.isError {
                for known in out.reversed() {
                    if known.kind == "result" { break }
                    if known.kind == "status", let name = known.name, name == "interrupt" || name == "interrupted" {
                        step.subtype = "interrupted"
                        break
                    }
                }
            }
            out.append(step)
        }
        return out
    }

    /// Calls the human denied with the chat's Deny button during the turn that ends at `at`.
    static func deniedInChat(_ steps: [Step], _ at: Int) -> Int {
        var count = 0
        var index = at - 1
        while index >= 0 {
            let step = steps[index]
            if step.kind == "user" || step.kind == "result" { break }
            if step.kind == "status", step.name == "permission_answered", step.text.hasPrefix("Denied ") { count += 1 }
            index -= 1
        }
        return count
    }

    /// A run's events as the chat's rows (web `threadItems`).
    public static func items(events: [RunEvent], partials: [Partial] = [], pendingPermission: PendingPermission? = nil) -> [ThreadItem] {
        var out: [ThreadItem] = []
        var callAt: [String: (row: Int, index: Int)] = [:]
        var editAt: [String: Int] = [:]
        var spawnAt: [String: (row: Int, index: Int)] = [:]
        var questionAt: [String: Int] = [:]
        var group: Int? // the open "tools" row
        var spawn: Int? // the open "spawn" row
        func close() {
            group = nil
            spawn = nil
        }
        let main = steps(events)
        for (at, step) in main.enumerated() {
            switch step.kind {
            case "tool_use":
                let name = step.name ?? "tool"
                let id = step.id.isEmpty ? step.key : step.id
                if isEdit(name) {
                    close()
                    let edit = editOf(name: name, detail: step.detail, summary: step.summary, input: step.input)
                    var row = ThreadItem(id: step.key, kind: .edit)
                    row.path = edit.path
                    row.created = edit.created
                    row.diff = edit.diff
                    row.added = edit.added
                    row.removed = edit.removed
                    row.pending = true
                    editAt[id] = out.count
                    out.append(row)
                } else if isAgent(name) {
                    group = nil
                    let input = step.input
                    let agent = SpawnedAgent(
                        toolUseId: id,
                        agentId: nil,
                        name: firstNonEmpty(str(input?["description"]), fieldOf(step.detail, "description")?.text, step.summary) ?? "Agent",
                        type: firstNonEmpty(str(input?["subagent_type"])),
                        background: input?["run_in_background"]?.bool == true,
                        pending: true
                    )
                    if spawn == nil {
                        spawn = out.count
                        out.append(ThreadItem(id: step.key, kind: .spawn))
                    }
                    let row = spawn!
                    spawnAt[id] = (row, out[row].agents.count)
                    out[row].agents.append(agent)
                } else if isAsk(name) {
                    close()
                    let asked = questionOf(detail: step.detail, summary: step.summary, input: step.input)
                    var row = ThreadItem(id: step.key, kind: .question, text: asked.question)
                    row.options = asked.options
                    questionAt[id] = out.count
                    out.append(row)
                } else {
                    spawn = nil
                    if group == nil {
                        group = out.count
                        out.append(ThreadItem(id: step.key, kind: .tools))
                    }
                    let row = group!
                    callAt[id] = (row, out[row].calls.count)
                    out[row].calls.append(callOf(id: id, name: name, detail: step.detail, summary: step.summary, input: step.input))
                }
            case "tool_result":
                let id = step.toolUseId
                if let call = callAt[id] {
                    out[call.row].calls[call.index] = withResult(out[call.row].calls[call.index], text: step.text, isError: step.isError)
                } else if let row = editAt[id] {
                    out[row].failed = step.isError
                    out[row].pending = false
                } else if let spawned = spawnAt[id] {
                    var agent = out[spawned.row].agents[spawned.index]
                    agent.agentId = Transcript.agentId(in: step.text) ?? agent.agentId
                    agent.pending = false
                    out[spawned.row].agents[spawned.index] = agent
                } else if let row = questionAt[id] {
                    out[row].answer = answerIn(step.text, isError: step.isError)
                }
            case "user":
                close()
                // A reply after an unanswered question answers it.
                if let last = out.indices.last, out[last].kind == .question, out[last].answer == nil, questionAt.values.contains(last) {
                    out[last].answer = step.text
                }
                out.append(ThreadItem(id: step.key, kind: .user, text: step.text))
            case "assistant":
                close()
                out.append(ThreadItem(id: step.key, kind: .assistant, text: step.text))
            case "thinking":
                close()
                var row = ThreadItem(id: step.key, kind: .thinking, text: step.text)
                if at > 0 && at + 1 < main.count {
                    let ms = main[at + 1].at - main[at - 1].at
                    if ms >= 1000 && ms < 3_600_000 { row.seconds = Int((ms / 1000).rounded()) }
                }
                out.append(row)
            case "result":
                if step.subtype == "interrupted" {
                    close()
                    out.append(note(step.key, "Interrupted", .muted))
                } else if step.denied.count > deniedInChat(main, at) {
                    close()
                    let use = main[..<at].last { $0.kind == "tool_use" && step.denied.contains($0.name ?? "") }
                    var row = ThreadItem(id: step.key, kind: .permission)
                    row.tool = step.denied.joined(separator: ", ")
                    row.command = use.map { firstNonEmpty(str($0.input?["command"])) ?? $0.summary ?? "" } ?? ""
                    row.reason = "Nobody could approve it in this run, so it was refused."
                    out.append(row)
                } else if step.isError {
                    close()
                    let text = firstNonEmpty(step.errors.first, step.text) ?? "The turn ended with an error" + (step.subtype.map { " (\($0))" } ?? "")
                    out.append(note(step.key, text, .bad))
                }
            case "status":
                close()
                out.append(note(step.key, step.text, .muted))
            case "error":
                close()
                out.append(note(step.key, step.text.isEmpty ? "Error" : step.text, .bad))
            case "usage":
                close()
                out.append(note(step.key, step.text.isEmpty ? "Usage limit" : step.text, step.isError ? .bad : .attn))
            case "exit":
                close()
                let text = "The process exited" + (step.code.map { " (code \($0))" } ?? "") + (step.text.isEmpty ? "" : ": \(step.text)")
                out.append(note(step.key, text, (step.code ?? 0) != 0 ? .bad : .muted))
            default:
                break // init
            }
        }
        // A live permission prompt the run holds now: the card with Allow / Deny buttons.
        // A held AskUserQuestion is its question card, open; the answer goes back on the prompt.
        if let pending = pendingPermission {
            if pending.tool == "AskUserQuestion", let asking = out.lastIndex(where: { $0.kind == .question }) {
                out[asking].open = true
                out[asking].answer = nil
            } else {
                var row = ThreadItem(id: "perm:\(pending.requestId)", kind: .permissionRequest)
                row.requestId = pending.requestId
                row.tool = pending.tool
                row.command = pending.command ?? ""
                row.title = pending.title
                out.append(row)
            }
        }
        for partial in partials where partial.agent == nil {
            switch partial.kind {
            case "thinking", "redacted_thinking":
                var row = ThreadItem(id: "partial:\(partial.key)", kind: .thinking, text: partial.text)
                row.streaming = true
                out.append(row)
            case "text", "assistant":
                var row = ThreadItem(id: "partial:\(partial.key)", kind: .assistant, text: partial.text)
                row.streaming = true
                out.append(row)
            default:
                break
            }
        }
        return out
    }

    static func note(_ key: String, _ text: String, _ tone: ThreadItem.Tone) -> ThreadItem {
        var row = ThreadItem(id: key, kind: .note, text: text)
        row.tone = tone
        return row
    }

    // ---- labels

    public static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }

    /// "now", "5m", "3h", "2d", "1w": the sidebar's age of a time.
    public static func relTime(_ ms: Double) -> String {
        let mins = ms / 60_000
        if mins < 1 { return "now" }
        if mins < 60 { return "\(Int(mins.rounded()))m" }
        if mins < 60 * 24 { return "\(Int((mins / 60).rounded()))h" }
        if mins < 60 * 24 * 7 { return "\(Int((mins / 60 / 24).rounded()))d" }
        return "\(Int((mins / 60 / 24 / 7).rounded()))w"
    }

    /// Claude Code's --effort levels; Codex and Pi runs take no effort from Fleet.
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public static func effortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "XHigh" : effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// Only Claude Code takes a permission mode and an effort from Fleet.
    public static func takesPermissionMode(_ harness: String) -> Bool { harness == "claude" }
    public static func takesEffort(_ harness: String) -> Bool { harness == "claude" }

    public struct PermissionMode: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var hint: String
    }

    /// Claude Code's modes as Fleet chat runs them: a tool that would ask waits for the chat's Allow / Deny buttons.
    public static let permissionModes: [PermissionMode] = [
        PermissionMode(id: "bypassPermissions", label: "Bypass permissions", hint: "Run everything without asking"),
        PermissionMode(id: "acceptEdits", label: "Accept edits", hint: "Edits run; anything else that would ask waits for you here"),
        PermissionMode(id: "auto", label: "Auto", hint: "Claude Code's classifier decides each tool call"),
        PermissionMode(id: "plan", label: "Plan", hint: "Plans only; changes nothing"),
        PermissionMode(id: "dontAsk", label: "Don't ask", hint: "Only pre-approved tools run; the rest are refused"),
        PermissionMode(id: "manual", label: "Manual", hint: "Every tool that needs approval waits for you here"),
    ]

    public static func permissionLabel(_ mode: String?) -> String {
        if let mode, let known = permissionModes.first(where: { $0.id == mode }) { return known.label }
        if let mode, !mode.isEmpty { return mode }
        return "Default permissions"
    }

    /// A model choice in the picker: "Default model" first, then what the harness reports.
    public struct ModelOption: Hashable, Sendable, Identifiable {
        public var model: String?
        public var name: String
        public var via: String?
        public var id: String { model ?? "" }
    }

    public static func modelOptions(harness: String, models: [String], current: String? = nil) -> [ModelOption] {
        var ids = models
        if let current, !current.isEmpty, !ids.contains(current) { ids.insert(current, at: 0) }
        return [ModelOption(model: nil, name: "Default model", via: nil)] + ids.map { model in
            if harness == "pi", let slash = model.firstIndex(of: "/"), slash != model.startIndex {
                return ModelOption(model: model, name: String(model[model.index(after: slash)...]), via: String(model[..<slash]))
            }
            return ModelOption(model: model, name: Format.modelLabel(model), via: nil)
        }
    }

    /// "Using machine: ..." lines for the Provisioned thread row.
    public static func provision(run: Run, machineName: String?) -> [String] {
        var out = ["Using machine: \(machineName ?? run.machineId)", "Using workspace: \(run.cwd ?? "unknown")"]
        if let branch = run.branch, !branch.isEmpty { out.append("Using branch: \(branch)") }
        out.append("Using \(Format.harnessName(run.harness)): \(Format.modelLabel(run.model))" + (run.effort.map { ", \($0) effort" } ?? ""))
        if run.harness == "claude" { out.append("Permission mode: \(permissionLabel(run.permissionMode))") }
        if let session = run.sessionId { out.append("Session: \(session)") }
        out.append("Fleet run: \(run.id)" + (run.isExternal ? " (attached to a session started outside Fleet)" : ""))
        return out
    }

    /// The header's Stop: interrupts the turn; a harness that can't be interrupted is stopped for good.
    public enum StopAction: Hashable, Sendable { case interrupt, stop }

    public static func stopChoice(controls: Controls, caps: HarnessCapabilities?) -> (action: StopAction?, label: String) {
        if controls.interrupt.enabled { return (.interrupt, "Stop the current turn. The thread can go on") }
        if controls.stop.enabled && caps?.interrupt == false { return (.stop, "Stop the run. Its process is killed") }
        return (nil, controls.interrupt.reason)
    }

    /// The sidebar's state for a run.
    public enum Status: String, Hashable, Sendable { case running, waiting, idle, done, unknown }

    public static func status(of run: Run) -> Status {
        if run.isEnded { return .done }
        if run.needsYou { return .waiting }
        if run.status == .running || run.status == .starting || run.turnOpen { return .running }
        if run.status == .unknown { return .unknown }
        return .idle
    }

    /// The sidebar's short run line: "4m 10s · 12.3k tokens · Editing a file".
    public static func compactLine(_ run: Run, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        var out: [String] = []
        if let stats = run.stats { out.append(Format.duration(seconds: Format.elapsedMs(stats, now: now) / 1000)) }
        if let tokens = run.stats?.tokens, tokens > 0 { out.append("\(Format.tokenCount(tokens)) tokens") }
        if run.endedAt == nil, let activity = run.stats?.activity, !activity.isEmpty { out.append(activity) }
        return out.joined(separator: " · ")
    }

    /// A background task's line: "Explore · 1m 4s · 73.5k tokens · 1 tool use · Reading a file".
    public static func agentLine(_ agent: SessionAgent, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        var out: [String] = [agentType(agent)]
        if let start = agent.startedAt {
            let end = agent.isRunning ? now : (agent.lastAt ?? now)
            out.append(Format.duration(seconds: max(0, end - start) / 1000))
        }
        if let model = agent.model, !model.isEmpty { out.append(Format.modelLabel(model)) }
        if let tokens = agent.tokens, tokens > 0 { out.append("\(Format.tokenCount(tokens)) tokens") }
        if let uses = agent.toolUses { out.append(plural(uses, "tool use")) }
        if agent.isRunning { out.append(firstNonEmpty(agent.activityLabel) ?? "Working") }
        return out.joined(separator: " · ")
    }

    public static func agentType(_ agent: SessionAgent) -> String {
        if let type = agent.type, !type.isEmpty, type != "general-purpose" { return type }
        return "Agent"
    }
}

public extension NewRun {
    /// A new Fleet chat thread, as the web's hero composer starts it: permission prompts are
    /// held for the chat's Allow / Deny buttons, and only Claude Code takes a permission mode and effort.
    static func chat(machineId: String, harness: String, prompt: String, cwd: String? = nil, model: String? = nil, permissionMode: String? = nil, effort: String? = nil) -> NewRun {
        let claude = harness == "claude"
        let mode = (permissionMode?.isEmpty == false ? permissionMode : nil) ?? "acceptEdits"
        return NewRun(
            machineId: machineId,
            harness: harness,
            model: model?.isEmpty == false ? model : nil,
            cwd: cwd?.isEmpty == false ? cwd : nil,
            prompt: prompt,
            permissionMode: claude ? mode : nil,
            effort: claude && effort?.isEmpty == false ? effort : nil,
            holdPermissions: true
        )
    }
}
