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

    /// A message typed here, shown until the run's own copy of it arrives (the web's `local` items).
    struct Local: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var state: String // "sending" or "queued"
    }

    let client: FleetClient
    let runId: String
    private(set) var run: Run?
    private(set) var caps: HarnessCapabilities?
    private(set) var machine: Machine?
    /// The chat's rows, as the web's `threadItems` draws them.
    private(set) var thread: [ThreadItem] = []
    private(set) var firstSeq: Int?
    private(set) var agents: [SessionAgent] = []
    private(set) var connection: Connection = .connecting
    private(set) var loadingEarlier = false
    private(set) var locals: [Local] = []
    /// The action in flight: "send", "respond", "interrupt", "stop" or "restart".
    private(set) var busy: String?
    /// The decision just sent for the held prompt, so its card shows a spinner on that button.
    private(set) var sentDecision: PermissionDecision?
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
    var isBusy: Bool { busy != nil }

    /// A held permission prompt keeps the turn open, but the run is really waiting on you, not working.
    var working: Bool {
        guard let run, !run.isEnded, run.pendingPermission == nil else { return false }
        return run.status == .running || run.status == .starting || run.turnOpen
    }

    /// Whether the last row is text still being written (then "Working..." hides).
    var streaming: Bool { thread.last?.streaming == true }

    /// The main button: Send now when the harness takes the message now, else Queue.
    var primary: (mode: String, control: Control, label: String)? { controls?.primary }

    var title: String {
        if let title = run?.title, !title.isEmpty, !title.hasPrefix("Attached session ") { return title }
        if let first = thread.first(where: { $0.kind == .user })?.text.split(separator: "\n").first { return String(first.prefix(120)) }
        return run?.title ?? runId
    }

    /// The composer's state line, worded as the web words it.
    var hint: String? {
        guard let run, let controls else { return nil }
        if let machine, !machine.isReachable { return "\(machine.name) is offline · sending fails until it's back" }
        if working && run.turnOpen && run.queued > 0 && controls.queue.enabled {
            return "\(Format.queuedText(run.queued)) waiting · new messages go after \(run.queued == 1 ? "it" : "them") when the turn ends"
        }
        if working && run.turnOpen && !controls.send.enabled && controls.queue.enabled { return "Messages queue until the turn ends" }
        if working && run.turnOpen && controls.send.enabled {
            return run.harness == "claude" ? "Send now: Claude Code reads it at its next tool step, so a long tool call delays it" : "Send now: \(Format.harnessName(run.harness)) takes it mid-turn"
        }
        return nil
    }

    /// Why the composer can't send at all, shown in place of its placeholder.
    var disabled: String? {
        guard let run, let controls else { return nil }
        if run.isEnded {
            if controls.restart.enabled && run.sessionId != nil && caps?.resume != false { return "This run has ended. Restart it to go on." }
            if run.sessionId == nil { return "This run has ended without a session to resume." }
            return "This run has ended and \(Format.harnessName(run.harness)) can't resume it."
        }
        if !controls.send.enabled && !controls.queue.enabled { return controls.send.reason }
        return nil
    }

    var provision: [String] { run.map { ChatThread.provision(run: $0, machineName: machine?.name) } ?? [] }

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
            if let machines = try? await client.machines() { machine = machines.first { $0.id == detail.run.machineId } }
            await refreshAgents(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handle(_ message: RunStreamMessage) {
        switch message {
        case .run(let fresh):
            let sessionChanged = fresh.sessionId != run?.sessionId
            take(fresh)
            if sessionChanged { Task { await refreshAgents(force: true) } }
        case .event(let event):
            if event.type == "user", event.agent == nil, let text = event.data.string("text") {
                // The run's own copy of a message typed here replaces it.
                let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let echo = locals.firstIndex(where: { $0.text == said }) { locals.remove(at: echo) }
            }
            if chat.apply(event) { scheduleRebuild() }
            if event.type == "tool_use", event.data.string("name").map({ ChatThread.isAgent($0) }) == true {
                Task { await refreshAgents(force: true) }
            }
        case .delta(let delta):
            chat.apply(delta)
            scheduleRebuild()
        case .ping:
            Task { await refreshAgents(force: false) }
        }
    }

    private func take(_ fresh: Run) {
        let before = run?.pendingPermission?.requestId
        run = fresh
        if fresh.pendingPermission?.requestId != before { sentDecision = nil }
        if fresh.isEnded { locals.removeAll { $0.state == "queued" } }
        scheduleRebuild()
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
        thread = ChatThread.items(events: chat.events, partials: chat.partials, pendingPermission: run?.pendingPermission)
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

    func agent(for spawned: SpawnedAgent) -> SessionAgent? {
        agents.first { $0.toolUseId == spawned.toolUseId } ?? spawned.agentId.flatMap { id in agents.first { $0.id == id } }
    }

    // ---- actions

    /// Sends a message: Send now ("auto") when the harness takes it now, else Queue.
    @discardableResult
    func send(_ text: String, mode: String? = nil) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, busy == nil else { return false }
        let mode = mode ?? (controls?.send.enabled == true ? "auto" : "queue")
        busy = "send"
        defer { busy = nil }
        let local = Local(text: text, state: "sending")
        locals.append(local)
        do {
            let response = try await client.send(runId, text: text, mode: mode)
            take(response.run)
            if response.queued == true, let at = locals.firstIndex(where: { $0.id == local.id }) { locals[at].state = "queued" }
            error = nil
            return true
        } catch {
            locals.removeAll { $0.id == local.id }
            self.error = error.localizedDescription
            return false
        }
    }

    private var asking: Bool { run?.pendingPermission.map { ChatThread.isAsk($0.tool) } == true }

    /// Whether the question card can take an answer: a held prompt, or a reply the run can take.
    var canAnswer: Bool { asking || (disabled == nil && !working) }

    /// The question card's answer: the held AskUserQuestion prompt takes it, else it goes as a reply.
    func answer(_ text: String) async {
        if asking {
            await respond(.allowOnce, answer: text)
        } else {
            await send(text)
        }
    }

    func interrupt() async { await act("interrupt") { try await $0.interrupt($1) } }
    func stop() async { await act("stop") { try await $0.stop($1) } }

    func respond(_ decision: PermissionDecision, message: String? = nil, answer: String? = nil) async {
        sentDecision = decision
        let done = await act("respond") { try await $0.respond($1, decision: decision, message: message, answer: answer) }
        if done == nil { sentDecision = nil }
    }

    /// Starts a new run that resumes this session; returns it so the screen can open it.
    func restart() async -> Run? { await act("restart") { try await $0.restart($1) } }

    @discardableResult
    private func act(_ name: String, _ action: @escaping @Sendable (FleetClient, String) async throws -> Run) async -> Run? {
        guard busy == nil else { return nil }
        busy = name
        defer { busy = nil }
        do {
            let fresh = try await action(client, runId)
            if fresh.id == runId { take(fresh) }
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
