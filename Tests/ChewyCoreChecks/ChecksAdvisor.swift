import ChewyCore
import Foundation

func checkAccountAdvisor() throws {
    let now = Date()
    let active = UUID(), low = UUID(), high = UUID()

    func snap(_ pct: Double, resetsInMin: Double? = nil, extra: Bool = false, dollars: Double? = nil) -> UsageSnapshot {
        let reset = resetsInMin.map { now.addingTimeInterval($0 * 60) }
        // `extra` here means actually-in-overage: enabled + window at/over 100.
        return UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", usedPercent: extra ? 100 : pct, resetsAt: reset)],
            extraUsageEnabled: extra,
            extraSpendThisCycle: dollars
        )
    }

    /// A snapshot with BOTH a 5-hour and a 7-day window.
    func snap2(
        five: Double, fiveResetsInMin: Double? = nil,
        weekly: Double, weeklyResetsInMin: Double? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(windows: [
            UsageWindow(label: "5-hour", usedPercent: five, resetsAt: fiveResetsInMin.map { now.addingTimeInterval($0 * 60) }),
            UsageWindow(label: "7-day", usedPercent: weekly, resetsAt: weeklyResetsInMin.map { now.addingTimeInterval($0 * 60) })
        ])
    }

    // Active is maxed; a fresh account exists → recommend the fresh one.
    let r1 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(96)),
            .init(id: low, usage: snap(5)),
            .init(id: high, usage: snap(80)),
        ],
        activeId: active, now: now
    )
    try check(r1?.id == low, "should recommend the lowest-utilization account")

    // Active is fine (low) → no recommendation (don't nag).
    let r2 = AccountAdvisor.recommend(
        candidates: [.init(id: active, usage: snap(5)), .init(id: low, usage: snap(2))],
        activeId: active, now: now
    )
    try check(r2 == nil, "should NOT recommend a switch when the active account is already fine")

    // Extra-usage active account is worst; even a high (non-extra) account beats it.
    let r3 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(50, extra: true, dollars: 149)),
            .init(id: high, usage: snap(85)),
        ],
        activeId: active, now: now
    )
    try check(r3?.id == high, "an account on extra usage should be avoided in favor of a non-extra one")

    // Imminent reset wins: 95% resetting in 2m beats 40% resetting in hours.
    let soon = UUID(), steady = UUID()
    let r4 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(99)),
            .init(id: soon, usage: snap(95, resetsInMin: 2)),
            .init(id: steady, usage: snap(40, resetsInMin: 600)),
        ],
        activeId: active, now: now
    )
    try check(r4?.id == soon, "a near-full window resetting in minutes should win over a steadier one")
    try check(r4?.reason.contains("resets in") == true, "reason should mention the imminent reset")

    // No candidates besides active → nil.
    try check(AccountAdvisor.recommend(candidates: [.init(id: active, usage: snap(99))], activeId: active, now: now) == nil,
              "no alternative accounts → no recommendation")

    // --- P3 scoring semantics ---

    // Unknown usage scores 25 (idle >8h ⇒ the 5-hour window provably expired;
    // near-fresh — only the weekly budget is a gamble). Was 50 pre-P3.
    try check(AccountAdvisor.score(nil, now: now) == 25, "unknown usage should score 25 (near-fresh)")

    // resetSoonMinutes is 30: a 90% window resetting in 15m is effectively 45.
    try check(abs(AccountAdvisor.score(snap(90, resetsInMin: 15), now: now) - 45) < 0.01,
              "reset-soon discount should be linear over a 30-minute window (90% @ 15m → 45)")
    // Beyond 30 minutes there is no discount.
    try check(AccountAdvisor.score(snap(90, resetsInMin: 31), now: now) == 90,
              "no reset-soon discount beyond 30 minutes")

    // Weekly-drained (7-day ≥ 99.5) → 400 + minutesToWeeklyReset/60: worse than any
    // live account, better than overage's 1000+.
    let drained60 = AccountAdvisor.score(snap2(five: 10, weekly: 99.6, weeklyResetsInMin: 60), now: now)
    try check(abs(drained60 - 401) < 0.01, "weekly-drained resetting in 60m should score 401")
    let drainedUnknownReset = AccountAdvisor.score(snap2(five: 10, weekly: 100), now: now)
    try check(abs(drainedUnknownReset - (400 + 100_000.0 / 60)) < 0.01,
              "weekly-drained with no reset time should use the 100000/60 cap")
    // The weekly branch outranks a fresh-looking 5-hour window.
    try check(drained60 > AccountAdvisor.score(snap(98), now: now),
              "a weekly-drained account must score worse than any live 5-hour state")

    // A 7-day window BELOW 99.5 doesn't drive the score when a 5-hour window exists:
    // the 5-hour window is scored specifically (not the peak).
    try check(AccountAdvisor.score(snap2(five: 20, weekly: 90), now: now) == 20,
              "with a live weekly, the 5-hour window's utilization is the score")
    // No 5-hour window at all → fall back to the hottest window.
    try check(AccountAdvisor.score(UsageSnapshot(windows: [UsageWindow(label: "7-day", usedPercent: 40, resetsAt: nil)]), now: now) == 40,
              "without a 5-hour window, fall back to peak-window scoring")

    // --- ε-tiebreak (within 8 points, prefer the LOWEST 7-day utilization) ---

    // B's 5h score (26) is within ε=8 of A's (20), but B's weekly (10) beats A's (80).
    let tieA = UUID(), tieB = UUID()
    let r5 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(99)),
            .init(id: tieA, usage: snap2(five: 20, weekly: 80)),
            .init(id: tieB, usage: snap2(five: 26, weekly: 10)),
        ],
        activeId: active, now: now
    )
    try check(r5?.id == tieB, "ε-tiebreak should prefer the lower 7-day utilization among near-equal 5h scores")

    // Outside ε the raw score decides: 40 is NOT within 8 of 20.
    let farB = UUID()
    let r6 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(99)),
            .init(id: tieA, usage: snap2(five: 20, weekly: 80)),
            .init(id: farB, usage: snap2(five: 40, weekly: 10)),
        ],
        activeId: active, now: now
    )
    try check(r6?.id == tieA, "outside the ε band the lower 5h score should win regardless of weekly")

    // Unknown usage counts as weekly 55 in the tiebreak: a known candidate with a
    // lower weekly wins the tie (25 vs 30 is within ε).
    let unknown = UUID(), knownLowWeekly = UUID()
    let r7 = AccountAdvisor.recommend(
        candidates: [
            .init(id: active, usage: snap(99)),
            .init(id: unknown, usage: nil),
            .init(id: knownLowWeekly, usage: snap2(five: 30, weekly: 20)),
        ],
        activeId: active, now: now
    )
    try check(r7?.id == knownLowWeekly, "unknown counts as weekly 55 — a known low-weekly candidate wins the tie")
}
