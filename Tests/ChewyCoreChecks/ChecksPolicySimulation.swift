import ChewyCore
import Foundation

// =============================================================================
// Policy simulation: multi-account auto-switch strategies, evaluated by a
// deterministic minute-tick discrete-event simulator over a 16-hour day.
//
// Everything here is pure and seeded (SplitMix64) — no Date(), no random().
// The study that designed P3 compared the then-shipped policy (P0) against pure
// candidates P1..P3; P3 won and IS NOW THE SHIPPED CODE. The roles today:
// - LEGACY: the pre-P3 shipped policy, frozen by hand (trigger 5h>95 only,
//   cooldown 120s, reset-soon 10, unknown 50, all-known-maxed → stall). It is
//   the floor nobody may regress below.
// - LIVE: the real shipped code, bridged to AutoSwitchPlanner.plan /
//   AccountAdvisor.score — faithful by construction.
// - P1..P3 remain as pure reference policies for offline studies.
//
// `checkPolicySimulation()` runs a compact grid (fast) and asserts the LIVE
// policy dominates LEGACY on stalled minutes without flapping — a permanent
// regression guard on the shipped switching policy.
// `policySimulationFullStudy()` runs the full grid (36 cells x 25 seeds x both
// overage modes) and returns a formatted table — used offline for the report,
// never printed by the checks binary.
// =============================================================================

// MARK: - Deterministic RNG (SplitMix64)

