import Foundation

/// What the background auto-switcher should do, given the current usage picture.
public enum AutoSwitchDecision: Equatable {
    /// Do nothing — the active account is fine, unmanaged, unknown, or we're cooling down.
    case stay
    /// Re-point new sessions at this account, announcing `reason`.
    case switchTo(id: UUID, reason: String)
    /// The active account is maxed but no account can be switched to.
    /// `allKnownMaxed == true` when other accounts exist but are all maxed/overage;
    /// `false` when no other account has readable usage.
    case noViableAccount(allKnownMaxed: Bool)
}

/// Everything the auto-switch decision needs — fully pure, so the model-level
/// behavior is testable without any AppKit/network plumbing.
public struct AutoSwitchInputs {
    /// Did the canonical credential resolve to a profile WE own? Never act blindly.
    public let activeIsManaged: Bool
    public let activeId: UUID?
    public let activeUsage: UsageSnapshot?
    /// The active account's sign-in is known-dead (post-swap heal reported
    /// signed-out). The planner must escape it immediately — usage is
    /// unreadable on a dead account, so the normal triggers can never fire.
    public let activeNeedsReconnect: Bool
    /// OTHER managed Claude accounts only (Codex is never passed in).
    public let candidates: [Candidate]
    /// For cooldown: when we last auto-switched, if ever.
    public let lastSwitchAt: Date?
    public let now: Date

    public struct Candidate: Equatable {
        public let id: UUID
        public let usage: UsageSnapshot?
        public init(id: UUID, usage: UsageSnapshot?) {
            self.id = id
            self.usage = usage
        }
    }

    public init(
        activeIsManaged: Bool,
        activeId: UUID?,
        activeUsage: UsageSnapshot?,
        activeNeedsReconnect: Bool = false,
        candidates: [Candidate],
        lastSwitchAt: Date?,
        now: Date
    ) {
        self.activeIsManaged = activeIsManaged
        self.activeId = activeId
        self.activeUsage = activeUsage
        self.activeNeedsReconnect = activeNeedsReconnect
        self.candidates = candidates
        self.lastSwitchAt = lastSwitchAt
        self.now = now
    }

    /// Build inputs from the model's live state. Candidates = `claudeProfiles` minus
    /// the active profile and minus `excluding` (accounts with a known-dead sign-in —
    /// switching onto one just produces a login prompt), mapped to their last-known
    /// usage. `activeIsManaged` is true iff the canonical identity resolved to a
    /// managed profile (`activeMatch != nil`).
    public static func build(
        activeMatch: AccountProfile?,
        claudeProfiles: [AccountProfile],
        usageByAccount: [UUID: UsageSnapshot],
        excluding: Set<UUID> = [],
        lastSwitchAt: Date?,
        now: Date
    ) -> AutoSwitchInputs {
        let activeId = activeMatch?.id
        let candidates = claudeProfiles
            .filter { $0.id != activeId && !excluding.contains($0.id) }
            .map { Candidate(id: $0.id, usage: usageByAccount[$0.id]) }
        return AutoSwitchInputs(
            activeIsManaged: activeMatch != nil,
            activeId: activeId,
            activeUsage: activeMatch.flatMap { usageByAccount[$0.id] },
            activeNeedsReconnect: activeId.map { excluding.contains($0) } ?? false,
            candidates: candidates,
            lastSwitchAt: lastSwitchAt,
            now: now
        )
    }
}

