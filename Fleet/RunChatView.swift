import SwiftUI
import FleetKit

/// One Fleet chat thread, as the web draws it: the transcript in a centered column,
/// the composer card at the bottom, and the background tasks one tap away.
struct RunChatView: View {
    @State private var model: RunChatModel
    @State private var showAgents = false
    @State private var openAgent: SpawnedAgent?
    @State private var atBottom = true
    /// Opens another run in place of this one (after Restart).
    let open: (String) -> Void

    init(client: FleetClient, runId: String, open: @escaping (String) -> Void) {
        _model = State(initialValue: RunChatModel(client: client, runId: runId))
        self.open = open
    }

    /// Changes when the chat grows, so it can follow the bottom.
    private var growth: String {
        let last = model.thread.last
        return "\(model.thread.count):\(last?.text.count ?? 0):\(last?.calls.count ?? 0):\(model.locals.count):\(model.working)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.canLoadEarlier {
                        Button {
                            Task { await model.loadEarlier() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.loadingEarlier { Spinner(size: 11) }
                                Text("Load earlier")
                            }
                        }
                        .buttonStyle(.fleet(.plain, compact: true))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("loadEarlier")
                    }
                    if let run = model.run {
                        ThreadView(
                            items: model.thread,
                            locals: model.locals,
                            provision: model.provision,
                            working: model.working,
                            harness: run.harness,
                            agentInfo: { model.agent(for: $0) },
                            onOpenAgent: { spawned in
                                if (spawned.agentId ?? model.agent(for: spawned)?.id) != nil { openAgent = spawned }
                            },
                            onAnswer: { text in Task { await model.answer(text) } },
                            questionOpen: model.canAnswer,
                            onPermission: run.pendingPermission != nil ? { decision in Task { await model.respond(decision) } } : nil,
                            sentDecision: model.sentDecision
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: growth) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.canvas)
        .overlay {
            if model.thread.isEmpty && model.run == nil && model.error == nil { Spinner(size: 18) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(model: model, open: open)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.strong)
                        .lineLimit(1)
                    if let run = model.run {
                        Text(Format.runLine(run))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.title")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAgents = true } label: {
                    HStack(spacing: 4) {
                        if model.runningAgents > 0 { Spinner(size: 10) }
                        Image(systemName: "square.stack.3d.up")
                        if !model.agents.isEmpty { Text("\(model.runningAgents > 0 ? model.runningAgents : model.agents.count)").font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(Theme.ink)
                }
                .disabled(model.agents.isEmpty)
                .accessibilityLabel(model.runningAgents > 0 ? "\(model.runningAgents) background tasks running" : "Background tasks")
                .accessibilityIdentifier("agents.open")
            }
        }
        .sheet(isPresented: $showAgents) { AgentsSheet(model: model) }
        .sheet(item: $openAgent) { spawned in
            AgentSheet(model: model, spawned: spawned)
        }
        .task { await model.start() }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if case .retrying(let reason) = model.connection {
                Banner(text: "Reconnecting · \(reason)", systemImage: "wifi.exclamationmark", tint: Theme.attn)
            }
            if let run = model.run, run.status == .usageBlocked || run.usageBlock != nil, !run.isEnded {
                Banner(text: run.usageBlock?.message ?? "A usage limit was reached. The run waits for it to reset.", systemImage: "gauge.with.dots.needle.100percent", tint: Theme.attn)
            }
        }
    }
}

/// A thin strip under the header for the connection and usage limits.
struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.caption)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.attnSoft)
            .foregroundStyle(tint)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.seam).frame(height: 1) }
    }
}

/// A subagent's transcript, opened from its row in the thread.
private struct AgentSheet: View {
    let model: RunChatModel
    let spawned: SpawnedAgent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = model.agent(for: spawned)
        NavigationStack {
            Group {
                if let id = spawned.agentId ?? info?.id {
                    AgentTranscriptView(
                        model: model,
                        agentId: id,
                        title: info?.description ?? spawned.name,
                        prompt: info?.prompt,
                        result: info?.result,
                        running: info?.isRunning ?? spawned.pending
                    )
                } else {
                    Text("This task's transcript isn't available yet.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("sheet.done")
                }
            }
        }
    }
}
