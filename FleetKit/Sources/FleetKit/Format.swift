import Foundation

/// Labels as the web app and CLI draw them (server/run-line.ts).
public enum Format {
    public static func harnessName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "pi": "Pi"
        default: harness
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "opus" -> "Opus (latest)"; other ids stay as they are.
    public static func modelLabel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Default model" }
        let pattern = #"^(?:claude-)?(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)) {
            func group(_ i: Int) -> String? {
                guard let range = Range(match.range(at: i), in: model) else { return nil }
                return String(model[range])
            }
            let family = (group(1) ?? "").lowercased().capitalized
            var label = "\(family) \(group(2) ?? "")"
            if let minor = group(3) { label += ".\(minor)" }
            if group(4) != nil { label += " 1M" }
            return label
        }
        if ["opus", "sonnet", "haiku", "fable"].contains(model.lowercased()) { return "\(model.lowercased().capitalized) (latest)" }
        return model
    }

    /// 530 -> "8m 50s", 3 -> "3s", 3900 -> "1h 5m".
    public static func duration(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// 950 -> "950", 272_480 -> "272.5k", 1_250_000 -> "1.3M".
    public static func tokenCount(_ n: Double) -> String {
        let value = max(0, Int(n.rounded()))
        func trim(_ text: String) -> String { text.hasSuffix(".0") ? String(text.dropLast(2)) : text }
        if value < 1000 { return String(value) }
        if value < 999_950 { return trim(String(format: "%.1f", Double(value) / 1000)) + "k" }
        return trim(String(format: "%.1f", Double(value) / 1_000_000)) + "M"
    }

    public static func queuedText(_ n: Int) -> String { "\(n) queued message\(n == 1 ? "" : "s")" }

    /// Time a run has spent working: its finished turns plus the open one so far (ms).
    public static func elapsedMs(_ stats: RunStats, now: Double) -> Double {
        (stats.workedMs ?? 0) + (stats.turnStartedAt.map { max(0, now - $0) } ?? 0)
    }

    /// "Claude Code · 54m 19s · Opus 5.5 · 272.5k tokens · 110 tool uses · Running a command".
    /// Activity shows only while the run's process is alive.
    public static func runLine(_ run: Run, now: Double = Date().timeIntervalSince1970 * 1000, label: Bool = true) -> String {
        var out: [String] = []
        if label { out.append(harnessName(run.harness)) }
        if let stats = run.stats { out.append(duration(seconds: elapsedMs(stats, now: now) / 1000)) }
        out.append(modelLabel(run.model))
        if let tokens = run.stats?.tokens, tokens > 0 { out.append("\(tokenCount(tokens)) tokens") }
        let tools = Int(run.stats?.toolUses ?? 0)
        out.append("\(tools) tool use\(tools == 1 ? "" : "s")")
        if run.endedAt == nil, let activity = run.stats?.activity, !activity.isEmpty { out.append(activity) }
        return out.joined(separator: " · ")
    }

    /// "now", "5m", "3h", "2d": how long ago a ms timestamp was.
    public static func ago(_ ms: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let s = max(0, (now - ms) / 1000)
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// "/Users/porter/code/fleet" -> "fleet".
    public static func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
