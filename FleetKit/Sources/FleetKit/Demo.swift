import Foundation

/// A Fleet server in a box: answers the API from the bundled fixtures in `Demo/`,
/// which are real responses captured from the Fleet dev server. The app runs on it
/// with the `-FleetDemo` launch argument (or "Try the demo" when pairing), so the
/// UI tests and screenshots need no server. Timestamps are moved so the newest run
/// was updated a minute ago.
public enum Demo {
    public static let baseURL = URL(string: "https://demo.fleet.invalid")!

    /// A client whose requests never leave the app.
    public static func client() -> FleetClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DemoURLProtocol.self]
        return FleetClient(baseURL: baseURL, token: "demo", session: URLSession(configuration: config))
    }

    /// A bundled fixture, e.g. `fixture("runs")` or `fixture("stream_live", "txt")`.
    public static func fixture(_ name: String, _ ext: String = "json") -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Demo") else { return nil }
        return try? Data(contentsOf: url)
    }

    // ---- the routes

    struct Reply {
        var status = 200
        var body: Data
        var stream = false
    }

    static func reply(method: String, path: String) -> Reply {
        let parts = path.split(separator: "/").map(String.init) // ["api", "runs", id, action]
        guard parts.first == "api", parts.count >= 2 else { return notFound }
        let route = Array(parts.dropFirst())
        let get = method == "GET"
        let id = route.count > 1 ? route[1] : ""
        let action = route.count > 2 ? route[2] : nil

        if route.count == 1 {
            if get, ["me", "machines", "repos", "harnesses", "runs"].contains(route[0]) { return json(route[0]) }
            if !get, route[0] == "runs" { return encode(["run": run(deployRun) ?? [:]]) } // spawn
            return notFound
        }
        if route[0] == "runs", route.count <= 3 {
            switch (get, action) {
            case (true, nil): return detail(id)
            case (true, "transcript"?):
                if id == deployRun { return json("transcript_subagent") }
                return encode(["events": [Any](), "next": NSNull(), "total": 0])
            case (true, "stream"?): return stream(id)
            case (false, "send"?): return encode(["run": run(id) ?? [:], "queued": true])
            case (false, .some): return encode(["run": run(id) ?? [:]]) // interrupt, stop, restart, respond
            default: return notFound
            }
        }
        if route[0] == "sessions", get, route.count == 3 {
            if action == "agents" {
                if id == run(deployRun)?["sessionId"] as? String { return json("agents") }
                return encode(["agents": [Any]()])
            }
            if action == "transcript" { return json("agent_transcript") }
        }
        return notFound
    }

    /// The run whose Agent call has a nested subagent, and the one mid-turn.
    static let deployRun = "r_8713f00693"
    static let busyRun = "r_f11275d79e"

    private static var notFound: Reply {
        Reply(status: 404, body: Data(#"{"error":"Not part of the demo."}"#.utf8))
    }

    private static func json(_ name: String) -> Reply {
        guard let data = fixture(name) else { return notFound }
        return Reply(body: shifted(data))
    }

    private static func encode(_ object: [String: Any]) -> Reply {
        Reply(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private static let runs: [[String: Any]] = {
        guard let data = fixture("runs"),
              let object = try? JSONSerialization.jsonObject(with: shifted(data)) as? [String: Any] else { return [] }
        return object["runs"] as? [[String: Any]] ?? []
    }()

    private static func run(_ id: String) -> [String: Any]? { runs.first { $0["id"] as? String == id } }

    /// GET /api/runs/:id: the captured detail where there is one, else the run with
    /// the Claude harness's capabilities.
    private static func detail(_ id: String) -> Reply {
        for name in ["run_detail", "run_detail_permission"] {
            if let data = fixture(name), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (object["run"] as? [String: Any])?["id"] as? String == id {
                return Reply(body: shifted(data))
            }
        }
        guard let run = run(id) else { return notFound }
        var capabilities: Any = NSNull()
        if let data = fixture("run_detail"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            capabilities = object["capabilities"] ?? NSNull()
        }
        return encode(["run": run, "capabilities": capabilities, "attempt": NSNull()])
    }

    /// GET /api/runs/:id/stream: the captured stream, held open like the server's.
    private static func stream(_ id: String) -> Reply {
        let name = id == deployRun ? "stream_subagent" : id == busyRun ? "stream_live" : nil
        if let name, let data = fixture(name, "txt"), let text = String(data: data, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard line.hasPrefix("data: ") else { return String(line) }
                let shiftedJSON = shifted(Data(line.dropFirst(6).utf8))
                return "data: " + (String(data: shiftedJSON, encoding: .utf8) ?? "")
            }
            return Reply(body: Data(lines.joined(separator: "\n").utf8), stream: true)
        }
        guard let run = run(id), let data = try? JSONSerialization.data(withJSONObject: run) else { return notFound }
        return Reply(body: Data(": open\n\nevent: run\ndata: ".utf8) + data + Data("\n\n".utf8), stream: true)
    }

    // ---- timestamps

    /// How far to move the captured times so the newest run is a minute old.
    private static let offset: Double = {
        guard let data = fixture("runs"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = object["runs"] as? [[String: Any]] else { return 0 }
        let newest = runs.compactMap { ($0["updatedAt"] as? NSNumber)?.doubleValue }.max() ?? 0
        guard newest > 0 else { return 0 }
        return (Date().timeIntervalSince1970 * 1000 - 60_000) - newest
    }()

    /// Moves every epoch-ms time (`at`, `createdAt`, `updatedAt`, ...) by `offset`.
    static func shifted(_ data: Data) -> Data {
        guard offset != 0, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        let moved = shift(object)
        return (try? JSONSerialization.data(withJSONObject: moved, options: [.fragmentsAllowed])) ?? data
    }

    private static func shift(_ value: Any, key: String? = nil) -> Any {
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { $0[$1.key] = shift($1.value, key: $1.key) }
        }
        if let array = value as? [Any] { return array.map { shift($0) } }
        if let key, key == "at" || key.hasSuffix("At"), let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 1e12 {
            return NSNumber(value: Int64(number.doubleValue + offset))
        }
        return value
    }
}

/// Serves `Demo` replies in place of the network. Streams send the captured
/// events and stay open until the app cancels them, like the real SSE route.
public final class DemoURLProtocol: URLProtocol {
    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let url = request.url else { return }
        let reply = Demo.reply(method: request.httpMethod ?? "GET", path: url.path)
        let type = reply.stream ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if !reply.stream { client?.urlProtocolDidFinishLoading(self) }
    }

    override public func stopLoading() {}
}
