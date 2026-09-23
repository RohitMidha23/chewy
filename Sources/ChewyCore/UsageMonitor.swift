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
    /// Codex usage for a ChatGPT-backed sign-in. `accountId` is the ChatGPT account
    /// id from `auth.json` (`tokens.account_id`), sent as `chatgpt-account-id`.
    func fetchCodex(accessToken: String, accountId: String) async -> UsageSnapshot?
}

public extension UsageFetching {
    func fetchCodex(accessToken: String, accountId: String) async -> UsageSnapshot? { nil }
}

// MARK: - Parsing + fetching

public enum UsageMonitor {
    /// Friendly labels for the windows Claude reports. Unknown keys fall through to
    /// a lightly cleaned version of the raw key.
    private static let windowLabels: [String: String] = [
        "five_hour": "5-hour",
        "seven_day": "7-day",
        "seven_day_opus": "7-day (Opus)",
        "seven_day_sonnet": "7-day (Sonnet)",
        "seven_day_oauth_apps": "7-day (apps)"
    ]

    /// Parser for Claude's `GET /api/oauth/usage` response.
    ///
    /// The current response carries a structured `limits` array —
    /// `[{kind: "session"|"weekly_all"|"weekly_scoped"|…, percent, resets_at,
    /// scope: {model: {display_name}}}]` — alongside the older named top-level
    /// windows (`five_hour`, `seven_day`, `seven_day_opus`, …). We read BOTH, the
    /// array first, deduping by display label, and ignore unknown top-level keys
    /// (the endpoint also emits experimental feature buckets such as
    /// `nimbus_quill` that must never drive the meter or the switcher).
    ///
    /// Utilization values are PERCENTAGES (0…100) — the API has always reported
    /// them that way and the CLI displays them verbatim. They are never rescaled:
    /// an earlier "0…1 means a fraction" heuristic turned a genuine 1% into 100%
    /// and fired spurious limit-reached switches right after a window reset.
    ///
    /// Returns nil when nothing window-shaped (and no extra-usage state) is found.
    /// Never logs the response body.
    public static func parseClaudeUsage(_ data: Data) -> UsageSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }

        var windows: [UsageWindow] = []
        var seenLabels = Set<String>()
        func add(label: String, percent: Double, resetsAt: Date?) {
            guard seenLabels.insert(label).inserted else { return }
            windows.append(UsageWindow(label: label, usedPercent: percent, resetsAt: resetsAt))
        }

        // 1. Structured `limits` array (current shape).
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = utilizationPercent(from: limit) else { continue }
                add(label: limitLabel(kind: kind, limit: limit),
                    percent: percent,
                    resetsAt: resetDate(from: limit))
            }
        }

        // 2. Known named windows at the top level (or under a legacy container).
        var containers: [[String: Any]] = [root]
        for key in ["usage", "windows", "rate_limits"] {
            if let nested = root[key] as? [String: Any] {
                containers.append(nested)
            }
        }
        for container in containers {
            for (key, label) in windowLabels {
                guard let dict = container[key] as? [String: Any],
                      let percent = utilizationPercent(from: dict) else { continue }
                add(label: label, percent: percent, resetsAt: resetDate(from: dict))
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

    /// Display label for a `limits[]` entry. `session` is the 5-hour window;
    /// `weekly_all` the plain 7-day budget; `weekly_scoped` a per-model 7-day cap
    /// (labelled with the model's display name so it sorts with the other 7-day
    /// windows via the "7-day" prefix). Unknown kinds fall back to their group.
    static func limitLabel(kind: String, limit: [String: Any]) -> String {
        switch kind {
        case "session":
            return "5-hour"
        case "weekly_all":
            return "7-day"
        case "weekly_scoped":
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String) ?? (model?["id"] as? String)
            if let name, !name.isEmpty { return "7-day (\(name))" }
            return "7-day (scoped)"
        default:
            switch limit["group"] as? String {
            case "session": return "5-hour"
            case "weekly": return "7-day (\(prettify(kind)))"
            default: return prettify(kind)
            }
        }
    }

    // MARK: Codex

    /// Parser for the ChatGPT backend's Codex usage response
    /// (`GET https://chatgpt.com/backend-api/wham/usage`, the same call the Codex CLI
    /// makes for `/status`). Shape:
    /// `rate_limit.primary_window` / `secondary_window` = `{used_percent,
    /// limit_window_seconds, reset_at}`, plus `rate_limit_reached_type`, and
    /// `credits.{has_credits, overage_limit_reached}`. Windows are labelled by their
    /// length (18000s → "5-hour", 604800s → "7-day") so the planner's 5-hour /
    /// weekly logic applies unchanged. Never logs the body.
    public static func parseCodexUsage(_ data: Data) -> UsageSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let rateLimit = root["rate_limit"] as? [String: Any]
        else {
            return nil
        }

        var windows: [UsageWindow] = []
        for (key, fallback) in [("primary_window", "5-hour"), ("secondary_window", "7-day")] {
            guard let window = rateLimit[key] as? [String: Any],
                  let percent = utilizationPercent(from: window) else { continue }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.doubleValue
            windows.append(
                UsageWindow(
                    label: codexWindowLabel(seconds: seconds, fallback: fallback),
                    usedPercent: percent,
                    resetsAt: resetDate(from: window)
                )
            )
        }
        guard !windows.isEmpty else { return nil }

        let credits = root["credits"] as? [String: Any]
        let hasCredits = (credits?["has_credits"] as? NSNumber)?.boolValue ?? false
        let unlimited = (credits?["unlimited"] as? NSNumber)?.boolValue ?? false
        let overageReached = (credits?["overage_limit_reached"] as? NSNumber)?.boolValue ?? false
        let reachedType = (root["rate_limit_reached_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        windows.sort { $0.usedPercent > $1.usedPercent }
        // Credits are Codex's "extra usage": with credits, a reached limit means the
        // account is now burning credits — the same red state as Claude's overage.
        return UsageSnapshot(
            windows: windows,
            extraUsageEnabled: hasCredits || unlimited,
            extraSpendThisCycle: nil,
            severity: overageReached ? "overage_limit_reached" : reachedType
        )
    }

    /// "5-hour" / "7-day" style label for a Codex window length in seconds.
    static func codexWindowLabel(seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        if seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400))-day"
        }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600))-hour"
        }
        return "\(Int(seconds / 60))-minute"
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

    /// Pull a utilization PERCENTAGE (0…100) out of a window/limit dict. Values are
    /// clamped to 0…100 and never rescaled — see `parseClaudeUsage`.
    private static func utilizationPercent(from dict: [String: Any]) -> Double? {
        let candidateKeys = ["utilization", "used_percent", "usedPercent", "percent"]
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
        return min(value, 100.0)
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
/// and the ChatGPT backend's Codex usage endpoint with a 10s timeout. NEVER logs the
/// access token or the response body.
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
                // Status code only — never the body. A nil keeps the prior value.
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ChewyLog.warn("usage fetch failed: HTTP \(code)")
                return nil
            }
            guard let snapshot = UsageMonitor.parseClaudeUsage(data) else {
                ChewyLog.warn("usage fetch: HTTP \(http.statusCode) but no usage windows recognised (\(data.count) bytes)")
                return nil
            }
            return snapshot
        } catch {
            // Swallow — the caller keeps the prior snapshot. Log the error class only.
            ChewyLog.warn("usage fetch error: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    public func fetchCodex(accessToken: String, accountId: String) async -> UsageSnapshot? {
        guard !accessToken.isEmpty, !accountId.isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs/0.154.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ChewyLog.warn("codex usage fetch failed: HTTP \(code)")
                return nil
            }
            guard let snapshot = UsageMonitor.parseCodexUsage(data) else {
                ChewyLog.warn("codex usage fetch: HTTP \(http.statusCode) but no rate_limit windows recognised (\(data.count) bytes)")
                return nil
            }
            return snapshot
        } catch {
            ChewyLog.warn("codex usage fetch error: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }
}