/// The only new logic: turns "the active account is walled (5-hour, weekly, or
/// paying overage) and account X has headroom" into a decision the model acts on.
/// Pure and fully testable.
public enum AutoSwitchPlanner {
    /// 5-hour utilization above this triggers a switch. 90 (not 95): with a fleet
    /// of parallel agents the window can burn >5% between 60-second polls, so a 95
    /// trigger often fires only after the wall is already hit — 90 buys new sessions
    /// a fresh account BEFORE running ones start erroring.
    public static let threshold = 90.0
    /// No second auto-switch within this window (anti-flap / anti-chain).
    public static let cooldown: TimeInterval = 180
    /// If the active 5-hour window resets within this, the wall lifts by itself —
    /// staying is cheaper than switching.
    static let imminentResetSeconds: TimeInterval = 120
    /// Candidates scoring at/above this are not worth switching onto: it means
    /// their own 5-hour window is effectively full (or worse — weekly/overage).
    static let viableScoreCeiling = 99.0
    /// A soft (5-hour threshold) switch must improve the effective score by at
    /// least this much — stops two near-threshold accounts from ping-ponging.
    static let switchImprovementMargin = 15.0
    /// Above this the 5-hour wall is effectively hit: switch to ANY viable
    /// candidate. Between `threshold` and this, we're in the early-warning band
    /// and only switch when the target is meaningfully fresher.
    static let hardWallPercent = 95.0

    public static func plan(_ i: AutoSwitchInputs) -> AutoSwitchDecision {
        // Gate: never act on an unmanaged active account.
        guard i.activeIsManaged else { return .stay }

        // DEAD SIGN-IN ESCAPE: the active account's credential is known-dead, so
        // its usage is unreadable and no usage trigger can ever fire — the switcher
        // would wedge here forever. Escape to the best viable candidate NOW:
        // no usage triggers, no cooldown (dead candidates are quarantined out of
        // `candidates`, so this cannot ping-pong).
        if i.activeNeedsReconnect {
            let viable = viableCandidates(i)
            if let best = bestViable(viable, now: i.now) {
                return .switchTo(id: best, reason: "the previous account's sign-in expired")
            }
            return .noViableAccount(allKnownMaxed: !i.candidates.isEmpty)
        }

        // Gate: only act when we can read the active account's usage.
        guard let active = i.activeUsage else { return .stay }
        let fivePercent = active.fiveHourWindow?.usedPercent ?? 0
        let weeklyDrained = (active.weeklyWindow?.usedPercent ?? 0) >= AccountAdvisor.weeklyDrainedPercent
        // Trigger: 5-hour wall, drained weekly budget, or live paid overage.
        guard fivePercent > threshold || weeklyDrained || active.inOverageNow else { return .stay }
        // Imminent-reset exception: the 5-hour wall is about to lift on its own,
        // and nothing longer-lived (weekly/overage) is keeping the account walled.
        if let reset = active.fiveHourWindow?.resetsAt,
           reset.timeIntervalSince(i.now) <= imminentResetSeconds,
           !weeklyDrained, !active.inOverageNow {
            return .stay
        }
        // Gate: cooldown after a recent switch.
        if let last = i.lastSwitchAt, i.now.timeIntervalSince(last) < cooldown {
            return .stay
        }

        let viable = viableCandidates(i)
        if let best = bestViable(viable, now: i.now) {
            let bestScore = viable.first(where: { $0.id == best })
                .map { AccountAdvisor.score($0.usage, now: i.now) } ?? .infinity
            if active.inOverageNow || weeklyDrained {
                // HARD wall (overage / drained weekly): always switch — staying is
                // strictly worse, and these accounts are non-viable as targets so
                // there is no ping-pong path back.
                return .switchTo(id: best, reason: switchReason(active: active, weeklyDrained: weeklyDrained))
            }
            if fivePercent <= hardWallPercent {
                // EARLY-WARNING band (threshold..hardWall]: switch only when the
                // target is meaningfully fresher — two accounts hovering near the
                // threshold would otherwise ping-pong every cooldown (the
                // simulation guard catches exactly this).
                let activeScore = AccountAdvisor.score(active, now: i.now)
                guard activeScore - bestScore >= switchImprovementMargin else { return .stay }
                return .switchTo(id: best, reason: switchReason(active: active, weeklyDrained: weeklyDrained))
            }
            // PAST the wall: take any target clear of the warning band. A target
            // that is ITSELF near the wall would re-trigger immediately (flap), so
            // for wall-to-wall situations fall through to ride-the-earliest-reset.
            if bestScore < threshold {
                return .switchTo(id: best, reason: switchReason(active: active, weeklyDrained: weeklyDrained))
            }
        }

        // No candidates at all → nothing to switch to.
        guard !i.candidates.isEmpty else { return .noViableAccount(allKnownMaxed: false) }

        // Every candidate is KNOWN to be walled. Ride out whichever wall lifts first:
        // switch to the candidate with the earliest 5-hour reset, skipping
        // weekly-drained ones (a 5-hour reset won't unblock those). Stay only when
        // the ACTIVE account's own reset is soonest.
        let activeFiveReset = weeklyDrained ? nil : active.fiveHourWindow?.resetsAt
        var bestReset = activeFiveReset?.timeIntervalSince(i.now) ?? .infinity
        var winner: UUID?
        for candidate in i.candidates {
            guard let usage = candidate.usage, let reset = usage.fiveHourWindow?.resetsAt else { continue }
            if let weekly = usage.weeklyWindow, weekly.usedPercent >= AccountAdvisor.weeklyDrainedPercent { continue }
            let seconds = reset.timeIntervalSince(i.now)
            if seconds < bestReset {
                bestReset = seconds
                winner = candidate.id
            }
        }
        var activeResetsSoonest = winner == nil && activeFiveReset != nil
        if winner == nil, weeklyDrained {
            // The active account is weekly-drained and no 5-hour reset can win:
            // the soonest 7-DAY reset is the next wall to lift anywhere.
            let activeWeeklyReset = active.weeklyWindow?.resetsAt
            var bestWeeklyReset = activeWeeklyReset?.timeIntervalSince(i.now) ?? .infinity
            for candidate in i.candidates {
                guard let reset = candidate.usage?.weeklyWindow?.resetsAt else { continue }
                let seconds = reset.timeIntervalSince(i.now)
                if seconds < bestWeeklyReset {
                    bestWeeklyReset = seconds
                    winner = candidate.id
                }
            }
            activeResetsSoonest = winner == nil && activeWeeklyReset != nil
        }
        if let winner {
            return .switchTo(id: winner, reason: "all accounts are maxed — this one resets soonest")
        }
        // Nobody is pickable: either the active account's own reset is provably
        // soonest (stay and ride it out) or no resets are known at all (surface
        // the all-maxed state to the UI).
        return activeResetsSoonest ? .stay : .noViableAccount(allKnownMaxed: true)
    }

