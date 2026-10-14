import SwiftUI
import FleetKit

/// The web chat's sidebar as the phone's first screen: "Running and waiting", then
/// every other thread grouped by machine. A row opens its chat.
struct RunsListView: View {
    let client: FleetClient
    @State private var store: RunsStore
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false
    @State private var collapsed: Set<String> = []

    init(client: FleetClient) {
        self.client = client
        _store = State(initialValue: RunsStore(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = store.error {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(Theme.small)
                            .foregroundStyle(Theme.bad)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.badLine))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    let active = store.active
                    if !active.isEmpty {
                        SectionHeader(title: "Running and waiting", count: active.count)
                        ForEach(active) { run in
                            NavigationLink(value: run.id) {
                                ActiveRunRow(run: run, machine: store.machine(run.machineId))
                            }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityIdentifier("run:\(run.title ?? run.id)")
                        }
                    }
                    let groups = store.groups
                    if !groups.isEmpty {
                        SectionHeader(title: "Threads", count: nil)
                            .padding(.top, active.isEmpty ? 0 : 14)
                        ForEach(groups) { group in
                            let open = !collapsed.contains(group.id)
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                                }
                            } label: {
                                MachineGroupHeader(group: group, open: open)
                            }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityIdentifier("machine:\(group.name)")
                            if open {
                                ForEach(group.runs) { run in
                                    NavigationLink(value: run.id) {
                                        ThreadRunRow(run: run)
                                    }
                                    .buttonStyle(RowButtonStyle())
                                    .accessibilityIdentifier("run:\(run.title ?? run.id)")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(Theme.canvas)
            .overlay {
                if !store.loaded {
                    Spinner(size: 18)
                } else if store.active.isEmpty && store.groups.isEmpty && store.error == nil {
                    VStack(spacing: 6) {
                        Text(store.query.isEmpty ? "No threads yet" : "No threads match").font(Theme.body).foregroundStyle(Theme.ink)
                        Text("Start one with the pencil above.").font(Theme.small).foregroundStyle(Theme.muted)
                    }
                }
            }
            .searchable(text: $store.query, prompt: "Search threads")
            .refreshable { await store.refresh() }
            .task { await store.poll() }
            .navigationTitle("Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("newRun.open")
                }
            }
            .navigationDestination(for: String.self) { id in
                RunChatView(client: client, runId: id) { next in path = [next] }
            }
            .sheet(isPresented: $showNew) {
                NewRunSheet(client: client) { run in
                    showNew = false
                    path = [run.id]
                    Task { await store.refresh() }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .tint(Theme.strong)
    }
}

/// The sidebar's rows: a soft highlight while pressed, like the web's hover.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count { Text("\(count)").foregroundStyle(Theme.muted.opacity(0.7)) }
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Running and waiting": the title and machine, then what the turn is doing.
private struct ActiveRunRow: View {
    let run: Run
    let machine: Machine?

    var body: some View {
        let status = ChatThread.status(of: run)
        let unreachable = machine.map { !$0.isReachable } ?? false
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(status: unreachable ? .unknown : status)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.title ?? "Untitled thread")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.strong)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(machine?.name ?? run.machineId)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                let line = unreachable ? "Unknown · machine unreachable" : status == .waiting ? waitingLine : ChatThread.compactLine(run)
                if !line.isEmpty {
                    Text(line)
                        .font(Theme.caption)
                        .foregroundStyle(status == .waiting && !unreachable ? Theme.attn : Theme.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var waitingLine: String {
        if let pending = run.pendingPermission {
            return ChatThread.isAsk(pending.tool) ? "Asking you a question" : "Waiting for permission: \(pending.tool)"
        }
        if run.status == .usageBlocked { return "Usage limit reached" }
        return "Needs you"
    }
}

/// A machine's group in "Threads": its name, an offline note, and a chevron.
private struct MachineGroupHeader: View {
    let group: RunsStore.Group
    let open: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 16)
            Text(group.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if let machine = group.machine, !machine.isReachable {
                Text("offline" + (machine.lastCheckedAt.map { " · " + ChatThread.relTime(Date().timeIntervalSince1970 * 1000 - $0) } ?? ""))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A finished or idle thread: its title, its age, and its state.
private struct ThreadRunRow: View {
    let run: Run

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: ChatThread.status(of: run))
                .frame(width: 16)
            Text(run.title ?? "Untitled thread")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(ChatThread.relTime(Date().timeIntervalSince1970 * 1000 - (run.updatedAt ?? run.createdAt)))
                .font(Theme.caption)
                .foregroundStyle(Theme.muted)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}
