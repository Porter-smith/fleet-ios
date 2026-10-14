import SwiftUI
import FleetKit

/// A chat's transcript in the web chat's look (web/src/fleet-chat/transcript.tsx): your
/// messages as bubbles, the agent's text as prose, tool calls folded into "Ran N commands"
/// rows that open to each command and its output, edits with their diff, thinking rows,
/// "Started N agents", and the cards for what the chat waits on.
struct ThreadView: View {
    let items: [ThreadItem]
    var locals: [RunChatModel.Local] = []
    /// Where the chat runs, for the "Provisioned thread" row after the first message.
    var provision: [String] = []
    var working = false
    var harness = "claude"
    var agentInfo: (SpawnedAgent) -> SessionAgent? = { _ in nil }
    var onOpenAgent: ((SpawnedAgent) -> Void)?
    /// Answers an open question; nil when the chat can't take one now.
    var onAnswer: ((String) -> Void)?
    /// Whether an unanswered question at the end of the thread still takes an answer.
    var questionOpen = false
    /// Answers the held permission prompt; nil when the run can't take a decision.
    var onPermission: ((PermissionDecision) -> Void)?
    var sentDecision: PermissionDecision?

    private var firstUser: String? { items.first { $0.kind == .user }?.id }
    private var streaming: Bool { items.last?.streaming == true && items.last?.kind == .assistant }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                row(item)
            }
            ForEach(locals) { local in
                UserBubble(text: local.text, local: local.state)
            }
            if working && !streaming {
                ShineText(text: "Working...", font: .system(size: 14))
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("working")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ item: ThreadItem) -> some View {
        switch item.kind {
        case .user:
            VStack(alignment: .leading, spacing: 16) {
                UserBubble(text: item.text, local: item.local)
                if item.id == firstUser && !provision.isEmpty {
                    ProvisionedRow(lines: provision)
                }
            }
        case .assistant:
            MarkdownView(text: item.text)
                .accessibilityIdentifier("row.assistant")
        case .thinking:
            ThinkingRow(item: item)
        case .tools:
            ToolsRow(calls: item.calls)
        case .edit:
            EditRow(item: item)
        case .question:
            let live = item.open || (item.answer == nil && questionOpen && item.id == items.last?.id)
            QuestionCard(item: item, live: live, onAnswer: onAnswer)
        case .permission:
            RefusedCard(item: item)
        case .permissionRequest:
            PermissionCard(item: item, harness: harness, sent: sentDecision, onPermission: onPermission)
        case .spawn:
            SpawnRow(agents: item.agents, info: agentInfo, onOpen: onOpenAgent)
        case .note:
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(item.tone == .bad ? Theme.bad : item.tone == .attn ? Theme.attn : Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// ---- rows

/// Your message: a bubble on the right, with "Sending…" or "Queued until the turn ends" under it.
struct UserBubble: View {
    let text: String
    var local: String?

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                InlineText(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.seam, lineWidth: 1))
                    .textSelection(.enabled)
                if let local {
                    Text(local == "queued" ? "Queued until the turn ends" : "Sending…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.attn)
                        .accessibilityIdentifier("composer.queued")
                }
            }
        }
        .accessibilityIdentifier("row.user")
    }
}

/// A collapsible transcript row ("Ran 2 commands", "Edited x.ts", "Thought for 6s").
struct FoldRow<Head: View, Content: View>: View {
    let icon: String
    let head: Head
    let content: Content
    @State private var open: Bool

    init(icon: String, defaultOpen: Bool = false, @ViewBuilder head: () -> Head, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.head = head()
        self.content = content()
        _open = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 15)
                    head
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The box under an opened row: command output, diff.
private struct CodeBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.seam, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ToolsRow: View {
    let calls: [ToolCall]

    private var icon: String {
        switch calls.first?.kind {
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        default: "terminal"
        }
    }

    var body: some View {
        FoldRow(icon: icon) {
            Text(ChatThread.summarize(calls)).truncationMode(.tail)
            if calls.contains(where: \.pending) { Spinner(size: 10) }
        } content: {
            CodeBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(calls.enumerated()), id: \.element.id) { at, call in
                        if at > 0 { Rectangle().fill(Theme.seam).frame(height: 1) }
                        CallView(call: call)
                    }
                }
            }
        }
        .accessibilityIdentifier("row.tools")
    }
}

