import SwiftUI
import FleetKit

struct RunChatView: View {
    @State private var model: RunChatModel
    @State private var showAgents = false
    @State private var atBottom = true
    /// Opens another run in place of this one (after Restart).
    let open: (String) -> Void

    init(client: FleetClient, runId: String, open: @escaping (String) -> Void) {
        _model = State(initialValue: RunChatModel(client: client, runId: runId))
        self.open = open
    }

    /// Changes when the chat grows, so it can follow the bottom.
    private var growth: String {
        "\(model.items.count):\(model.items.last?.text.count ?? 0):\(model.items.last?.children.count ?? 0)"
    }

    private var agentsTitle: String {
        model.runningAgents > 0 ? "\(model.runningAgents) running" : "Agents"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.canLoadEarlier {
                        Button {
                            Task { await model.loadEarlier() }
                        } label: {
                            if model.loadingEarlier { ProgressView() } else { Text("Load earlier") }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(model.items) { item in
                        ChatRowView(item: item)
                    }
                    if model.run?.turnOpen == true {
                        WorkingRow(run: model.run)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: growth) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .overlay {
            if model.items.isEmpty && model.run == nil && model.error == nil { ProgressView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(model: model, open: open)
        }
        .navigationTitle(model.run?.title ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAgents = true } label: {
                    Label(agentsTitle, systemImage: "person.2")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.agents.isEmpty)
                .accessibilityIdentifier("agents.open")
            }
        }
        .sheet(isPresented: $showAgents) { AgentsSheet(model: model) }
        .task { await model.start() }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if case .retrying(let reason) = model.connection {
                Banner(text: "Reconnecting… \(reason)", systemImage: "wifi.exclamationmark", tint: .orange)
            }
            if let error = model.error {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .red)
                    .onTapGesture { model.error = nil }
            }
            if let run = model.run, run.status == .usageBlocked || run.usageBlock != nil, !run.isEnded {
                Banner(text: run.usageBlock?.message ?? "A usage limit was reached. The run waits for it to reset.", systemImage: "gauge.with.dots.needle.100percent", tint: .orange)
            }
            if let pending = model.run?.pendingPermission {
                PermissionBanner(pending: pending, busy: model.busy) { decision in
                    Task { await model.respond(decision) }
                }
            }
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
    }
}

struct WorkingRow: View {
    let run: Run?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(run?.stats?.activity ?? "Working…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// ---- rows

struct ChatRowView: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            MarkdownText(text: item.text)
                .opacity(item.isPartial ? 0.75 : 1)
        case .thinking:
            DisclosureGroup {
                Text(item.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .tool, .subagent:
            ToolRow(item: item)
        case .result:
            ResultRow(item: item)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        case .usage, .exit:
            Label(item.text, systemImage: item.isError ? "exclamationmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(item.isError ? Color.orange : Color.secondary)
        case .status, .session:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

/// Inline markdown (bold, code, links) keeping the line breaks; plain text if it doesn't parse.
struct MarkdownText: View {
    let text: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResultRow: View {
    let item: ChatItem

    private var label: String {
        if item.subtype == "interrupted" { return "Interrupted" }
        var parts = [item.isError ? "Turn failed" : "Turn done"]
        if let ms = item.durationMs { parts.append(Format.duration(seconds: ms / 1000)) }
        if let cost = item.costUsd, cost > 0 { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(label)
                .font(.caption2)
                .foregroundStyle(item.isError && item.subtype != "interrupted" ? Color.red : Color.secondary)
                .fixedSize()
            VStack { Divider() }
        }
    }
}

/// A tool call: one compact line, tap for its input and output. An Agent/Task call
/// (or an orphan subagent thread) opens onto the subagent's own rows, nested.
struct ToolRow: View {
    let item: ChatItem
    @State private var expanded = false

    private var isSubagent: Bool { item.subagent != nil || item.kind == .subagent }

    private var title: String {
        if let call = item.subagent {
            return [call.type ?? "Agent", call.description].compactMap { $0 }.joined(separator: " · ")
        }
        if item.kind == .subagent { return "Subagent" }
        return item.name ?? "Tool"
    }

    private var icon: String {
        if isSubagent { return "person.crop.circle.badge.clock" }
        switch item.name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "MultiEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private var stateIcon: (String, Color)? {
        if item.outputIsError { return ("xmark.circle.fill", .red) }
        if item.hasOutput { return ("checkmark.circle", .secondary) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(isSubagent ? Color.purple : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let summary = item.summary, !summary.isEmpty, !isSubagent {
                            Text(summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if isSubagent {
                            Text(subagentLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if !item.hasOutput && !isSubagent {
                        ProgressView().controlSize(.mini)
                    } else if let state = stateIcon {
                        Image(systemName: state.0).foregroundStyle(state.1).font(.caption)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(isSubagent ? "subagent.\(item.toolId ?? item.id)" : "tool.\(item.toolId ?? item.id)")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if isSubagent {
                        ForEach(item.children) { child in
                            ChatRowView(item: child)
                        }
                        if item.children.isEmpty {
                            Text(item.subagent?.background == true ? "Runs in the background; see Agents." : "No activity yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let output = item.output, !output.isEmpty {
                            CodeBox(title: "Result", text: output, isError: item.outputIsError)
                        }
                    } else {
                        if let detail = item.detail, !detail.isEmpty {
                            CodeBox(title: "Input", text: detail, isError: false)
                        }
                        if let output = item.output, !output.isEmpty {
                            CodeBox(title: "Output", text: output, isError: item.outputIsError)
                        }
                    }
                }
                .padding(.leading, isSubagent ? 12 : 26)
                .overlay(alignment: .leading) {
                    if isSubagent {
                        Rectangle().fill(Color.purple.opacity(0.35)).frame(width: 2)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var subagentLine: String {
        let steps = item.children.filter { $0.kind == .tool }.count
        var parts: [String] = []
        if item.subagent?.background == true { parts.append("background") }
        parts.append(steps == 1 ? "1 tool call" : "\(steps) tool calls")
        if item.hasOutput { parts.append(item.outputIsError ? "failed" : "done") } else { parts.append("working") }
        return parts.joined(separator: " · ")
    }
}

struct CodeBox: View {
    let title: String
    let text: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text)
                    .font(.caption.monospaced())
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 260)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
