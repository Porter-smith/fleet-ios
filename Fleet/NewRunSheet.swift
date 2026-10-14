import SwiftUI
import FleetKit

/// Starts a run: machine, harness, model, folder and prompt (POST /api/runs).
struct NewRunSheet: View {
    let client: FleetClient
    let created: (Run) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var machines: [MachineHarnesses] = []
    @State private var workdirs: [String: String] = [:]
    @State private var loading = true
    @State private var machineId = ""
    @State private var harness = ""
    @State private var model = ""
    @State private var permissionMode = ""
    @State private var effort = ""
    @State private var cwd = ""
    @State private var title = ""
    @State private var prompt = ""
    @State private var busy = false
    @State private var error: String?

    /// Machines with at least one harness installed, so every choice can start.
    private var usable: [MachineHarnesses] {
        machines.filter { $0.harnesses.values.contains(where: \.installed) }
    }

    private var machine: MachineHarnesses? { usable.first { $0.machineId == machineId } }
    private var harnesses: [String] { (machine?.harnesses.filter { $0.value.installed }.keys).map { $0.sorted() } ?? [] }
    private var caps: HarnessCapabilities? { machine?.harnesses[harness] }
    private var canStart: Bool { !busy && caps?.installed == true && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView()
                } else if usable.isEmpty {
                    Text("No machine has a harness installed.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Where") {
                        Picker("Machine", selection: $machineId) {
                            ForEach(usable) { machine in
                                Text(machine.name).tag(machine.machineId)
                            }
                        }
                        .accessibilityIdentifier("newRun.machine")
                        Picker("Harness", selection: $harness) {
                            ForEach(harnesses, id: \.self) { name in
                                Text(Format.harnessName(name)).tag(name)
                            }
                        }
                        .accessibilityIdentifier("newRun.harness")
                        TextField(workdirs[machineId] ?? "Folder (machine default)", text: $cwd)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("newRun.cwd")
                    }
                    Section("How") {
                        Picker("Model", selection: $model) {
                            Text("Default").tag("")
                            ForEach(caps?.models ?? [], id: \.self) { id in
                                Text(Format.modelLabel(id)).tag(id)
                            }
                        }
                        .accessibilityIdentifier("newRun.model")
                        Picker("Permissions", selection: $permissionMode) {
                            Text("Default").tag("")
                            ForEach(NewRun.permissionModes, id: \.self) { mode in
                                Text(mode).tag(mode)
                            }
                        }
                        Picker("Effort", selection: $effort) {
                            Text("Default").tag("")
                            ForEach(NewRun.efforts, id: \.self) { level in
                                Text(level).tag(level)
                            }
                        }
                    }
                    Section("Prompt") {
                        TextField("Title (optional)", text: $title)
                        TextField("What should it do?", text: $prompt, axis: .vertical)
                            .lineLimit(5...12)
                            .accessibilityIdentifier("newRun.prompt")
                    }
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .accessibilityIdentifier("newRun")
            .navigationTitle("New run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await start() }
                    } label: {
                        if busy { ProgressView() } else { Text("Start") }
                    }
                    .disabled(!canStart)
                    .accessibilityIdentifier("newRun.start")
                }
            }
            .onChange(of: machineId) {
                if !harnesses.contains(harness) { harness = harnesses.contains("claude") ? "claude" : (harnesses.first ?? "") }
            }
            .onChange(of: harness) {
                if !(caps?.models ?? []).contains(model) { model = "" }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            machines = try await client.harnesses()
            if let all = try? await client.machines() {
                workdirs = Dictionary(all.compactMap { m in m.workdir.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
            }
            if machineId.isEmpty, let first = usable.first {
                machineId = first.machineId
                harness = harnesses.contains("claude") ? "claude" : (harnesses.first ?? "")
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func start() async {
        busy = true
        error = nil
        func blank(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let body = NewRun(
            machineId: machineId,
            harness: harness,
            model: blank(model),
            cwd: blank(cwd),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            title: blank(title),
            permissionMode: blank(permissionMode),
            effort: blank(effort)
        )
        do {
            let run = try await client.spawn(body)
            created(run)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
