import SwiftUI
import FleetKit

/// A new thread, as the web's hero composer starts it: "Ask anything." in a card with
/// the harness and model, the folder and machine under it, and (Claude Code only) the
/// permission mode. Permission prompts are held for the chat's Allow / Deny buttons.
struct NewRunSheet: View {
    let client: FleetClient
    let created: (Run) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var machines: [MachineHarnesses] = []
    @State private var info: [String: Machine] = [:]
    @State private var recent: [String: [String]] = [:]
    @State private var loading = true
    @State private var machineId = ""
    @State private var harness = "claude"
    @State private var model = ""
    @State private var permissionMode = "acceptEdits"
    @State private var effort = ""
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var busy = false
    @State private var error: String?
    @State private var askFolder = false
    @State private var folderDraft = ""
    @FocusState private var focused: Bool

    private func online(_ id: String) -> Bool { info[id]?.isReachable ?? true }
    private var machine: MachineHarnesses? { machines.first { $0.machineId == machineId } }
    private var harnesses: [String] {
        let installed = machine?.harnesses.filter { $0.value.installed }.keys.sorted() ?? []
        return installed.sorted { ($0 == "claude" ? 0 : 1, $0) < ($1 == "claude" ? 0 : 1, $1) }
    }
    private var caps: HarnessCapabilities? { machine?.harnesses[harness] }
    private var claude: Bool { harness == "claude" }

