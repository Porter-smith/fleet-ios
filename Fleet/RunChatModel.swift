import Foundation
import Observation
import FleetKit

/// One run's chat: its row, the events and partial text from its SSE stream,
/// and the composer's actions. Reconnects with backoff and resumes after the
/// last seq it has, so nothing is drawn twice.
@MainActor @Observable
final class RunChatModel {
    enum Connection: Equatable {
        case connecting, live
        case retrying(String)
    }

    let client: FleetClient
    let runId: String
    private(set) var run: Run?
    private(set) var caps: HarnessCapabilities?
    private(set) var items: [ChatItem] = []
    private(set) var firstSeq: Int?
    private(set) var agents: [SessionAgent] = []
    private(set) var connection: Connection = .connecting
    private(set) var loadingEarlier = false
    /// Messages the server queued for the end of the turn (it reports only how many).
    private(set) var queuedTexts: [String] = []
    private(set) var busy = false
    var error: String?

    @ObservationIgnored private var chat = ChatState()
    @ObservationIgnored private var rebuildPending = false
    @ObservationIgnored private var agentsFetchedAt = Date.distantPast

    init(client: FleetClient, runId: String) {
        self.client = client
        self.runId = runId
    }

    var controls: Controls? { run.map { Controls(run: $0, caps: caps) } }
    var canLoadEarlier: Bool { (firstSeq ?? 0) > 1 }
    var runningAgents: Int { agents.filter(\.isRunning).count }

    /// The main button. While a turn is open it queues (the message waits for the
    /// turn to end); "Send now" pushes into the live turn where the harness can.
    var primary: (mode: String, control: Control, label: String)? {
        guard let run, let controls else { return nil }
        if run.turnOpen && controls.queue.enabled { return ("queue", controls.queue, "Queue") }
        return controls.primary
    }

    // ---- the stream

    func start() async {
        await loadDetail()
        var failures = 0
        while !Task.isCancelled {
            connection = .connecting
            var reason = "The connection closed"
            do {
                for try await message in client.stream(runId, after: chat.events.isEmpty ? nil : chat.lastSeq) {
                    if connection != .live {
                        connection = .live
                        failures = 0
                    }
                    handle(message)
                }
            } catch {
                reason = error.localizedDescription
            }
            if Task.isCancelled { return }
            failures += 1
            connection = .retrying(reason)
            chat.clearPartials() // their deltas are lost; the finished events replay
            scheduleRebuild()
            let delay = min(30.0, pow(2.0, Double(failures - 1)))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func loadDetail() async {
        do {
            let detail = try await client.run(runId)
            run = detail.run
            caps = detail.capabilities
            await refreshAgents(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handle(_ message: RunStreamMessage) {
        switch message {
        case .run(let fresh):
            let sessionChanged = fresh.sessionId != run?.sessionId
            run = fresh
            if fresh.queued == 0 { queuedTexts.removeAll() }
            else if queuedTexts.count > fresh.queued { queuedTexts.removeFirst(queuedTexts.count - fresh.queued) }
            if sessionChanged { Task { await refreshAgents(force: true) } }
        case .event(let event):
            if chat.apply(event) { scheduleRebuild() }
            if event.type == "tool_use", event.data.string("name").map({ ["Agent", "Task"].contains($0) }) == true {
                Task { await refreshAgents(force: true) }
            }
        case .delta(let delta):
            chat.apply(delta)
            scheduleRebuild()
        case .ping:
            Task { await refreshAgents(force: false) }
        }
    }

    /// Coalesces a burst of events (the replay, fast deltas) into one rebuild.
    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            rebuildPending = false
            rebuild()
        }
    }

    private func rebuild() {
        items = chat.items()
        firstSeq = chat.firstSeq
    }

    /// The 200 events before the oldest one loaded (the transcript route reads forward from `after`).
    func loadEarlier() async {
        guard let first = chat.firstSeq, first > 1, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await client.transcript(runId, after: max(0, first - 1 - 200), limit: 200)
            chat.apply(page.events.filter { $0.seq < first })
            rebuild()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Background subagents of the run's session (GET /api/sessions/:id/agents).
    func refreshAgents(force: Bool) async {
        guard let run, let sessionId = run.sessionId, !sessionId.isEmpty else { return }
        guard force || Date().timeIntervalSince(agentsFetchedAt) > 15 else { return }
        agentsFetchedAt = Date()
        if let agents = try? await client.agents(sessionId: sessionId, machineId: run.machineId) { self.agents = agents }
    }

    // ---- actions

    @discardableResult
    func send(_ text: String, mode: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let response = try await client.send(runId, text: text, mode: mode)
            run = response.run
            if response.queued == true { queuedTexts.append(text) }
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func interrupt() async { await act { try await $0.interrupt($1) } }
    func stop() async { await act { try await $0.stop($1) } }
    func respond(_ decision: PermissionDecision) async { await act { try await $0.respond($1, decision: decision) } }

    /// Starts a new run that resumes this session; returns it so the screen can open it.
    func restart() async -> Run? { await act { try await $0.restart($1) } }

    @discardableResult
    private func act(_ action: @escaping @Sendable (FleetClient, String) async throws -> Run) async -> Run? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let fresh = try await action(client, runId)
            if fresh.id == runId { run = fresh }
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
