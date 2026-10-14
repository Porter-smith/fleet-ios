import Foundation

/// Splits a byte stream into lines on LF, CRLF or a lone CR, keeping empty lines.
/// `URLSession.AsyncBytes.lines` drops empty lines, and SSE uses an empty line to
/// end each event, so the stream is split here instead.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var lastWasCR = false

    public init() {}

    /// Feeds one byte; returns a finished line when this byte ends one.
    public mutating func push(_ byte: UInt8) -> String? {
        if byte == 0x0A { // LF
            if lastWasCR { lastWasCR = false; return nil } // the LF of a CRLF
            return take()
        }
        if byte == 0x0D { // CR
            lastWasCR = true
            return take()
        }
        lastWasCR = false
        buffer.append(byte)
        return nil
    }

    /// Feeds a chunk; returns every line it finished.
    public mutating func push(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes { if let line = push(byte) { lines.append(line) } }
        return lines
    }

    /// The unterminated tail when the stream ends, if any.
    public mutating func finish() -> String? {
        buffer.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// One server-sent event.
public struct SSEMessage: Hashable, Sendable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// The SSE field rules (WHATWG "event stream interpretation"), fed one line at a time.
public struct SSEParser: Sendable {
    private var event = ""
    private var data: [String] = []
    private var id: String?

    public init() {}

    /// Feeds one line (without its terminator); returns an event when the line was the blank one ending it.
    public mutating func push(line: String) -> SSEMessage? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil } // a comment, e.g. ": open"
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break // retry and unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> SSEMessage? {
        defer { event = ""; data = [] }
        if data.isEmpty { return nil }
        return SSEMessage(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)
    }
}

/// What a run's stream carries (server/control/routes.ts: `run`, `event`, `delta`, plus `ping`).
public enum RunStreamMessage: Sendable {
    case run(Run)
    case event(RunEvent)
    case delta(RunDelta)
    case ping

    /// Decodes one SSE message; nil for one this build doesn't know or can't read.
    public static func decode(_ message: SSEMessage, decoder: JSONDecoder = JSONDecoder()) -> RunStreamMessage? {
        let data = Data(message.data.utf8)
        switch message.event {
        case "run": return (try? decoder.decode(Run.self, from: data)).map(RunStreamMessage.run)
        case "event": return (try? decoder.decode(RunEvent.self, from: data)).map(RunStreamMessage.event)
        case "delta": return (try? decoder.decode(RunDelta.self, from: data)).map(RunStreamMessage.delta)
        case "ping": return .ping
        default: return nil
        }
    }
}
