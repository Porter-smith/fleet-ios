import Foundation

// Mirrors of server/types.ts, as the API serves them (docs/api.md). Decoding is
// tolerant on purpose: anything but an id is optional, and an enum value this
// build doesn't know decodes as `.unknown` instead of failing the whole list,
// so a newer server never blanks the app.

public enum RunStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case starting, running, idle
    case usageBlocked = "usage_blocked"
    case stopped, exited, failed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunStatus(rawValue: raw) ?? .unknown
    }

    /// The process is gone: stopped, exited or failed.
    public var isEnded: Bool { self == .stopped || self == .exited || self == .failed }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .idle: "Idle"
        case .usageBlocked: "Usage limit"
        case .stopped: "Stopped"
        case .exited: "Exited"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

public struct HarnessCapabilities: Codable, Hashable, Sendable {
    public var installed: Bool
    public var path: String?
    public var version: String?
    public var structuredStream: Bool
    public var send: Bool
    public var queue: Bool
    public var interrupt: Bool
    public var resume: Bool
    public var usageSignals: Bool
    /// Takes a message mid-turn (Send now). Only set on GET /api/runs/:id.
    public var midTurnInput: Bool?
    public var models: [String]
    public var notes: String?

    public init(installed: Bool = true, path: String? = nil, version: String? = nil, structuredStream: Bool = true, send: Bool = true, queue: Bool = true, interrupt: Bool = true, resume: Bool = true, usageSignals: Bool = true, midTurnInput: Bool? = nil, models: [String] = [], notes: String? = nil) {
        self.installed = installed
        self.path = path
        self.version = version
        self.structuredStream = structuredStream
        self.send = send
        self.queue = queue
        self.interrupt = interrupt
        self.resume = resume
        self.usageSignals = usageSignals
        self.midTurnInput = midTurnInput
        self.models = models
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        structuredStream = try c.decodeIfPresent(Bool.self, forKey: .structuredStream) ?? false
        send = try c.decodeIfPresent(Bool.self, forKey: .send) ?? false
        queue = try c.decodeIfPresent(Bool.self, forKey: .queue) ?? false
        interrupt = try c.decodeIfPresent(Bool.self, forKey: .interrupt) ?? false
        resume = try c.decodeIfPresent(Bool.self, forKey: .resume) ?? false
        usageSignals = try c.decodeIfPresent(Bool.self, forKey: .usageSignals) ?? false
        midTurnInput = try c.decodeIfPresent(Bool.self, forKey: .midTurnInput)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

public struct Machine: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var host: String?
    public var port: Int?
    public var user: String?
    public var workdir: String?
    public var harnesses: [String: HarnessCapabilities]
    public var status: String?
    public var lastCheckedAt: Double?
    public var lastError: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
        harnesses = try c.decodeIfPresent([String: HarnessCapabilities].self, forKey: .harnesses) ?? [:]
        status = try c.decodeIfPresent(String.self, forKey: .status)
        lastCheckedAt = try c.decodeIfPresent(Double.self, forKey: .lastCheckedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    public var isReachable: Bool { status != "unreachable" }
}

public struct Repo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var machineIds: [String]?
    public var defaultBranch: String?
}

public struct UsageBlock: Codable, Hashable, Sendable {
    public var kind: String?
    public var source: String?
    public var message: String?
    public var resetsAt: Double?
    public var at: Double?
}

public struct PendingPermission: Codable, Hashable, Sendable {
    public var requestId: String
    public var tool: String
    public var command: String?
    public var input: JSONValue?
    public var title: String?
    public var at: Double?
}

public struct RunStats: Codable, Hashable, Sendable {
    public var tokens: Double?
    public var context: Double?
    public var input: Double?
    public var output: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var toolUses: Double?
    public var activity: String?
    public var workedMs: Double?
    public var turnStartedAt: Double?
    public var lastAt: Double?
}

/// `RunView` = `Run & RunExtras`: a run row as every route returns it.
public struct Run: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String?
    public var machineId: String
    public var harness: String
    public var model: String?
    public var cwd: String?
    public var branch: String?
    public var sessionId: String?
    public var status: RunStatus
    public var title: String?
    public var origin: String?
    public var usageBlock: UsageBlock?
    public var exitCode: Int?
    public var error: String?
    public var createdAt: Double
    public var updatedAt: Double?
    public var endedAt: Double?
    public var turnOpen: Bool
    public var queued: Int
    public var holdPermissions: Bool?
    public var pendingPermission: PendingPermission?
    // RunExtras
    public var costUsd: Double?
    public var permissionMode: String?
    public var effort: String?
    public var resumeOf: String?
    public var source: String?
    public var agentLog: String?
    public var retries: Int?
    public var stats: RunStats?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId) ?? ""
        harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? "claude"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        status = try c.decodeIfPresent(RunStatus.self, forKey: .status) ?? .unknown
        title = try c.decodeIfPresent(String.self, forKey: .title)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        usageBlock = try c.decodeIfPresent(UsageBlock.self, forKey: .usageBlock)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        endedAt = try c.decodeIfPresent(Double.self, forKey: .endedAt)
        turnOpen = try c.decodeIfPresent(Bool.self, forKey: .turnOpen) ?? false
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        holdPermissions = try c.decodeIfPresent(Bool.self, forKey: .holdPermissions)
        pendingPermission = try c.decodeIfPresent(PendingPermission.self, forKey: .pendingPermission)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        resumeOf = try c.decodeIfPresent(String.self, forKey: .resumeOf)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        agentLog = try c.decodeIfPresent(String.self, forKey: .agentLog)
        retries = try c.decodeIfPresent(Int.self, forKey: .retries)
        stats = try c.decodeIfPresent(RunStats.self, forKey: .stats)
    }

    /// ended = a final status, or an end time (web/src/chat/controls.ts).
    public var isEnded: Bool { status.isEnded || endedAt != nil }
    public var isExternal: Bool { origin == "external" }
    /// Working now, or blocked on the human.
    public var isActive: Bool { !isEnded }
    public var needsYou: Bool { pendingPermission != nil || status == .usageBlocked }
}

