import Foundation

public enum FleetError: LocalizedError, Equatable, Sendable {
    case badURL
    case unauthorized(String)
    /// 409: the harness can't do this (a missing capability) or the run's state forbids it.
    case conflict(String)
    case http(Int, String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "That server URL doesn't look right."
        case .unauthorized(let message): message.isEmpty ? "The token was refused." : message
        case .conflict(let message): message
        case .http(let code, let message): message.isEmpty ? "The server answered \(code)." : message
        case .decoding(let message): "Unexpected reply from the server: \(message)"
        case .transport(let message): message
        }
    }

    /// Readable text for a URLSession failure, with the fix for the common ones.
    static func from(_ error: Error) -> FleetError {
        if let fleet = error as? FleetError { return fleet }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorSecureConnectionFailed:
                return .transport("The server's certificate isn't trusted. Install Caddy's root CA and turn it on in Settings > General > About > Certificate Trust Settings.")
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet:
                return .transport("Can't reach the server. Is Tailscale on, or are you on the same network? (\(ns.localizedDescription))")
            default: break
            }
        }
        return .transport(error.localizedDescription)
    }
}

/// The Fleet HTTP API (docs/api.md): bearer auth, JSON in and out, `{error}` on failure.
public struct FleetClient: Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Normalizes what a person types: adds https:// when no scheme is given, drops a trailing slash.
    public static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    // ---- reads

    public func me() async throws -> MeResponse { try await get("/api/me") }
    public func machines() async throws -> [Machine] { try await (get("/api/machines") as MachinesResponse).machines }
    public func repos() async throws -> [Repo] { try await (get("/api/repos") as ReposResponse).repos }
    public func harnesses() async throws -> [MachineHarnesses] { try await (get("/api/harnesses") as HarnessesResponse).machines }

    public func runs(status: String? = nil, machineId: String? = nil, limit: Int = 200) async throws -> [Run] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let machineId { query.append(URLQueryItem(name: "machineId", value: machineId)) }
        return try await (get("/api/runs", query: query) as RunsResponse).runs
    }

    public func run(_ id: String) async throws -> RunDetail { try await get("/api/runs/\(id)") }

    public func transcript(_ id: String, after: Int? = nil, limit: Int = 200, types: [String]? = nil, maxChars: Int? = 20_000) async throws -> TranscriptPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let types { query.append(URLQueryItem(name: "types", value: types.joined(separator: ","))) }
        if let maxChars { query.append(URLQueryItem(name: "maxChars", value: String(maxChars))) }
        return try await get("/api/runs/\(id)/transcript", query: query)
    }

    public func agents(sessionId: String, machineId: String) async throws -> [SessionAgent] {
        try await (get("/api/sessions/\(sessionId)/agents", query: [URLQueryItem(name: "machineId", value: machineId)]) as AgentsResponse).agents
    }

    public func agentTranscript(sessionId: String, machineId: String, agentId: String, limit: Int = 400) async throws -> SessionTranscript {
        try await get("/api/sessions/\(sessionId)/transcript", query: [
            URLQueryItem(name: "machineId", value: machineId),
            URLQueryItem(name: "agent", value: agentId),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    // ---- actions

    public func spawn(_ body: NewRun) async throws -> Run { try await (post("/api/runs", body: body) as RunResponse).run }

    /// mode "auto" sends now when the harness takes mid-turn input, else queues; "queue" always waits for the turn to end.
    public func send(_ id: String, text: String, mode: String) async throws -> SendResponse {
        try await post("/api/runs/\(id)/send", body: ["text": text, "mode": mode])
    }

    public func interrupt(_ id: String) async throws -> Run { try await (post("/api/runs/\(id)/interrupt", body: [String: String]()) as RunResponse).run }
    public func stop(_ id: String) async throws -> Run { try await (post("/api/runs/\(id)/stop", body: [String: String]()) as RunResponse).run }
    public func restart(_ id: String) async throws -> Run { try await (post("/api/runs/\(id)/restart", body: [String: String]()) as RunResponse).run }

    public func respond(_ id: String, decision: PermissionDecision, message: String? = nil) async throws -> Run {
        var body = ["decision": decision.rawValue]
        if let message, !message.isEmpty { body["message"] = message }
        return try await (post("/api/runs/\(id)/respond", body: body) as RunResponse).run
    }

    // ---- the live stream

    /// GET /api/runs/:id/stream as typed messages. With no `after` the server
    /// replays the newest 200 events first; pass the last seq seen to resume.
    /// Ends when the connection drops (the server keeps it open even after the run ends).
    public func stream(_ id: String, after: Int?) -> AsyncThrowingStream<RunStreamMessage, Error> {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        let request: URLRequest
        do {
            var built = try makeRequest("/api/runs/\(id)/stream", query: query)
            built.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            built.timeoutInterval = 60 // the server pings every 15 s
            request = built
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 4096 { break } }
                        throw Self.failure(status: http.statusCode, body: body)
                    }
                    var lines = LineSplitter()
                    var parser = SSEParser()
                    let decoder = JSONDecoder()
                    for try await byte in bytes {
                        guard let line = lines.push(byte) else { continue }
                        if let message = parser.push(line: line), let decoded = RunStreamMessage.decode(message, decoder: decoder) {
                            continuation.yield(decoded)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: FleetError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // ---- plumbing

    private func makeRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw FleetError.badURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FleetError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await perform(makeRequest(path, query: query))
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FleetError.from(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.failure(status: http.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FleetError.decoding(String(describing: error))
        }
    }

    static func failure(status: Int, body: Data) -> FleetError {
        struct Body: Decodable { var error: String? }
        let message = (try? JSONDecoder().decode(Body.self, from: body))?.error ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401, 403: return .unauthorized(message)
        case 409: return .conflict(message)
        default: return .http(status, message)
        }
    }
}
