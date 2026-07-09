import Foundation

/// Recommends the best Claude account to switch TO, given each account's usage.
///
/// The model: lower "effective utilization" is better. An account that is paying
/// paid overflow (extra usage) is worst. A drained 7-day window makes an account
/// nearly useless until its (distant) weekly reset — worse than any live account.
/// A 5-hour window that resets very soon is treated as nearly fresh — switching to
/// it buys a refresh in minutes. Accounts with unknown usage (idle >8h — their
/// 5-hour window has provably expired) are near-fresh; only their weekly budget is
/// a gamble. Pure and deterministic for testing.
public enum AccountAdvisor {
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let usage: UsageSnapshot?
        public init(id: UUID, usage: UsageSnapshot?) {
            self.id = id
            self.usage = usage
        }
    }

    public struct Recommendation: Equatable, Sendable {
        public let id: UUID
        public let reason: String
        public init(id: UUID, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    /// A window resetting within this many minutes counts as "about to refresh".
    static let resetSoonMinutes: Double = 30
    /// Score for an account whose usage we couldn't read (expired/missing token).
    /// Idle >8h means the 5-hour window truly expired — near-fresh, weekly unknown.
    static let unknownScore: Double = 25
    /// Minimum effective-utilization improvement (points) over the active account
    /// before we bother recommending a switch.
    static let improvementThreshold: Double = 15
    /// A 7-day window at/above this is "drained": the account stays walled until
    /// the weekly reset no matter what the 5-hour window does.
    public static let weeklyDrainedPercent: Double = 99.5
    /// Scores within this many points of the best count as a tie — broken by the
    /// LOWEST 7-day utilization, to stop grinding one account's weekly budget.
    static let tieEpsilon: Double = 8

    /// Recommend an account to switch to, or nil if staying put is fine.
    /// `candidates` should include the active account too (used for the comparison);
    /// it's excluded from being recommended.
    public static func recommend(candidates: [Candidate], activeId: UUID?, now: Date) -> Recommendation? {
        let switchable = candidates.filter { $0.id != activeId }
        guard !switchable.isEmpty else { return nil }

        // Best (lowest-score) account to switch to, weekly-aware tiebreak included.
        let bestIdx = bestIndex(usages: switchable.map(\.usage), now: now)!
        let best = switchable[bestIdx]
        let bestScore = switchable.map { score($0.usage, now: now) }.min()!

        // Compare to the active account (if any). Only recommend a switch when it's a
        // real improvement — don't nag when the current account is already fine.
        if let activeId, let active = candidates.first(where: { $0.id == activeId }) {
            let activeScore = score(active.usage, now: now)
            guard activeScore - bestScore >= improvementThreshold else { return nil }
        }

        return Recommendation(id: best.id, reason: reason(for: best.usage, now: now))
    }

    /// Index of the best entry (lowest score), with the 7-day-aware ε-tiebreak:
    /// among entries scoring within `tieEpsilon` of the best, pick the lowest 7-day
    /// utilization (unknown usage counts as weekly 55 — a gamble, not a win).
    public static func bestIndex(usages: [UsageSnapshot?], now: Date) -> Int? {
        guard !usages.isEmpty else { return nil }
        let scores = usages.map { score($0, now: now) }
        let bestScore = scores.min()!
        var pick = scores.firstIndex(of: bestScore)!
        var pickWeekly = weeklyPercentForTiebreak(usages[pick])
        for index in usages.indices where index != pick {
            guard scores[index] <= bestScore + tieEpsilon else { continue }
            let weekly = weeklyPercentForTiebreak(usages[index])
            if weekly < pickWeekly {
                pickWeekly = weekly
                pick = index
            }
        }
        return pick
    }

    static func weeklyPercentForTiebreak(_ usage: UsageSnapshot?) -> Double {
        guard let usage else { return 55 } // unknown weekly budget — a gamble
        return usage.weeklyWindow?.usedPercent ?? 0
    }

    /// Lower is better. Extra-usage dominates (1000+); a drained 7-day window is
    /// next-worst (400+, ordered by time to the weekly reset); otherwise effective
    /// utilization of the 5-hour window, discounted when it resets soon.
    public static func score(_ usage: UsageSnapshot?, now: Date) -> Double {
        guard let usage else { return unknownScore }
        if usage.inOverageNow { return 1000 + usage.peakPercent }
        if let weekly = usage.weeklyWindow, weekly.usedPercent >= weeklyDrainedPercent {
            // Weekly-drained: useless until the (possibly distant) weekly reset —
            // worse than any live account, better than paying overage.
            let minutesToReset = weekly.resetsAt.map { max(0, $0.timeIntervalSince(now) / 60) } ?? 100_000
            return 400 + min(minutesToReset, 100_000) / 60
        }
        if let fiveHour = usage.fiveHourWindow {
            return effectiveUtilization(fiveHour, now: now)
        }
        guard let window = usage.peakWindow else { return 0 } // no windows reported = fresh
        return effectiveUtilization(window, now: now)
    }

    /// Utilization adjusted for an imminent reset: a window at 90% that resets in 15
    /// minutes is effectively ~45% (15/30 of 90); one that reset 0 min ago is ~0%.
    static func effectiveUtilization(_ window: UsageWindow, now: Date) -> Double {
        guard let reset = window.resetsAt else { return window.usedPercent }
        let minutes = reset.timeIntervalSince(now) / 60
        guard minutes >= 0, minutes <= resetSoonMinutes else { return window.usedPercent }
        return window.usedPercent * (minutes / resetSoonMinutes)
    }

    static func reason(for usage: UsageSnapshot?, now: Date) -> String {
        guard let usage, let window = usage.peakWindow else {
            return usage == nil ? "usage unknown — likely fresh" : "fresh — nothing used"
        }
        if let reset = window.resetsAt {
            let minutes = reset.timeIntervalSince(now) / 60
            if minutes >= 0, minutes <= resetSoonMinutes {
                return "\(window.label) resets in \(max(1, Int(minutes.rounded())))m"
            }
        }
        let pct = Int(usage.peakPercent.rounded())
        return pct <= 1 ? "fresh — nothing used" : "most headroom — \(pct)% used"
    }
}