struct SimRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(nextRaw() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    /// Uniform integer in lo...hi (inclusive).
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(nextRaw() % UInt64(hi - lo + 1)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: - What a policy is allowed to see

/// One usage window as a policy sees it. `resetInMin == nil` means no window is
/// currently open (fresh) or the provider didn't report a reset.
struct PolicyWindow {
    let pct: Double
    let resetInMin: Double?
}

/// One account as a policy sees it. When `known == false` (idle > ~8h, token too
/// stale to peek) BOTH windows are nil and `inOverage` is false — policies must
/// never assume they can refresh idle tokens.
struct PolicyAccount {
    let known: Bool
    let fiveHour: PolicyWindow?
    let sevenDay: PolicyWindow?
    let inOverage: Bool
}

enum PolicyDecision: Equatable {
    case stay
    case switchTo(Int)
}

struct SwitchPolicy {
    let name: String
    /// Minimum minutes between auto-switches (anti-flap), enforced by the harness.
    let cooldownMinutes: Int
    let decide: (_ activeIndex: Int, _ accounts: [PolicyAccount], _ nowMinutes: Double) -> PolicyDecision
}

// MARK: - Scenario space

enum SimLoad: String, CaseIterable {
    case light, medium, heavy
    /// Base demand units per minute during core working hours.
    var baseUnitsPerMinute: Double {
        switch self {
        case .light: return 0.35
        case .medium: return 0.7
        case .heavy: return 1.25
        }
    }
}

struct SimScenario: Hashable {
    let accounts: Int
    let load: SimLoad
    /// Account 1 starts with its 5-hour window already at 100%.
    let deadStart: Bool
    /// Up to two idle accounts start with unreadable (UNKNOWN) usage.
    let unknownStart: Bool

    var label: String {
        var s = "N\(accounts)/\(load.rawValue)"
        if deadStart { s += "/dead" }
        if unknownStart { s += "/unk" }
        return s
    }

    var salt: UInt64 {
        UInt64(accounts) &* 1_000_003
            &+ UInt64(SimLoad.allCases.firstIndex(of: load) ?? 0) &* 7919
            &+ (deadStart ? 31 : 0) &+ (unknownStart ? 17 : 0)
    }
}

struct SimMetrics {
    var stalledMin = 0.0
    var overageUnits = 0.0
    var switches = 0.0
    var p95Streak = 0.0
    var weekliesDrained = 0.0

    static func mean(_ runs: [SimMetrics]) -> SimMetrics {
        guard !runs.isEmpty else { return SimMetrics() }
        var m = SimMetrics()
        for r in runs {
            m.stalledMin += r.stalledMin
            m.overageUnits += r.overageUnits
            m.switches += r.switches
            m.p95Streak += r.p95Streak
            m.weekliesDrained += r.weekliesDrained
        }
        let c = Double(runs.count)
        m.stalledMin /= c
        m.overageUnits /= c
        m.switches /= c
        m.p95Streak /= c
        m.weekliesDrained /= c
        return m
    }
}

// MARK: - Simulator constants

/// 16-hour day, one tick per minute (08:00 → 24:00; t=0 is 08:00).
private let simDayTicks = 960
/// Units a 5-hour window can absorb before hitting 100%.
private let simCap5 = 300.0
/// Units the 7-day window can absorb — a slower budget (~3.3 sessions' worth).
private let simCap7 = 1000.0
private let simFiveHourLen = 300
/// An idle account's usage becomes unreadable this many minutes after last use.
private let simUnknownAfterIdle = 480

// MARK: - Demand process

/// Deterministic per-seed daily demand: steady 9–5 coding, a lunch dip, 2–4
/// bursty agent-fleet spikes at 3–5x, and (60% of days) a late-night burst.
func simDemandProfile(load: SimLoad, rng: inout SimRandom) -> [Double] {
    var mult = [Double](repeating: 0.15, count: simDayTicks) // off-hours trickle
    for t in 60..<540 { mult[t] = 1.0 }                      // 09:00–17:00 steady
    for t in 270..<315 { mult[t] = 0.05 }                    // 12:30–13:15 lunch
    if rng.chance(0.6) {                                     // late-night burst
        let start = rng.int(760, 840)
        for t in start..<min(start + 120, simDayTicks) { mult[t] = max(mult[t], 1.2) }
    }
    for _ in 0..<rng.int(2, 4) {                             // agent-fleet spikes
        let start = rng.int(60, 880)
        let dur = rng.int(20, 60)
        let m = rng.range(3.0, 5.0)
        for t in start..<min(start + dur, simDayTicks) { mult[t] = max(mult[t], m) }
    }
    var demand = [Double](repeating: 0, count: simDayTicks)
    for t in 0..<simDayTicks {
        if rng.chance(0.1) { continue }                      // think-time gaps
        demand[t] = load.baseUnitsPerMinute * mult[t] * rng.range(0.6, 1.4)
    }
    return demand
}

// MARK: - Engine

private struct SimAccountTruth {
    var used5 = 0.0
    var start5: Int?      // tick the 5h window opened; nil = no open window
    var used7 = 0.0
    var reset7 = 0        // tick the (always-open, pre-seeded) 7-day window resets
    var lastActive = -100_000
}

private func simView(of a: SimAccountTruth, index: Int, active: Int, now: Int, overageMode: Bool) -> PolicyAccount {
    let known = index == active || now - a.lastActive <= simUnknownAfterIdle
    guard known else { return PolicyAccount(known: false, fiveHour: nil, sevenDay: nil, inOverage: false) }
    let pct5 = a.used5 / simCap5 * 100
    let pct7 = a.used7 / simCap7 * 100
    return PolicyAccount(
        known: true,
        fiveHour: PolicyWindow(pct: pct5, resetInMin: a.start5.map { Double($0 + simFiveHourLen - now) }),
        sevenDay: PolicyWindow(pct: pct7, resetInMin: Double(a.reset7 - now)),
        inOverage: overageMode && (pct5 >= 100 || pct7 >= 100)
    )
}

func simRun(scenario: SimScenario, seed: UInt64, policy: SwitchPolicy, overageMode: Bool) -> SimMetrics {
    // Demand and account seeding depend ONLY on (scenario, seed) — identical
    // across policies, so comparisons are paired.
    var demandRng = SimRandom(seed: 0xD00D &+ seed &* 2_654_435_761 &+ scenario.salt)
    let demand = simDemandProfile(load: scenario.load, rng: &demandRng)
    var setupRng = SimRandom(seed: 0x5E7 &+ seed &* 40_503 &+ scenario.salt &* 3)

    let n = scenario.accounts
    var accounts = (0..<n).map { i -> SimAccountTruth in
        var a = SimAccountTruth()
        a.used7 = simCap7 * setupRng.range(0.05, 0.45)
        a.reset7 = setupRng.int(1500, 9000) // outside today unless drained again
        a.lastActive = i == 0 ? 0 : -setupRng.int(30, 400)
        return a
    }
    if scenario.deadStart, n > 1 {
        // Recently active, KNOWN, and pinned at 100% of its 5-hour window.
        accounts[1].used5 = simCap5
        accounts[1].start5 = -setupRng.int(10, 120)
        accounts[1].lastActive = -2
    }
    if scenario.unknownStart {
        // The last one/two non-active, non-dead accounts have been idle > 8h.
        // NOTE: >8h idle implies the 5h window truly expired — unknown accounts
        // are 5h-fresh in reality, but their 7-day budget is still whatever it is.
        var made = 0
        var i = n - 1
        while i >= 1, made < 2 {
            if !(scenario.deadStart && i == 1) {
                accounts[i].used5 = 0
                accounts[i].start5 = nil
                accounts[i].lastActive = -setupRng.int(600, 2000)
                made += 1
            }
            i -= 1
        }
    }

    var active = 0
    var lastSwitchTick = -100_000
    var metrics = SimMetrics()
    var streaks: [Int] = []
    var streak = 0

    for t in 0..<simDayTicks {
        // 1. Window lifecycle: full reset 5h/7d after window start.
        for i in 0..<n {
            if let s = accounts[i].start5, t >= s + simFiveHourLen {
                accounts[i].start5 = nil
                accounts[i].used5 = 0
            }
            if t >= accounts[i].reset7 {
                accounts[i].used7 = 0
                accounts[i].reset7 = t + 10_080
            }
        }
        // The active account's usage is always readable.
        accounts[active].lastActive = t

        // 2. Poll (every tick) + policy, honoring the policy's own cooldown.
        if t - lastSwitchTick >= policy.cooldownMinutes {
            let views = (0..<n).map { simView(of: accounts[$0], index: $0, active: active, now: t, overageMode: overageMode) }
            if case .switchTo(let j) = policy.decide(active, views, Double(t)), j != active, j >= 0, j < n {
                active = j
                accounts[j].lastActive = t
                lastSwitchTick = t
                metrics.switches += 1
            }
        }

        // 3. Serve demand on the ACTIVE account.
        let d = demand[t]
        var stalledThisTick = false
        if d > 0 {
            let room5 = simCap5 - accounts[active].used5
            let room7 = simCap7 - accounts[active].used7
            let take = max(0, min(d, min(room5, room7)))
            if take > 0 {
                if accounts[active].start5 == nil { accounts[active].start5 = t }
                accounts[active].used5 += take
                accounts[active].used7 += take
            }
            let unserved = d - take
            if unserved > 1e-9 {
                if overageMode {
                    metrics.overageUnits += unserved // paid at API rates
                } else {
                    metrics.stalledMin += 1
                    stalledThisTick = true
                }
            }
        }
        if stalledThisTick {
            streak += 1
        } else if streak > 0 {
            streaks.append(streak)
            streak = 0
        }
    }
    if streak > 0 { streaks.append(streak) }
    if !streaks.isEmpty {
        let sorted = streaks.sorted()
        let idx = max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)
        metrics.p95Streak = Double(sorted[idx])
    }
    metrics.weekliesDrained = Double(accounts.filter { $0.used7 >= 0.95 * simCap7 }.count)
    return metrics
}

// MARK: - Shared policy helpers

/// Effective utilization with a linear "resets soon" discount over `window` min.
func simEffective(_ w: PolicyWindow?, window: Double) -> Double {
    guard let w else { return 0 }
    guard let r = w.resetInMin, r >= 0, r <= window else { return w.pct }
    return w.pct * (r / window)
}

// MARK: - LEGACY: the pre-P3 shipped policy, frozen by hand

/// Faithful reproduction of the policy that shipped BEFORE P3 landed:
/// - trigger: active 5-hour > 95 only (weekly maxed / overage never triggered);
/// - viable: unknown usage, or not-in-overage with 5-hour ≤ 95;
/// - score: unknown 50; otherwise the PEAK window's effective utilization with a
///   10-minute reset-soon discount;
/// - all-known-maxed: stay (stall until the active window resets by itself);
/// - cooldown: 120 s.
/// Kept as the regression floor now that the live code IS P3 — do not "fix" it.
func simLegacyPolicy() -> SwitchPolicy {
    SwitchPolicy(name: "LEGACY", cooldownMinutes: 2) { active, accounts, _ in
        let a = accounts[active]
        guard a.known, let pct5 = a.fiveHour?.pct, pct5 > 95 else { return .stay }
        func peak(_ c: PolicyAccount) -> PolicyWindow? {
            switch (c.fiveHour, c.sevenDay) {
            case (nil, let w), (let w, nil): return w
            case (let five?, let seven?): return five.pct >= seven.pct ? five : seven
            }
        }
        func score(_ c: PolicyAccount) -> Double {
            guard c.known else { return 50 }
            guard let w = peak(c) else { return 0 }
            return simEffective(w, window: 10)
        }
        var best = -1
        var bestScore = Double.infinity
        for (i, c) in accounts.enumerated() where i != active {
            // Old viability: skip known-overage and known 5h>95; unknown is viable.
            if c.known {
                if c.inOverage { continue }
                if let p = c.fiveHour?.pct, p > 95 { continue }
            }
            let s = score(c)
            if s < bestScore { bestScore = s; best = i }
        }
        return best >= 0 ? .switchTo(best) : .stay // noViableAccount ⇒ stall
    }
}

// MARK: - LIVE: the shipped policy, via the REAL planner/advisor code

private let simIds: [UUID] = (0..<8).map { i in
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!
}

private func simSnapshot(_ a: PolicyAccount, now: Date) -> UsageSnapshot? {
    guard a.known else { return nil }
    var windows: [UsageWindow] = []
    if let w = a.fiveHour {
        windows.append(UsageWindow(label: "5-hour", usedPercent: w.pct,
                                   resetsAt: w.resetInMin.map { now.addingTimeInterval($0 * 60) }))
    }
    if let w = a.sevenDay {
        windows.append(UsageWindow(label: "7-day", usedPercent: w.pct,
                                   resetsAt: w.resetInMin.map { now.addingTimeInterval($0 * 60) }))
    }
    // extraUsageEnabled+severity chosen so UsageSnapshot.inOverageNow == a.inOverage.
    return UsageSnapshot(windows: windows, extraUsageEnabled: a.inOverage,
                         extraSpendThisCycle: nil, severity: a.inOverage ? "escalated" : "normal")
}

func simLivePolicy() -> SwitchPolicy {
    SwitchPolicy(name: "LIVE", cooldownMinutes: 3) { active, accounts, nowMinutes in
        let now = Date(timeIntervalSinceReferenceDate: nowMinutes * 60)
        let inputs = AutoSwitchInputs(
            activeIsManaged: true,
            activeId: simIds[active],
            activeUsage: simSnapshot(accounts[active], now: now),
            candidates: accounts.indices.filter { $0 != active }.map {
                AutoSwitchInputs.Candidate(id: simIds[$0], usage: simSnapshot(accounts[$0], now: now))
            },
            lastSwitchAt: nil, // cooldown enforced by the harness (same 180s)
            now: now
        )
        if case .switchTo(let id, _) = AutoSwitchPlanner.plan(inputs),
           let idx = simIds.firstIndex(of: id) {
            return .switchTo(idx)
        }
        return .stay
    }
}

// MARK: - P1: greedy-headroom (wide reset discount + earliest-reset when all maxed)

func simP1Policy() -> SwitchPolicy {
    SwitchPolicy(name: "P1", cooldownMinutes: 2) { active, accounts, _ in
        let a = accounts[active]
        let pct5 = a.fiveHour?.pct ?? 0
        guard a.known, pct5 >= 95 || a.inOverage else { return .stay }
        func score(_ c: PolicyAccount) -> Double {
            guard c.known else { return 50 }
            if c.inOverage { return 2000 }
            return simEffective(c.fiveHour, window: 30)
        }
        var best = -1
        var bestScore = Double.infinity
        for (i, c) in accounts.enumerated() where i != active {
            let s = score(c)
            if s < bestScore { bestScore = s; best = i }
        }
        if best >= 0, bestScore < 95 { return .switchTo(best) }
        // All known-maxed → earliest 5-hour reset (active included).
        var winner = active
        var bestReset = a.fiveHour?.resetInMin ?? Double.infinity
        for (i, c) in accounts.enumerated() where i != active {
            guard c.known, let r = c.fiveHour?.resetInMin else { continue }
            if r < bestReset { bestReset = r; winner = i }
        }
        return winner == active ? .stay : .switchTo(winner)
    }
}

// MARK: - P2: stagger-rotate (proactive rotation at 80% to spread window starts)

func simP2Policy() -> SwitchPolicy {
    SwitchPolicy(name: "P2", cooldownMinutes: 10) { active, accounts, _ in
        let a = accounts[active]
        guard a.known else { return .stay }
        let pct5 = a.fiveHour?.pct ?? 0
        func score(_ c: PolicyAccount) -> Double {
            guard c.known else { return 50 }
            if c.inOverage { return 2000 }
            return simEffective(c.fiveHour, window: 30)
        }
        if pct5 >= 95 || a.inOverage {
            var best = -1
            var bestScore = Double.infinity
            for (i, c) in accounts.enumerated() where i != active {
                let s = score(c)
                if s < bestScore { bestScore = s; best = i }
            }
            if best >= 0, bestScore < 95 { return .switchTo(best) }
            var winner = active
            var bestReset = a.fiveHour?.resetInMin ?? Double.infinity
            for (i, c) in accounts.enumerated() where i != active {
                guard c.known, let r = c.fiveHour?.resetInMin else { continue }
                if r < bestReset { bestReset = r; winner = i }
            }
            return winner == active ? .stay : .switchTo(winner)
        }
        // Proactive: rotate before the wall to stagger window start times.
        if pct5 >= 80 {
            let activeEff = simEffective(a.fiveHour, window: 30)
            var best = -1
            var bestScore = Double.infinity
            for (i, c) in accounts.enumerated() where i != active {
                let s = score(c)
                if s < bestScore { bestScore = s; best = i }
            }
            if best >= 0, bestScore <= activeEff - 25 { return .switchTo(best) }
        }
        return .stay
    }
}

// MARK: - P3: greedy-headroom + 7-day trigger/penalty/tiebreak + tuned unknowns

struct SimP3Config {
    /// Score for an UNKNOWN account. >8h idle guarantees the 5h window expired,
    /// so unknown is close-to-fresh — but its 7-day budget is a gamble.
    var unknownScore = 25.0
    /// 5h scores within this of the best are "ties" → prefer lower 7-day pct.
    var tieEpsilon = 8.0
    /// Linear reset-soon discount window (minutes).
    var discountWindow = 30.0
    /// Don't bother switching when the active window resets within this (min).
    var stayIfResetWithin = 2.0
    var name = "P3"
}

func simP3Policy(_ cfg: SimP3Config = SimP3Config()) -> SwitchPolicy {
    SwitchPolicy(name: cfg.name, cooldownMinutes: 3) { active, accounts, _ in
        let a = accounts[active]
        let pct5 = a.fiveHour?.pct ?? 0
        let pct7 = a.sevenDay?.pct ?? 0
        // Trigger on the 5h wall OR a drained weekly OR live overage.
        guard a.known, pct5 >= 95 || pct7 >= 99.5 || a.inOverage else { return .stay }
        // Imminent-reset exception: a switch buys < stayIfResetWithin minutes.
        if let r = a.fiveHour?.resetInMin, r <= cfg.stayIfResetWithin, pct7 < 99.5, !a.inOverage {
            return .stay
        }
        func score(_ c: PolicyAccount) -> Double {
            guard c.known else { return cfg.unknownScore }
            if c.inOverage { return 2000 }
            if let w7 = c.sevenDay, w7.pct >= 99.5 {
                // Weekly-drained: useless until its (distant) weekly reset.
                return 400 + min(w7.resetInMin ?? 100_000, 100_000) / 60
            }
            return simEffective(c.fiveHour, window: cfg.discountWindow)
        }
        var best = -1
        var bestScore = Double.infinity
        for (i, c) in accounts.enumerated() where i != active {
            let s = score(c)
            if s < bestScore { bestScore = s; best = i }
        }
        guard best >= 0 else { return .stay }
        if bestScore < 99 {
            // Viable target exists. 7-day-aware tiebreak among near-equal 5h scores.
            var pick = best
            var pickWeekly = accounts[best].known ? (accounts[best].sevenDay?.pct ?? 0) : 55
            for (i, c) in accounts.enumerated() where i != active && i != pick {
                let s = score(c)
                guard s <= bestScore + cfg.tieEpsilon, s < 99 else { continue }
                let weekly = c.known ? (c.sevenDay?.pct ?? 0) : 55
                if weekly < pickWeekly {
                    pickWeekly = weekly
                    pick = i
                }
            }
            return .switchTo(pick)
        }
        // Everything known is maxed → earliest 5h reset (active included),
        // skipping weekly-drained accounts (a 5h reset won't unblock them).
        var winner = active
        var bestReset = (pct7 >= 99.5) ? Double.infinity : (a.fiveHour?.resetInMin ?? Double.infinity)
        for (i, c) in accounts.enumerated() where i != active {
            guard c.known, let w5 = c.fiveHour, let r = w5.resetInMin else { continue }
            if let w7 = c.sevenDay, w7.pct >= 99.5 { continue }
            if r < bestReset { bestReset = r; winner = i }
        }
        if winner == active, pct7 >= 99.5 {
            // Active weekly-drained and nothing better on 5h resets: soonest weekly reset.
            var bestR7 = a.sevenDay?.resetInMin ?? Double.infinity
            for (i, c) in accounts.enumerated() where i != active {
                guard c.known, let r7 = c.sevenDay?.resetInMin else { continue }
                if r7 < bestR7 { bestR7 = r7; winner = i }
            }
        }
        return winner == active ? .stay : .switchTo(winner)
    }
}

// MARK: - Study runner

struct SimCellSummary {
    let scenario: SimScenario
    let overageMode: Bool
    /// Policy name → mean metrics across seed replicates.
    let byPolicy: [(name: String, metrics: SimMetrics)]
}

func simRunCell(scenario: SimScenario, policies: [SwitchPolicy], seeds: Int, overageMode: Bool) -> SimCellSummary {
    var results: [(String, SimMetrics)] = []
    for policy in policies {
        var runs: [SimMetrics] = []
        for seed in 0..<seeds {
            runs.append(simRun(scenario: scenario, seed: UInt64(seed) &+ 1, policy: policy, overageMode: overageMode))
        }
        results.append((policy.name, SimMetrics.mean(runs)))
    }
    return SimCellSummary(scenario: scenario, overageMode: overageMode, byPolicy: results)
}

private func simFmt(_ v: Double) -> String {
    String(format: "%6.1f", v)
}

func simSummaryLine(_ cell: SimCellSummary) -> String {
    let head = cell.scenario.label.padding(toLength: 16, withPad: " ", startingAt: 0)
        + (cell.overageMode ? " $ " : "   ")
    let cols = cell.byPolicy.map { name, m -> String in
        let primary = cell.overageMode ? m.overageUnits : m.stalledMin
        return "\(name) \(simFmt(primary))/sw\(String(format: "%4.1f", m.switches))/p95\(String(format: "%3.0f", m.p95Streak))"
    }
    return head + cols.joined(separator: " | ")
}

/// Full 36-cell x both-modes study. Not called by the checks binary (silent
/// repo); used offline to produce the report tables.
func policySimulationFullStudy(seeds: Int = 25) -> String {
    let policies = [
        simLegacyPolicy(),
        simLivePolicy(),
        simP1Policy(),
        simP2Policy(),
        simP3Policy(SimP3Config(unknownScore: 25, name: "P3a")),
        simP3Policy(SimP3Config(unknownScore: 65, name: "P3b")),
    ]
    var lines: [String] = []
    for overageMode in [false, true] {
        lines.append(overageMode ? "== OVERAGE MODE (overageUnits/switches/p95) ==" : "== STALL MODE (stalledMin/switches/p95) ==")
        for n in [2, 4, 6] {
            for load in SimLoad.allCases {
                for dead in [false, true] {
                    for unk in [false, true] {
                        let sc = SimScenario(accounts: n, load: load, deadStart: dead, unknownStart: unk)
                        lines.append(simSummaryLine(simRunCell(scenario: sc, policies: policies, seeds: seeds, overageMode: overageMode)))
                    }
                }
            }
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - The check (compact + fast + silent)

func checkPolicySimulation() throws {
    // The permanent regression guard: the LIVE shipped policy (bridged to the real
    // AutoSwitchPlanner/AccountAdvisor) must never fall below the frozen pre-P3
    // LEGACY policy on stalled minutes, without flapping.
    let legacy = simLegacyPolicy()
    let live = simLivePolicy()
    let seeds = 10

    // Compact grid biased toward contested cells (medium/heavy) where stalls
    // actually occur, plus dead-start and unknown-at-t0 variants.
    let cells: [SimScenario] = [
        SimScenario(accounts: 2, load: .medium, deadStart: false, unknownStart: false),
        SimScenario(accounts: 2, load: .heavy, deadStart: false, unknownStart: false),
        SimScenario(accounts: 2, load: .heavy, deadStart: true, unknownStart: false),
        SimScenario(accounts: 2, load: .heavy, deadStart: false, unknownStart: true),
        SimScenario(accounts: 4, load: .medium, deadStart: true, unknownStart: false),
        SimScenario(accounts: 4, load: .heavy, deadStart: false, unknownStart: false),
        SimScenario(accounts: 4, load: .heavy, deadStart: true, unknownStart: true),
        SimScenario(accounts: 6, load: .medium, deadStart: false, unknownStart: true),
        SimScenario(accounts: 6, load: .heavy, deadStart: false, unknownStart: false),
        SimScenario(accounts: 6, load: .heavy, deadStart: true, unknownStart: true),
    ]

    var lines: [String] = []
    var strictlyBetter = 0
    var comparisons: [(cell: String, legacy: SimMetrics, live: SimMetrics)] = []
    for sc in cells {
        let summary = simRunCell(scenario: sc, policies: [legacy, live], seeds: seeds, overageMode: false)
        lines.append(simSummaryLine(summary))
        let l = summary.byPolicy[0].metrics
        let p = summary.byPolicy[1].metrics
        comparisons.append((sc.label, l, p))
        if p.stalledMin < l.stalledMin - 0.5 { strictlyBetter += 1 }
    }
    let table = lines.joined(separator: "\n")

    // Sanity: the harness gives both policies real work. If LEGACY never switches
    // or never stalls, the frozen reproduction (or the demand model) broke; if
    // LIVE never switches, the bridge to AutoSwitchPlanner broke.
    let heavy2 = comparisons.first { $0.cell == "N2/heavy" }!
    try check(heavy2.legacy.switches > 0, "LEGACY should switch under N2/heavy — the frozen policy looks broken\n\(table)")
    try check(heavy2.legacy.stalledMin > 0, "N2/heavy should produce LEGACY stalls — demand model looks too weak\n\(table)")
    try check(heavy2.live.switches > 0, "LIVE should switch under N2/heavy — bridge to AutoSwitchPlanner looks broken\n\(table)")

    for c in comparisons {
        // 0.5-min epsilon: minute-tick discrete-event noise. Earlier switching (the
        // 90% early-warning trigger) can shift WHICH poll discovers a dead account
        // by a tick in dead+unknown scenarios — a ~12-second artifact, not a policy
        // regression. Anything beyond noise still fails hard.
        try check(
            c.live.stalledMin <= c.legacy.stalledMin + 0.5,
            "shipped policy must not stall more than the pre-P3 legacy in \(c.cell): LIVE \(c.live.stalledMin) vs LEGACY \(c.legacy.stalledMin)\n\(table)"
        )
        try check(
            c.live.switches <= 3 * max(c.legacy.switches, 1.0),
            "shipped policy must not flap in \(c.cell): LIVE switches \(c.live.switches) vs LEGACY \(c.legacy.switches)\n\(table)"
        )
    }
    try check(
        strictlyBetter * 2 >= cells.count,
        "shipped policy should be strictly better in at least half the cells (got \(strictlyBetter)/\(cells.count))\n\(table)"
    )

    // Overage mode: the shipped policy shouldn't burn more overage dollars than legacy.
    for sc in [cells[1], cells[6]] {
        let summary = simRunCell(scenario: sc, policies: [legacy, live], seeds: seeds, overageMode: true)
        let l = summary.byPolicy[0].metrics
        let p = summary.byPolicy[1].metrics
        try check(
            p.overageUnits <= l.overageUnits * 1.05 + 1.0,
            "shipped overage should not exceed legacy in \(sc.label) ($): LIVE \(p.overageUnits) vs LEGACY \(l.overageUnits)\n\(simSummaryLine(summary))"
        )
    }
}
