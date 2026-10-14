import SwiftUI
import FleetKit

/// The session's subagents, including background ones still working after the turn.
struct AgentsSheet: View {
    let model: RunChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.agents) { agent in
                NavigationLink {
                    AgentTranscriptView(model: model, agent: agent)
                } label: {
                    AgentRow(agent: agent)
                }
            }
            .overlay {
                if model.agents.isEmpty {
                    ContentUnavailableView("No subagents", systemImage: "person.2")
                }
            }
            .refreshable { await model.refreshAgents(force: true) }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct AgentRow: View {
    let agent: SessionAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if agent.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: agent.state == "failed" ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(agent.state == "failed" ? Color.red : Color.secondary)
                }
                Text(agent.description ?? agent.type ?? agent.id)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let activity = agent.activityLabel ?? agent.activity, agent.isRunning {
                Text(activity)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var line: String {
        var parts: [String] = []
        if let type = agent.type { parts.append(type) }
        if let model = agent.model { parts.append(Format.modelLabel(model)) }
        if let uses = agent.toolUses { parts.append(uses == 1 ? "1 tool call" : "\(uses) tool calls") }
        if let tokens = agent.tokens { parts.append("\(Format.tokenCount(tokens)) tokens") }
        if let last = agent.lastAt { parts.append(Format.ago(last)) }
        return parts.joined(separator: " · ")
    }
}

struct AgentTranscriptView: View {
    let model: RunChatModel
    let agent: SessionAgent
    @State private var items: [ChatItem] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let prompt = agent.prompt, !prompt.isEmpty {
                    ChatRowView(item: ChatItem(id: "prompt", seq: 0, kind: .user, text: prompt))
                }
                ForEach(items) { item in
                    ChatRowView(item: item)
                }
                if let result = agent.result, !result.isEmpty, !agent.isRunning {
                    CodeBox(title: "Result", text: result, isError: agent.state == "failed")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(agent.description ?? agent.type ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task { await poll() }
    }

    /// Reloads every 5 s while the agent runs.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            if !agent.isRunning { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func load() async {
        guard let run = model.run, let sessionId = run.sessionId else {
            loaded = true
            return
        }
        do {
            let transcript = try await model.client.agentTranscript(sessionId: sessionId, machineId: run.machineId, agentId: agent.id)
            items = Transcript.build(events: transcript.events)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
