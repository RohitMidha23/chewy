import Foundation

// MARK: - Usage model

/// A single usage window (e.g. the rolling five-hour or seven-day limit) reported
/// by the provider's usage endpoint.
public struct UsageWindow: Equatable, Sendable, Codable {
    /// Human label for the window, normalized for display ("5-hour", "7-day", or the
    /// raw key when unknown).
    public let label: String
    /// How much of this window's limit is consumed, as a percentage 0...100.
    public let usedPercent: Double
    /// When this window's limit resets, if the provider reported it.
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A snapshot of the active account's usage across all reported windows, plus
/// extra-usage state. Note the distinction the provider draws:
/// - extra usage credits "cover you when you hit your plan limits" — you only pay
///   API rates once a window is exhausted (`inOverageNow`);
/// - `extraSpendThisCycle` is the CUMULATIVE amount spent this billing cycle — info,
///   not a "right now" alarm.
public struct UsageSnapshot: Equatable, Sendable, Codable {
    public let windows: [UsageWindow]
    /// Whether the account *can* use paid credits past its limits (a setting).
    public let extraUsageEnabled: Bool
    /// Cumulative paid-overage spend this billing cycle, if reported (dollars).
    public let extraSpendThisCycle: Double?
    /// The provider's own severity for spend ("normal" | escalated).
    public let severity: String?

    public init(
        windows: [UsageWindow],
        extraUsageEnabled: Bool = false,
        extraSpendThisCycle: Double? = nil,
        severity: String? = nil
    ) {
        self.windows = windows
        self.extraUsageEnabled = extraUsageEnabled
        self.extraSpendThisCycle = extraSpendThisCycle
        self.severity = severity
    }

    /// The highest utilization across all windows — the one to warn on.
    public var peakPercent: Double {
        windows.map(\.usedPercent).max() ?? 0
    }

    /// The window that drives `peakPercent` (the most-consumed one).
    public var peakWindow: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// The 5-hour (session) window specifically — the one users think in terms of.
    public var fiveHourWindow: UsageWindow? {
        windows.first { $0.label == "5-hour" }
    }

    /// The hottest 7-day window (plain, Opus, apps…) — the weekly budget that
    /// keeps an account useless even after its 5-hour window resets.
    public var weeklyWindow: UsageWindow? {
        windows.filter { $0.label.hasPrefix("7-day") }
            .max { $0.usedPercent < $1.usedPercent }
    }

    /// Whether the account is paying API rates RIGHT NOW: extra usage is enabled AND
    /// a plan window is exhausted (or the provider escalated severity). This — not
    /// cumulative spend — is what should trigger the red "extra usage" alert.
    public var inOverageNow: Bool {
        guard extraUsageEnabled else { return false }
        if let severity, severity != "normal" { return true }
        return peakPercent >= 100
    }
}

// MARK: - Fetching abstraction

/// Abstraction over the usage HTTP call so the poller is testable without network.
/// Implementations MUST NOT log the access token or the response body.
public protocol UsageFetching: Sendable {
    func fetchClaude(accessToken: String) async -> UsageSnapshot?
}

// TODO: Codex usage (secondary, best-effort). Codex writes per-session rollout
// logs under `~/.codex/sessions/**/rollout-*.jsonl`; the most recent `event_msg`
// line with `payload.type == "token_count"` carries `payload.rate_limits`
// (`used_percent`, `rate_limit_reached_type`) — parse that and surface it as a
// UsageSnapshot.
// Deliberately deferred: it requires globbing nested dated session dirs and
// reverse-scanning JSONL (without spawning codex). Claude proactive polling is the
// priority and is fully wired. Do NOT spawn codex processes when implementing this.

// MARK: - Parsing + fetching

public enum UsageMonitor {
    /// Friendly labels for the windows Claude reports. Unknown keys fall through to
    /// a lightly cleaned version of the raw key.
    private static let windowLabels: [String: String] = [
        "five_hour": "5-hour",
        "seven_day": "7-day",
        "seven_day_opus": "7-day (Opus)",
        "seven_day_oauth_apps": "7-day (apps)"
    ]

    /// Pure, defensive parser for Claude's `GET /api/oauth/usage` response.
    ///
    /// The response shape varies; we look for any object whose values look like a
    /// usage window (carry a `utilization`/`used`/`used_percent` number, optionally
    /// with `resets_at`). Utilization is normalized to 0...100 whether the provider
    /// reports a 0...1 fraction or a 0...100 percentage. Returns nil when nothing
    /// window-shaped is found.
    ///
    /// Never logs the response body.
    public static func parseClaudeUsage(_ data: Data) -> UsageSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }

        // Windows usually live at the top level keyed by name; some shapes nest them
        // under a "usage"/"windows"/"limits" container. Search both.
        var containers: [[String: Any]] = [root]
        for key in ["usage", "windows", "limits", "rate_limits"] {
            if let nested = root[key] as? [String: Any] {
                containers.append(nested)
            }
        }

