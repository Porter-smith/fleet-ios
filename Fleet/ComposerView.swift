import SwiftUI
import FleetKit

/// The web chat's composer card: the message box, then a row with "+", the model,
/// and the send buttons. While a turn runs and there is text, Queue and Send now both
/// show, the one Enter would pick filled in; with no text only the stop square shows.
/// Every button follows `Controls`, so an action the run can't take is disabled.
struct ComposerView: View {
    let model: RunChatModel
    let open: (String) -> Void
    @State private var text = ""
    @State private var confirmStop = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && model.disabled == nil && !model.isBusy }

    private var placeholder: String {
        if let disabled = model.disabled { return disabled }
        if !model.working { return "Ask for a follow-up" }
        return model.controls?.send.enabled == true ? "Message the agent. Send now reaches it mid-turn" : "Queue a follow-up. It is sent when the turn ends"
    }

    private var restartable: Bool {
        guard let run = model.run, let controls = model.controls else { return false }
        return controls.restart.enabled && !run.isExternal && run.sessionId != nil && model.caps?.resume != false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error {
                Text(error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.badLine))
                    .onTapGesture { model.error = nil }
                    .accessibilityIdentifier("composer.error")
            }
            if let run = model.run, run.isEnded, restartable {
                restartNotice
            }
            card
            underRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(Theme.canvas)
        .confirmationDialog("Stop this run?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop run", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("This ends the harness process. You can restart it later to go on in its session.")
        }
    }

    // ---- the card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 16))
                .foregroundStyle(Theme.strong)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(model.disabled != nil && text.isEmpty)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .frame(minHeight: 52, alignment: .topLeading)
                .accessibilityIdentifier("composer.field")
            HStack(spacing: 6) {
                moreMenu
                modelChip
                Spacer(minLength: 4)
                sendButtons
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Theme.ink2.opacity(0.5) : Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    /// "+": plan first (Claude Code, set when the run started), and the run's own actions.
    private var moreMenu: some View {
        Menu {
            if model.run?.harness == "claude" {
                Button {} label: {
                    Label("Plan first", systemImage: "list.bullet.clipboard")
                    Text("Set when a run starts")
                }
                .disabled(true)
            }
            if let controls = model.controls {
                if controls.interrupt.enabled {
                    Button { Task { await model.interrupt() } } label: {
                        Label("Interrupt turn", systemImage: "pause.circle")
                    }
                }
                if restartable {
                    Button { restart() } label: { Label("Restart run", systemImage: "arrow.clockwise") }
                        .disabled(model.isBusy)
                }
                if controls.stop.enabled {
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label(model.run?.isExternal == true ? "Stop watching" : "Stop run", systemImage: "stop")
                    }
                    .disabled(model.isBusy)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("composer.more")
    }

    /// The run's harness, model and effort. A live run's process keeps what it started with.
    private var modelChip: some View {
        Menu {
            Section("This run's process is live: its model and effort were set when it started.") {
                if let run = model.run {
                    Button {} label: { Label(Format.modelLabel(run.model), systemImage: "checkmark") }.disabled(true)
                    if let effort = run.effort, ChatThread.takesEffort(run.harness) {
                        Button {} label: { Text("\(ChatThread.effortLabel(effort)) effort") }.disabled(true)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let run = model.run { HarnessMark(harness: run.harness, size: 14) }
                Text(modelText)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("composer.model")
    }

    private var modelText: String {
        guard let run = model.run else { return "Model" }
        var out = Format.modelLabel(run.model)
        if let effort = run.effort, ChatThread.takesEffort(run.harness) { out += " · " + ChatThread.effortLabel(effort) }
        return out
    }

    @ViewBuilder private var sendButtons: some View {
        let controls = model.controls
        HStack(spacing: 4) {
            if model.working, let controls {
                if !trimmed.isEmpty {
                    let primary = controls.send.enabled ? "auto" : "queue"
                    modeButton("queue", label: "Queue", control: controls.queue, primary: primary == "queue")
                    modeButton("auto", label: "Send now", control: controls.send, primary: primary == "auto")
                }
                stopButton(controls)
            } else {
                Button { submit(mode: nil) } label: {
                    Image(systemName: model.busy == "send" ? "ellipsis" : "return")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer.send")
            }
        }
    }

    private func modeButton(_ mode: String, label: String, control: Control, primary: Bool) -> some View {
        Button { submit(mode: mode) } label: {
            HStack(spacing: 4) {
                Text(label)
                if primary { Image(systemName: "return").font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Theme.onPrimary : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(primary ? Theme.primary : Theme.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSend || !control.enabled)
        .opacity(canSend && control.enabled ? 1 : 0.4)
        .accessibilityHint(control.reason)
        .accessibilityIdentifier(mode == "auto" ? "composer.sendNow" : "composer.queue")
    }

    @ViewBuilder private func stopButton(_ controls: Controls) -> some View {
        let choice = ChatThread.stopChoice(controls: controls, caps: model.caps)
        Button {
            switch choice.action {
            case .interrupt: Task { await model.interrupt() }
            case .stop: confirmStop = true
            case nil: break
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(choice.action == nil || model.isBusy)
        .opacity(choice.action == nil ? 0.4 : 1)
        .accessibilityLabel(choice.label)
        .accessibilityIdentifier("composer.interrupt")
    }

    // ---- around the card

    private var restartNotice: some View {
        HStack(spacing: 4) {
            Text("This run has ended.")
                .foregroundStyle(Theme.ink)
            Button { restart() } label: {
                Text(model.busy == "restart" ? "Restarting..." : "Restart it").underline()
                    .foregroundStyle(Theme.strong)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityIdentifier("composer.restart")
            Text("to go on.")
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .font(Theme.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.attnSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.attnLine))
    }

    /// Under the card: the machine, the composer's hint, and the permission mode.
    private var underRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let machine = model.machine {
                Label(machine.name, systemImage: "server.rack")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            if let hint = model.hint {
                Text(hint)
                    .foregroundStyle(Theme.attn)
                    .lineLimit(2)
                    .accessibilityIdentifier("composer.hint")
            }
            Spacer(minLength: 4)
            if let run = model.run, ChatThread.takesPermissionMode(run.harness) {
                Text(ChatThread.permissionLabel(run.permissionMode))
                    .foregroundStyle(run.permissionMode == "bypassPermissions" ? Theme.attn : Theme.muted)
                    .lineLimit(1)
                    .accessibilityIdentifier("composer.permissionMode")
            }
        }
        .font(Theme.caption)
        .padding(.horizontal, 6)
    }

    // ---- actions

    private func submit(mode: String?) {
        guard canSend else { return }
        let sent = trimmed
        text = ""
        Task {
            let ok = await model.send(sent, mode: mode)
            if !ok && text.isEmpty { text = sent }
        }
    }

    private func restart() {
        Task { if let fresh = await model.restart() { open(fresh.id) } }
    }
}