public struct RunEvent: Codable, Hashable, Sendable, Identifiable {
    public var runId: String?
    public var seq: Int
    public var at: Double
    public var type: String
    public var agent: String?
    public var data: [String: JSONValue]

    public var id: Int { seq }

    public init(runId: String? = nil, seq: Int, at: Double = 0, type: String, agent: String? = nil, data: [String: JSONValue] = [:]) {
        self.runId = runId
        self.seq = seq
        self.at = at
        self.type = type
        self.agent = agent
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        data = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .data)) ?? [:]
    }
}

/// Streamed text of a block still being written; the finished event replaces it.
public struct RunDelta: Codable, Hashable, Sendable {
    public var key: String
    public var kind: String
    public var text: String
    public var agent: String?

    public init(key: String, kind: String = "text", text: String, agent: String? = nil) {
        self.key = key
        self.kind = kind
        self.text = text
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
    }
}

public struct Actor: Codable, Hashable, Sendable {
    public var kind: String
    public var id: String?
    public var name: String?
    public var scopes: [String]
    public var repos: [String]?
    public var machines: [String]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "token"
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        repos = try c.decodeIfPresent([String].self, forKey: .repos)
        machines = try c.decodeIfPresent([String].self, forKey: .machines)
    }

    /// The scopes this app needs: read runs, steer them, start them.
    public static let neededScopes = ["runs:read", "runs:control", "runs:spawn"]
    public var isAdmin: Bool { kind == "admin" }
    public func has(_ scope: String) -> Bool { isAdmin || scopes.contains(scope) }
    public var missingScopes: [String] { Actor.neededScopes.filter { !has($0) } }
}

public struct SessionAgent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String?
    public var description: String?
    public var prompt: String?
    public var toolUseId: String?
    public var model: String?
    public var toolUses: Int?
    public var tokens: Double?
    public var startedAt: Double?
    public var lastAt: Double?
    public var state: String?
    public var activity: String?
    public var activityLabel: String?
    public var result: String?

    public var isRunning: Bool { state == "running" }
}

public struct SessionTranscript: Codable, Hashable, Sendable {
    public struct AgentInfo: Codable, Hashable, Sendable {
        public var id: String
        public var type: String?
        public var chatTitle: String?
    }

    public var machineId: String?
    public var sessionId: String?
    public var title: String?
    public var agent: AgentInfo?
    public var active: Bool?
    public var model: String?
    public var events: [RunEvent]
    public var truncated: Bool?
}

public struct MachineHarnesses: Codable, Hashable, Sendable, Identifiable {
    public var machineId: String
    public var name: String
    public var harnesses: [String: HarnessCapabilities]
    public var id: String { machineId }
}

// ---- response envelopes

public struct MeResponse: Codable, Sendable { public var actor: Actor; public var network: Bool? }
public struct MachinesResponse: Codable, Sendable { public var machines: [Machine] }
public struct ReposResponse: Codable, Sendable { public var repos: [Repo] }
public struct RunsResponse: Codable, Sendable { public var runs: [Run] }
public struct RunResponse: Codable, Sendable { public var run: Run }
public struct SendResponse: Codable, Sendable { public var run: Run; public var queued: Bool? }
public struct HarnessesResponse: Codable, Sendable { public var machines: [MachineHarnesses] }
public struct AgentsResponse: Codable, Sendable { public var agents: [SessionAgent] }

public struct RunDetail: Codable, Sendable {
    public var run: Run
    public var capabilities: HarnessCapabilities?
}

public struct TranscriptPage: Codable, Sendable {
    public var events: [RunEvent]
    public var next: Int?
    public var total: Int?
}

/// POST /api/runs body.
public struct NewRun: Codable, Hashable, Sendable {
    public var machineId: String
    public var harness: String
    public var model: String?
    public var cwd: String?
    public var repoId: String?
    public var prompt: String
    public var title: String?
    public var permissionMode: String?
    public var effort: String?
    public var holdPermissions: Bool?

    public init(machineId: String, harness: String, model: String? = nil, cwd: String? = nil, repoId: String? = nil, prompt: String, title: String? = nil, permissionMode: String? = nil, effort: String? = nil, holdPermissions: Bool? = nil) {
        self.machineId = machineId
        self.harness = harness
        self.model = model
        self.cwd = cwd
        self.repoId = repoId
        self.prompt = prompt
        self.title = title
        self.permissionMode = permissionMode
        self.effort = effort
        self.holdPermissions = holdPermissions
    }

    public static let permissionModes = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
}

public enum PermissionDecision: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowTool = "allow_tool"
    case deny
}
