import SwiftUI
import FleetKit

/// The web chat's "Background tasks" panel: the session's subagents, each with its
/// type, time, model, tokens and what it is doing now. Each opens its transcript.
struct AgentsSheet: View {
    let model: RunChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.agents) { agent in
                        NavigationLink {
                            AgentTranscriptView(model: model, agentId: agent.id, title: agent.description ?? ChatThread.agentType(agent), prompt: agent.prompt, result: agent.result, running: agent.isRunning)
                        } label: {
                            AgentRow(agent: agent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.\(agent.id)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Theme.canvas)
            .overlay {
                if model.agents.isEmpty {
                    Text("No background tasks in this session.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            .refreshable { await model.refreshAgents(force: true) }
            .navigationTitle("Background tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
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

struct AgentRow: View {
    let agent: SessionAgent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if agent.isRunning {
                    Spinner(size: 11)
                } else {
                    Circle().fill(agent.state == "failed" ? Theme.bad : Theme.muted).frame(width: 6, height: 6)
                }
            }
            .frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.description ?? ChatThread.agentType(agent))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(ChatThread.agentLine(agent))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A subagent's own transcript, drawn like the chat. Reloads every 5 s while it runs.
struct AgentTranscriptView: View {
    let model: RunChatModel
    let agentId: String
    let title: String
    var prompt: String?
    var result: String?
    var running = false
    @State private var items: [ThreadItem] = []
    @State private var error: String?
    @State private var loaded = false

    private var promptItem: [ThreadItem] {
        guard let prompt, !prompt.isEmpty else { return [] }
        return [ThreadItem(id: "prompt", kind: .user, text: prompt)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThreadView(items: promptItem + items, working: running, harness: model.run?.harness ?? "claude")
                if let result, !result.isEmpty, !running, items.last?.kind != .assistant {
                    MarkdownView(text: result)
                }
                if let error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.bad)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.canvas)
        .overlay { if !loaded { Spinner(size: 18) } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .accessibilityIdentifier("agent.transcript")
        .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            if !running { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func load() async {
        guard let run = model.run, let sessionId = run.sessionId else {
            loaded = true
            return
        }
        do {
            let transcript = try await model.client.agentTranscript(sessionId: sessionId, machineId: run.machineId, agentId: agentId)
            // The subagent's events, drawn as a thread of their own.
            items = ChatThread.items(events: transcript.events.map { event in
                var event = event
                event.agent = nil
                return event
            })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