        // These keys carry spend/overage state, not rate-limit windows — handled
        // separately below so they don't masquerade as 0%-utilization windows.
        let nonWindowKeys: Set<String> = ["spend", "extra_usage"]

        var windows: [UsageWindow] = []
        var seenLabels = Set<String>()
        for container in containers {
            for (key, value) in container {
                guard !nonWindowKeys.contains(key) else { continue }
                guard let dict = value as? [String: Any] else { continue }
                guard let percent = utilizationPercent(from: dict) else { continue }
                let label = windowLabels[key] ?? prettify(key)
                guard seenLabels.insert(label).inserted else { continue }
                windows.append(
                    UsageWindow(
                        label: label,
                        usedPercent: percent,
                        resetsAt: resetDate(from: dict)
                    )
                )
            }
        }

        let extra = parseExtraUsage(root)

        // Return a snapshot if we found ANY signal (windows or extra-usage state).
        guard !windows.isEmpty || extra.enabled || extra.dollars != nil else { return nil }
        // Stable order: hottest first.
        windows.sort { $0.usedPercent > $1.usedPercent }
        return UsageSnapshot(
            windows: windows,
            extraUsageEnabled: extra.enabled,
            extraSpendThisCycle: extra.dollars,
            severity: extra.severity
        )
    }

    /// Extract extra-usage state: `extra_usage.is_enabled` (a setting), the CUMULATIVE
    /// cycle spend (`spend.used` minor units, or `extra_usage.used_credits` cents), and
    /// the provider's `spend.severity`. None of these alone means "in overage now" —
    /// see `UsageSnapshot.inOverageNow`.
    private static func parseExtraUsage(_ root: [String: Any]) -> (enabled: Bool, dollars: Double?, severity: String?) {
        var dollars: Double?
        var severity: String?

        if let spend = root["spend"] as? [String: Any] {
            severity = spend["severity"] as? String
            if let used = spend["used"] as? [String: Any],
               let minor = (used["amount_minor"] as? NSNumber)?.doubleValue {
                let exponent = (used["exponent"] as? NSNumber)?.doubleValue ?? 2
                dollars = minor / pow(10, exponent)
            }
        }

        let extra = root["extra_usage"] as? [String: Any]
        let enabled = (extra?["is_enabled"] as? NSNumber)?.boolValue ?? false
        if dollars == nil, let credits = (extra?["used_credits"] as? NSNumber)?.doubleValue {
            dollars = credits / 100.0
        }

        return (enabled, dollars, severity)
    }

    /// Pull a utilization value out of a window dict and normalize it to 0...100.
    private static func utilizationPercent(from dict: [String: Any]) -> Double? {
        let candidateKeys = ["utilization", "used_percent", "usedPercent", "percent", "used"]
        var raw: Double?
        for key in candidateKeys {
            if let number = dict[key] as? NSNumber {
                raw = number.doubleValue
                break
            }
            if let string = dict[key] as? String, let parsed = Double(string) {
                raw = parsed
                break
            }
        }
        guard let value = raw, value.isFinite, value >= 0 else { return nil }
        // Normalize 0...1 fractions to a percentage; leave 0...100 values as-is.
        let percent = value <= 1.0 ? value * 100.0 : value
        return min(percent, 100.0)
    }

    /// Parse `resets_at` (ISO-8601 string, or epoch seconds number) if present.
    private static func resetDate(from dict: [String: Any]) -> Date? {
        let candidateKeys = ["resets_at", "resetsAt", "reset_at", "reset"]
        for key in candidateKeys {
            if let string = dict[key] as? String {
                if let date = iso8601.date(from: string) { return date }
                if let date = iso8601NoFraction.date(from: string) { return date }
                if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            }
            if let number = dict[key] as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
        }
        return nil
    }

    // Read-only after configuration; ISO8601DateFormatter's parse methods are
    // safe to call concurrently, so opt these out of strict global-actor checks.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Turn an unknown snake_case window key into a readable label.
    private static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Compact "time until reset" for a window, e.g. "2h", "45m", "3d", or "now".
    /// nil when there's no reset time. Compact reset countdowns for menu display.
    public static func shortTimeUntil(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = Int(seconds / 3600)
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - Live fetcher

/// Live `UsageFetching` backed by URLSession. Calls Claude's OAuth usage endpoint
/// with a 10s timeout. NEVER logs the access token or the response body.
public struct LiveUsageFetcher: UsageFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchClaude(accessToken: String) async -> UsageSnapshot? {
        guard !accessToken.isEmpty,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Never log status detail with the body; a nil keeps the prior value.
                return nil
            }
            return UsageMonitor.parseClaudeUsage(data)
        } catch {
            // Swallow — the caller keeps the prior snapshot. Never log the error body.
            return nil
        }
    }
}
