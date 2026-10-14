import SwiftUI
import FleetKit

struct RunsListView: View {
    let client: FleetClient
    @State private var store: RunsStore
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false

    init(client: FleetClient) {
        self.client = client
        _store = State(initialValue: RunsStore(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $store.showAll) {
                        Text("Active").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("runs.filter")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                ForEach(store.sections) { section in
                    Section {
                        ForEach(section.runs) { run in
                            NavigationLink(value: run.id) {
                                RunRow(run: run)
                            }
                            .accessibilityIdentifier("run:\(run.title ?? run.id)")
                        }
                    } header: {
                        MachineHeader(section: section)
                    }
                }
            }
            .overlay {
                if !store.loaded {
                    ProgressView()
                } else if store.sections.isEmpty && store.error == nil {
                    ContentUnavailableView(store.showAll ? "No runs" : "No active runs", systemImage: "tray", description: Text("Start one with +."))
                }
            }
            .refreshable { await store.refresh() }
            .task { await store.poll() }
            .navigationTitle("Runs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New run")
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
    }
}

struct MachineHeader: View {
    let section: RunsStore.Section

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
            Text(section.name)
            if let machine = section.machine, !machine.isReachable {
                Text("unreachable")
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("\(section.runs.count)")
        }
    }
}

struct RunRow: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(run: run)
                Text(run.title ?? "Untitled run")
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Format.runLine(run))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.ago(run.updatedAt ?? run.createdAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if run.pendingPermission != nil {
                Label("Waiting for permission", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if run.queued > 0 {
                Label(Format.queuedText(run.queued), systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The run's state at a glance: green while a turn runs, blue idle, orange when it needs you.
struct StatusDot: View {
    let run: Run

    var color: Color {
        if run.needsYou { return .orange }
        switch run.status {
        case .failed: return .red
        case .stopped, .exited, .unknown: return .gray
        case .starting: return .yellow
        case .usageBlocked: return .orange
        case .running, .idle: return run.turnOpen ? .green : .blue
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(run.turnOpen ? "Working" : run.status.label)
    }
}