    /// Human, situation-specific reason for a switch, phrased for the post-switch
    /// announcement ("New sessions now use <email> — <reason>").
    private static func switchReason(active: UsageSnapshot, weeklyDrained: Bool) -> String {
        if active.inOverageNow { return "the previous account is on extra usage" }
        if weeklyDrained { return "the previous account reached its weekly limit" }
        return "the previous account hit its 5-hour limit"
    }

    /// Viable = anything NOT KNOWN to be walled. Unknown-usage accounts ARE allowed:
    /// their stored access token may be too stale for our usage peek, but the CLI
    /// refreshes on use (and the post-swap heal refreshes immediately); idle >8h
    /// means the 5-hour window truly expired. We only refuse an account we can SEE
    /// is walled (5h full, weekly drained, or in overage).
    private static func viableCandidates(_ i: AutoSwitchInputs) -> [AutoSwitchInputs.Candidate] {
        i.candidates.filter { candidate in
            guard let usage = candidate.usage else { return true } // unknown — near-fresh
            if usage.inOverageNow { return false }
            return AccountAdvisor.score(usage, now: i.now) < viableScoreCeiling
        }
    }

    /// Best viable candidate via the SAME scoring (and weekly-aware tiebreak) that
    /// powers the dropdown recommendation. Nil when none are viable.
    private static func bestViable(_ viable: [AutoSwitchInputs.Candidate], now: Date) -> UUID? {
        guard !viable.isEmpty,
              let bestIdx = AccountAdvisor.bestIndex(usages: viable.map(\.usage), now: now) else {
            return nil
        }
        return viable[bestIdx].id
    }
}