    /// Why nothing can start, shown in place of the placeholder (the web's `disabled`).
    private var disabled: String? {
        guard let machine else { return nil }
        if !online(machine.machineId) { return "\(machine.name) is offline" }
        if caps?.installed != true { return "\(Format.harnessName(harness)) is not installed on \(machine.name)" }
        return nil
    }
    private var canStart: Bool { !busy && disabled == nil && machine != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                if loading {
                    Spinner(size: 18)
                } else if machines.isEmpty {
                    Text(info.isEmpty ? "Add a machine in Settings to start a thread." : "Every machine is offline.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                } else {
                    hero
                }
                Spacer(minLength: 24)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("newRun")
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.ink)
                }
            }
            .alert("Folder", isPresented: $askFolder) {
                TextField(info[machineId]?.workdir ?? "/path/to/project", text: $folderDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use") { cwd = folderDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A folder on \(machine?.name ?? "the machine"). Leave it empty for the machine's default.")
            }
            .onChange(of: machineId) {
                if !harnesses.contains(harness) { harness = harnesses.first ?? "claude" }
                cwd = ""
            }
            .onChange(of: harness) {
                if !(caps?.models ?? []).contains(model) { model = "" }
                if !ChatThread.takesEffort(harness) { effort = "" }
            }
            .task { await load() }
        }
        .tint(Theme.strong)
    }

    // ---- the hero composer

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Text(error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.badLine))
            }
            VStack(alignment: .leading, spacing: 0) {
                TextField(disabled ?? "Ask anything.", text: $prompt, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.strong)
                    .lineLimit(3...10)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .frame(minHeight: 80, alignment: .topLeading)
                    .accessibilityIdentifier("newRun.prompt")
                HStack(spacing: 6) {
                    plusMenu
                    modelMenu
                    Spacer(minLength: 4)
                    Button { Task { await start() } } label: {
                        Group {
                            if busy { Spinner(size: 12) } else { Image(systemName: "return").font(.system(size: 14, weight: .semibold)) }
                        }
                        .foregroundStyle(Theme.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.4)
                    .accessibilityLabel(busy ? "Starting" : "Start")
                    .accessibilityIdentifier("newRun.start")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Theme.ink2.opacity(0.5) : Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)

            HStack(spacing: 2) {
                folderMenu
                machineMenu
                Spacer(minLength: 2)
                if ChatThread.takesPermissionMode(harness) { permissionMenu }
            }
            .padding(.horizontal, 4)
            Text("Starts a Fleet run")
                .font(Theme.caption)
                .foregroundStyle(Theme.attn)
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .onAppear { focused = true }
    }

    /// "+": Plan first sets the permission mode to Plan (Claude Code only).
    private var plusMenu: some View {
        Menu {
            Button { permissionMode = "plan" } label: { Label("Plan first", systemImage: "list.bullet.clipboard") }
                .disabled(!claude)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Prompt actions")
        .accessibilityIdentifier("newRun.more")
    }

    /// The web's model picker: the harness, its models, and (Claude Code only) the effort.
    private var modelMenu: some View {
        Menu {
            Picker("Harness", selection: $harness) {
                ForEach(harnesses, id: \.self) { name in
                    Text(Format.harnessName(name)).tag(name)
                }
            }
            .accessibilityIdentifier("newRun.harness")
            Section("Model") {
                Picker("Model", selection: $model) {
                    ForEach(ChatThread.modelOptions(harness: harness, models: caps?.models ?? [])) { option in
                        Text(option.via.map { "\(option.name) · \($0)" } ?? option.name).tag(option.model ?? "")
                    }
                }
            }
            if ChatThread.takesEffort(harness) {
                Section("Effort") {
                    Picker("Effort", selection: $effort) {
                        Text("Default effort").tag("")
                        ForEach(ChatThread.efforts, id: \.self) { level in
                            Text(ChatThread.effortLabel(level)).tag(level)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                HarnessIcon(harness: harness, size: 14)
                Text(modelText).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("newRun.model")
    }

    private var modelText: String {
        var out = model.isEmpty ? Format.harnessName(harness) : Format.modelLabel(model)
        if !effort.isEmpty && ChatThread.takesEffort(harness) { out += " · " + ChatThread.effortLabel(effort) }
        return out
    }

    private var folderMenu: some View {
        Menu {
            Button { cwd = "" } label: {
                Label("Machine default" + (info[machineId]?.workdir.map { " (\(Format.folder($0) ?? $0))" } ?? ""), systemImage: cwd.isEmpty ? "checkmark" : "folder")
            }
            ForEach(recent[machineId] ?? [], id: \.self) { folder in
                Button { cwd = folder } label: {
                    Label(folder, systemImage: cwd == folder ? "checkmark" : "folder")
                }
            }
            Divider()
            Button { folderDraft = cwd; askFolder = true } label: { Label("Other folder...", systemImage: "folder.badge.plus") }
        } label: {
            OptionChip(icon: "folder", text: Format.folder(cwd) ?? Format.folder(info[machineId]?.workdir) ?? "Folder")
        }
        .accessibilityIdentifier("newRun.cwd")
    }

    private var machineMenu: some View {
        Menu {
            Picker("Machine", selection: $machineId) {
                ForEach(machines) { m in
                    Text(online(m.machineId) ? m.name : "\(m.name) · offline").tag(m.machineId)
                }
            }
        } label: {
            OptionChip(icon: "server.rack", text: machine?.name ?? "Machine")
        }
        .accessibilityIdentifier("newRun.machine")
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(ChatThread.permissionModes) { mode in
                Button { permissionMode = mode.id } label: {
                    if permissionMode == mode.id { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                    Text(mode.hint)
                }
            }
        } label: {
            OptionChip(icon: nil, text: ChatThread.permissionLabel(permissionMode), tint: permissionMode == "bypassPermissions" ? Theme.attn : Theme.ink2)
        }
        .accessibilityIdentifier("newRun.permission")
    }

    // ---- loading and starting

    private func load() async {
        do {
            let all = try await client.harnesses()
            machines = all.filter { $0.harnesses.values.contains(where: \.installed) }
            if let list = try? await client.machines() {
                info = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            if let runs = try? await client.runs(limit: 200) {
                var folders: [String: [String]] = [:]
                for run in runs.sorted(by: { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }) {
                    guard let path = run.cwd, !path.isEmpty, !(folders[run.machineId] ?? []).contains(path) else { continue }
                    if (folders[run.machineId]?.count ?? 0) < 8 { folders[run.machineId, default: []].append(path) }
                }
                recent = folders
            }
            if machineId.isEmpty, let first = machines.first(where: { online($0.machineId) }) ?? machines.first {
                machineId = first.machineId
                harness = harnesses.first ?? "claude"
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func start() async {
        guard canStart else { return }
        busy = true
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = NewRun.chat(
            machineId: machineId,
            harness: harness,
            prompt: text,
            cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model,
            permissionMode: permissionMode,
            effort: effort
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