private struct CallView: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch call.kind {
            case .bash:
                (Text("$ ").foregroundColor(Theme.muted) + Text(call.target).foregroundColor(Theme.ink)
                    + Text(call.failed ? "  failed" : call.pending ? "  running…" : "").foregroundColor(call.failed ? Theme.bad : Theme.muted))
                    .font(Theme.mono)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            case .other:
                line {
                    Text(call.name).fontWeight(.medium)
                    if !call.target.isEmpty { Text(call.target).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle) }
                }
            case .read:
                line {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text("Read")
                    Text(call.target).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                    if let count = call.count { Text("· " + ChatThread.plural(count, "line")).foregroundStyle(Theme.muted).fixedSize() }
                }
            case .search:
                line {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Searched for")
                    Text(call.target).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                    if let count = call.count { Text("· " + ChatThread.plural(count, "result")).foregroundStyle(Theme.muted).fixedSize() }
                }
            case .fetch:
                line {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text("Fetched")
                    Text(call.target).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                }
            }
            if let output = call.output, !output.isEmpty, call.kind == .bash || call.kind == .other {
                Text(output)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(14)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            if call.failed && call.kind != .bash { Text("failed").foregroundStyle(Theme.bad) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct EditRow: View {
    let item: ThreadItem

    var body: some View {
        FoldRow(icon: "pencil") {
            Text(item.created ? "Created" : "Edited")
            Text((item.path as NSString).lastPathComponent).font(Theme.monoSmall).foregroundStyle(Theme.ink2)
            if let added = item.added, let removed = item.removed {
                Text("+\(added)").font(Theme.monoSmall).foregroundStyle(Theme.ok)
                Text("−\(removed)").font(Theme.monoSmall).foregroundStyle(Theme.bad)
            }
            if item.failed { Text("failed").foregroundStyle(Theme.bad) }
            if item.pending { Spinner(size: 10) }
        } content: {
            CodeBox {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.diff.prefix(240).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Theme.monoSmall)
                                .foregroundStyle(color(line))
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(line))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .accessibilityIdentifier("row.edit")
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("@@") || line == "…" { return Theme.muted }
        if line.hasPrefix("+") { return Theme.ok }
        if line.hasPrefix("-") { return Theme.bad }
        return Theme.muted
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") { return Theme.ok.opacity(0.08) }
        if line.hasPrefix("-") { return Theme.bad.opacity(0.08) }
        return .clear
    }
}

struct ThinkingRow: View {
    let item: ThreadItem

    private var label: String {
        if item.streaming { return "Thinking…" }
        if let seconds = item.seconds { return "Thought for \(seconds)s" }
        return "Thought"
    }

    var body: some View {
        FoldRow(icon: "brain") {
            if item.streaming {
                ShineText(text: label, font: .system(size: 12.5))
            } else {
                Text(label)
            }
        } content: {
            Text(item.text.isEmpty ? "The thinking is not shown." : item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The "Provisioned thread" system row: muted, opens to where the chat runs.
struct ProvisionedRow: View {
    let lines: [String]

    var body: some View {
        FoldRow(icon: "server.rack") {
            Text("Provisioned thread")
        } content: {
            CodeBox {
                Text(lines.joined(separator: "\n"))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("row.provisioned")
    }
}

/// "Started N agents": the subagents this turn started. Each opens its transcript.
struct SpawnRow: View {
    let agents: [SpawnedAgent]
    let info: (SpawnedAgent) -> SessionAgent?
    let onOpen: ((SpawnedAgent) -> Void)?

    var body: some View {
        FoldRow(icon: "person.2", defaultOpen: true) {
            Text("Started \(ChatThread.plural(agents.count, "agent"))")
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(agents) { agent in
                    let known = info(agent)
                    let running = known.map(\.isRunning) ?? agent.pending
                    Button {
                        onOpen?(agent)
                    } label: {
                        HStack(spacing: 8) {
                            if running {
                                Spinner(size: 10)
                            } else {
                                Circle().fill(Theme.muted).frame(width: 6, height: 6).padding(.horizontal, 2)
                            }
                            Text(agent.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(known?.model.map { Format.modelLabel($0) } ?? agent.type ?? (agent.background ? "background" : "Agent"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpen == nil)
                    .accessibilityIdentifier("subagent.\(agent.toolUseId)")
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            .padding(.leading, 6)
        }
    }
}

// ---- the cards for what the chat waits on

private struct CardTitle: View {
    let icon: String
    let text: String
    var tint: Color = Theme.ink

    var body: some View {
        Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: icon).font(.system(size: 13))
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(tint)
    }
}

private struct CommandBox: View {
    let command: String

    var body: some View {
        Text(command)
            .font(Theme.mono)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.seam, lineWidth: 1))
            .textSelection(.enabled)
    }
}

private extension View {
    func askBox(attn: Bool) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(attn ? Theme.attnSoft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(attn ? Theme.attnLine : Theme.line, lineWidth: 1))
    }
}

/// An AskUserQuestion: the open card with its options, or one line once answered.
struct QuestionCard: View {
    let item: ThreadItem
    let live: Bool
    let onAnswer: ((String) -> Void)?
    @State private var other = ""

    var body: some View {
        if let answer = item.answer {
            answered(icon: "checkmark", tint: Theme.ok) {
                Text("You answered: ") + Text(answer).fontWeight(.semibold).foregroundColor(Theme.strong)
            }
        } else if !live {
            answered(icon: "hand.raised", tint: Theme.ok) {
                Text("Asked: \(item.text)")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(icon: "hand.raised", text: "Waiting on you", tint: Theme.attn)
                MarkdownView(text: item.text)
                VStack(spacing: 6) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { at, option in
                        Button {
                            onAnswer?(option.label)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(at + 1)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 20, height: 20)
                                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.seam, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onAnswer == nil)
                        .accessibilityIdentifier("question.option.\(at + 1)")
                    }
                }
                if let onAnswer {
                    TextField("Or type another answer…", text: $other)
                        .font(.system(size: 14))
                        .submitLabel(.send)
                        .onSubmit {
                            let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                onAnswer(text)
                                other = ""
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .accessibilityIdentifier("question.other")
                }
                Text("An answer is sent as your reply\(onAnswer == nil ? " once the session has been quiet for 90 s" : "").")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .askBox(attn: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("question")
        }
    }

    private func answered(icon: String, tint: Color, text: () -> Text) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            text().lineLimit(1)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
    }
}

/// A permission prompt nobody could answer, refused.
struct RefusedCard: View {
    let item: ThreadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(icon: "shield", text: "Permission needed · \(item.tool)")
            Text(item.reason).font(.system(size: 14)).foregroundStyle(Theme.ink2)
            if !item.command.isEmpty { CommandBox(command: item.command) }
            Text("Reply to say how to go on, or pick a broader permission mode under the prompt box and send.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
        }
        .askBox(attn: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("refused")
    }
}

/// A live permission prompt: Allow once / Allow this tool / Deny, each sent back to the run.
struct PermissionCard: View {
    let item: ThreadItem
    let harness: String
    let sent: PermissionDecision?
    let onPermission: ((PermissionDecision) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(icon: "hand.raised", text: "Waiting on you · \(item.title ?? "\(item.tool) needs permission")", tint: Theme.attn)
            (Text("\(Format.harnessName(harness)) wants to use ") + Text(item.tool).fontWeight(.semibold) + Text(". Choose how to go on."))
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
            if !item.command.isEmpty { CommandBox(command: item.command) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            .padding(.top, 2)
            .disabled(onPermission == nil || sent != nil)
            Text(onPermission == nil ? "This run cannot take a decision right now." : "Allowing this tool for the run skips its prompt until the run ends. Or reply below to say how to go on.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
        }
        .askBox(attn: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission")
    }

    @ViewBuilder private var buttons: some View {
        Button { onPermission?(.allowOnce) } label: {
            label(.allowOnce, icon: "checkmark", text: "Allow once")
        }
        .buttonStyle(.fleet(.primary))
        .accessibilityIdentifier("permission.allowOnce")
        Button { onPermission?(.allowTool) } label: {
            label(.allowTool, icon: "shield", text: "Allow \(item.tool) this run")
        }
        .buttonStyle(.fleet(.plain))
        .accessibilityIdentifier("permission.allowTool")
        Button { onPermission?(.deny) } label: {
            label(.deny, icon: nil, text: "Deny")
        }
        .buttonStyle(.fleet(.danger))
        .accessibilityIdentifier("permission.deny")
    }

    private func label(_ decision: PermissionDecision, icon: String?, text: String) -> some View {
        HStack(spacing: 6) {
            if sent == decision {
                Spinner(size: 11)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            Text(text)
        }
    }
}

// ---- markdown

/// The web's small markdown: paragraphs, headings, "- " and "1. " lists, fenced code,
/// and inline code, bold and links.
enum MarkdownBlock: Hashable {
    case code(String)
    case heading(String)
    case list([String], numbered: Bool)
    case paragraph(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var code: [String]?
        var para: [String] = []
        var list: [String] = []
        var numbered = false
        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))) }
            para = []
        }
        func flushList() {
            if !list.isEmpty { out.append(.list(list, numbered: numbered)) }
            list = []
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushPara()
                    flushList()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushPara()
                flushList()
            } else if let heading = headingOf(line) {
                flushPara()
                flushList()
                out.append(.heading(heading))
            } else if let item = bulletOf(line) {
                flushPara()
                if numbered { flushList() }
                numbered = false
                list.append(item)
            } else if let item = numberedOf(line) {
                flushPara()
                if !numbered { flushList() }
                numbered = true
                list.append(item)
            } else {
                flushList()
                para.append(line)
            }
        }
        if let lines = code { out.append(.code(lines.joined(separator: "\n"))) }
        flushPara()
        flushList()
        return out
    }

    private static func headingOf(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return String(line.dropFirst(hashes + 1))
    }

    private static func bulletOf(_ line: String) -> String? {
        line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : nil
    }

    private static func numberedOf(_ line: String) -> String? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }.count
        guard digits > 0 else { return nil }
        let rest = line.dropFirst(digits)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

struct MarkdownView: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(Theme.mono)
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(3)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.seam, lineWidth: 1))
                case .heading(let line):
                    InlineText(line)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(Theme.strong)
                case .list(let lines, let numbered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { at, line in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(numbered ? "\(at + 1)." : "•")
                                    .foregroundStyle(Theme.muted)
                                    .frame(minWidth: 12, alignment: .trailing)
                                InlineText(line)
                            }
                        }
                    }
                    .font(.system(size: size))
                    .foregroundStyle(Theme.ink)
                case .paragraph(let text):
                    InlineText(text)
                        .font(.system(size: size))
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline markdown: `code`, **bold** and links, the line breaks kept.
struct InlineText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(Self.attributed(text))
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
