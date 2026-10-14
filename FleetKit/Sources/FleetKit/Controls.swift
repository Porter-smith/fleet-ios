import Foundation

/// One composer action: whether it's allowed, and why (shown when it isn't).
public struct Control: Hashable, Sendable {
    public var enabled: Bool
    public var reason: String
    static func on(_ reason: String) -> Control { Control(enabled: true, reason: reason) }
    static func off(_ reason: String) -> Control { Control(enabled: false, reason: reason) }
}

/// What the composer may do for a run, from the harness's own capabilities.
/// A port of web/src/chat/controls.ts: an action the harness can't do is shown
/// disabled with the reason, never faked.
public struct Controls: Hashable, Sendable {
    public var send: Control
    public var queue: Control
    public var interrupt: Control
    public var stop: Control
    public var restart: Control

    public init(run: Run, caps: HarnessCapabilities?) {
        let name = Format.harnessName(run.harness)
        let ended = run.isEnded
        let failedWord = run.status == .failed ? "failed" : "ended"
        let gone = Control.off("The run has \(failedWord). Restart to continue.")
        let unknown = Control.off("Fleet doesn't know what \(name) can do on this machine yet")
        let external = run.isExternal

        if ended { send = gone }
        else if caps == nil { send = unknown }
        else if caps?.send != true { send = .off("\(name) can't take a new message into a live session") }
        else if external && run.turnOpen { send = .off("This session was started outside fleet and is mid-turn; it can be continued once the turn ends") }
        else if !run.turnOpen { send = .on("Sends the message now") }
        else if caps?.midTurnInput != true { send = .off("\(name) reads a new message only between turns. Queue it for the end of the turn") }
        else if run.queued > 0 { send = .off("\(Format.queuedText(run.queued)) waiting, so this one goes after \(run.queued == 1 ? "it" : "them") when the turn ends. Queue it") }
        else { send = .on(run.harness == "claude" ? "Goes into the live turn now. Claude Code reads it at its next tool step, so a long tool call delays it" : "Goes into the live turn now; \(name) takes it mid-turn") }

        if ended { queue = gone }
        else if caps == nil { queue = unknown }
        else if external { queue = .off("Queueing works only for runs fleet started. Send once the turn ends to continue this session") }
        else if caps?.queue != true { queue = .off("\(name) can't queue messages for the end of the turn") }
        else { queue = .on("Waits for the current turn to end, then sends") }

        if ended { interrupt = gone }
        else if caps == nil { interrupt = unknown }
        else if external { interrupt = .off("Fleet did not start this process, so it cannot interrupt it. Interrupt it where it runs") }
        else if caps?.interrupt != true { interrupt = .off("\(name) can't be interrupted mid-turn") }
        else if !run.turnOpen { interrupt = .off("No turn in progress") }
        else { interrupt = .on("Stops the current turn; the session stays open") }

        if ended { stop = .off("The run has already \(failedWord)") }
        else if external { stop = .on("Stops watching this session. The process started outside fleet keeps running") }
        else { stop = .on("Kills the harness process; the files it changed stay") }

        if run.status == .starting { restart = .off("The run is still starting") }
        else if external { restart = .off("Fleet did not start this session. Send a message once it is idle to continue it as a fleet run") }
        else if let caps {
            restart = caps.resume ? .on("Starts a new run that resumes this \(name) session") : .on("\(name) can't resume a session, so the new run won't carry this conversation")
        } else { restart = .on("Starts a new run for this session") }
    }

    /// The main button: Send when it's allowed now, else Queue (the message waits for the turn to end).
    public var primary: (mode: String, control: Control, label: String) {
        if send.enabled { return ("auto", send, "Send") }
        return ("queue", queue, "Queue")
    }
}
