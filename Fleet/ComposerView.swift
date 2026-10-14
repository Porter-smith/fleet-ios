import SwiftUI
import FleetKit

/// The message box and run controls. Every button follows `Controls`: an action
/// the harness can't do (or the run's state forbids) is disabled with its reason.
struct ComposerView: View {
    let model: RunChatModel
    let open: (String) -> Void
    @State private var text = ""
    @State private var confirmStop = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.queuedTexts.isEmpty || (model.run?.queued ?? 0) > 0 {
                queued
            }
            if let run = model.run, run.isEnded {
                ended(run)
            } else {
                editor
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog("Stop this run?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop run", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("This ends the harness process. You can restart it later to continue the session.")
        }
    }

    private var queued: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(Format.queuedText(max(model.run?.queued ?? 0, model.queuedTexts.count)) + " for the end of this turn", systemImage: "tray.full")
                .font(.caption.weight(.medium))
            ForEach(Array(model.queuedTexts.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("composer.queued")
    }

    private func ended(_ run: Run) -> some View {
        HStack {
            Text(run.status == .failed ? "The run failed." : "The run has ended.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { if let fresh = await model.restart() { open(fresh.id) } }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.controls?.restart.enabled != true)
            .accessibilityIdentifier("composer.restart")
        }
    }

    private var editor: some View {
        let controls = model.controls
        let primary = model.primary
        let turnOpen = model.run?.turnOpen == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                menu(controls)
                TextField(turnOpen ? "Message (queues for the end of the turn)" : "Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("composer.field")
                Button {
                    submit(mode: primary?.mode ?? "auto")
                } label: {
                    Image(systemName: primary?.mode == "queue" ? "text.badge.plus" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(trimmed.isEmpty || model.busy || primary?.control.enabled != true)
                .accessibilityLabel(primary?.label ?? "Send")
                .accessibilityHint(primary?.control.reason ?? "")
                .accessibilityIdentifier("composer.send")
            }
            if turnOpen, let controls {
                HStack(spacing: 8) {
                    Button {
                        submit(mode: "auto")
                    } label: {
                        Label("Send now", systemImage: "bolt.fill")
                    }
                    .disabled(trimmed.isEmpty || model.busy || !controls.send.enabled)
                    .accessibilityHint(controls.send.reason)
                    .accessibilityIdentifier("composer.sendNow")

                    Button {
                        Task { await model.interrupt() }
                    } label: {
                        Label("Interrupt", systemImage: "pause.circle")
                    }
                    .disabled(model.busy || !controls.interrupt.enabled)
                    .accessibilityHint(controls.interrupt.reason)
                    .accessibilityIdentifier("composer.interrupt")

                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)
                if !controls.send.enabled {
                    Text(controls.send.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func menu(_ controls: Controls?) -> some View {
        Menu {
            if let controls {
                Button { submit(mode: "auto") } label: {
                    Label("Send now", systemImage: "bolt.fill")
                    Text(controls.send.reason)
                }
                .disabled(trimmed.isEmpty || !controls.send.enabled)
                Button { submit(mode: "queue") } label: {
                    Label("Queue for end of turn", systemImage: "text.badge.plus")
                    Text(controls.queue.reason)
                }
                .disabled(trimmed.isEmpty || !controls.queue.enabled)
                Button { Task { await model.interrupt() } } label: {
                    Label("Interrupt", systemImage: "pause.circle")
                    Text(controls.interrupt.reason)
                }
                .disabled(!controls.interrupt.enabled)
                Divider()
                Button(role: .destructive) { confirmStop = true } label: {
                    Label("Stop", systemImage: "stop.circle")
                    Text(controls.stop.reason)
                }
                .disabled(!controls.stop.enabled)
                Button { Task { if let fresh = await model.restart() { open(fresh.id) } } } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                    Text(controls.restart.reason)
                }
                .disabled(!controls.restart.enabled)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
        }
        .disabled(model.busy || controls == nil)
        .accessibilityLabel("Run actions")
        .accessibilityIdentifier("composer.more")
    }

    private func submit(mode: String) {
        let message = trimmed
        guard !message.isEmpty else { return }
        Task {
            if await model.send(message, mode: mode) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == message { text = "" }
            }
        }
    }
}

/// A tool call held for approval (holdPermissions runs).
struct PermissionBanner: View {
    let pending: PendingPermission
    let busy: Bool
    let decide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pending.title ?? "\(pending.tool) wants to run", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            if let command = pending.command, !command.isEmpty {
                Text(command)
                    .font(.caption.monospaced())
                    .lineLimit(4)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Allow once") { decide(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                Button("Always allow \(pending.tool)") { decide(.allowTool) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Deny", role: .destructive) { decide(.deny) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding()
        .background(Color.orange.opacity(0.15))
        .accessibilityIdentifier("permission")
    }
}
