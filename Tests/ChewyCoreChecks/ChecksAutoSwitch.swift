import ChewyCore
import Foundation

/// Build a usage snapshot with a single 5-hour window at `percent`.
private func usage(_ percent: Double, overage: Bool = false) -> UsageSnapshot {
    UsageSnapshot(
        windows: [UsageWindow(label: "5-hour", usedPercent: percent, resetsAt: nil)],
        extraUsageEnabled: overage,
        severity: overage ? "escalated" : nil
    )
}

func checkAutoSwitchPlanner() throws {
    let now = Date()
    let active = UUID()

    /// A snapshot with a 5-hour window (optional reset) and an optional 7-day window.
    func usage2(
        five: Double, fiveResetsInMin: Double? = nil,
        weekly: Double? = nil, weeklyResetsInMin: Double? = nil,
        overage: Bool = false
    ) -> UsageSnapshot {
        var windows = [UsageWindow(label: "5-hour", usedPercent: five,
                                   resetsAt: fiveResetsInMin.map { now.addingTimeInterval($0 * 60) })]
        if let weekly {
            windows.append(UsageWindow(label: "7-day", usedPercent: weekly,
                                       resetsAt: weeklyResetsInMin.map { now.addingTimeInterval($0 * 60) }))
        }
        return UsageSnapshot(windows: windows, extraUsageEnabled: overage,
                             severity: overage ? "escalated" : nil)
    }

    func inputs(
        activeIsManaged: Bool = true,
        activeUsage: UsageSnapshot?,
        candidates: [AutoSwitchInputs.Candidate],
        lastSwitchAt: Date? = nil
    ) -> AutoSwitchInputs {
        AutoSwitchInputs(
            activeIsManaged: activeIsManaged,
            activeId: active,
            activeUsage: activeUsage,
            candidates: candidates,
            lastSwitchAt: lastSwitchAt,
            now: now
        )
    }

    // active 5h 96% + a candidate at 10% → switchTo(thatId), reason mentions 5-hour.
    let fresh = UUID()
    let d1 = AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: fresh, usage: usage(10))]
    ))
    try check(d1 == .switchTo(id: fresh, reason: "the previous account hit its 5-hour limit"),
              "active over 90% with a fresh candidate should switch to it")
    if case let .switchTo(_, reason) = d1 {
        try check(reason.contains("5-hour"), "switch reason should mention the 5-hour limit")
    } else {
        throw CheckFailure(description: "expected a switchTo decision")
    }

    // active 5h 50% → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(50),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "active under threshold should stay")

    // Boundary: exactly 90 stays; 91 switches (threshold is now 90, strict >).
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(90),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "exactly 90% should stay (strict > trigger)")
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(91),
        candidates: [.init(id: fresh, usage: usage(10))]))
            == .switchTo(id: fresh, reason: "the previous account hit its 5-hour limit"),
              "91% should trigger at the 90 threshold")

    // active usage nil → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: nil,
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "unknown active usage should stay")

    // activeIsManaged == false → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeIsManaged: false,
        activeUsage: usage(96),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "unmanaged active should stay")

    // Several viable candidates → picks the lowest-5h (AccountAdvisor's best).
    let low = UUID()
    let mid = UUID()
    let high = UUID()
    let dPick = AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: high, usage: usage(70)),
                     .init(id: mid, usage: usage(40)),
                     .init(id: low, usage: usage(5))]))
    try check(dPick == .switchTo(id: low, reason: "the previous account hit its 5-hour limit"),
              "should pick the lowest-5h viable candidate")

    // All candidates maxed/overage with NO reset times anywhere → nobody is pickable
    // and the active can't prove its own reset is soonest → noViableAccount(true).
    // (Note: a candidate must score ≥ 99 to be non-viable now; 98% is still viable.)
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: UUID(), usage: usage(100)),
                     .init(id: UUID(), usage: usage(100, overage: true))])) == .noViableAccount(allKnownMaxed: true),
              "all maxed with no known resets → noViableAccount allKnownMaxed true")

    // All candidates unknown → unknown is "near-fresh" (idle >8h ⇒ 5h window expired),
    // so we DO switch (to one of them). Claude Code refreshes the token on use.
    let onlyUnknown = UUID()
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: onlyUnknown, usage: nil)]))
            == .switchTo(id: onlyUnknown, reason: "the previous account hit its 5-hour limit"),
              "an unknown-usage candidate is viable (near-fresh) → switch to it")

    // Mixed: one KNOWN-maxed + one unknown → switch to the unknown (the maxed is excluded).
    let mixedUnknown = UUID()
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: UUID(), usage: usage(100)),
                     .init(id: mixedUnknown, usage: nil)]))
            == .switchTo(id: mixedUnknown, reason: "the previous account hit its 5-hour limit"),
              "mixed maxed+unknown → switch to the unknown, never the known-maxed")

    // A KNOWN-viable account is preferred over an unknown one (score 5 vs 25, and
    // the unknown loses the ε-tiebreak too: weekly 55 vs 0).
    let knownFresh = UUID()
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: UUID(), usage: nil),
                     .init(id: knownFresh, usage: usage(5))]))
            == .switchTo(id: knownFresh, reason: "the previous account hit its 5-hour limit"),
              "a known-fresh candidate beats an unknown one")

    // No other accounts at all → noViableAccount(allKnownMaxed: false).
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [])) == .noViableAccount(allKnownMaxed: false),
              "no candidates → noViableAccount allKnownMaxed false")

    // Cooldown: active 96% but lastSwitchAt 30s before now → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: fresh, usage: usage(10))],
        lastSwitchAt: now.addingTimeInterval(-30))) == .stay,
              "a recent switch should keep us in cooldown")

    // Cooldown is 180s: 150s after a switch is STILL cooling down (was 120s pre-P3)…
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: fresh, usage: usage(10))],
        lastSwitchAt: now.addingTimeInterval(-150))) == .stay,
              "150s after a switch should still be in the 180s cooldown")
    // …and 200s after, we act again.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(96),
        candidates: [.init(id: fresh, usage: usage(10))],
        lastSwitchAt: now.addingTimeInterval(-200)))
            == .switchTo(id: fresh, reason: "the previous account hit its 5-hour limit"),
              "the cooldown should release after 180s")

    // Post-switch self-clear: new active at 5% → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage(5),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "a fresh active account after switching should stay")

    // --- Dead sign-in escape: the switcher must never wedge on a dead account ---

    // Active sign-in is known-dead (usage unreadable) → escape to the best viable
    // candidate immediately, with the sign-in reason.
    func deadInputs(candidates: [AutoSwitchInputs.Candidate], lastSwitchAt: Date? = nil) -> AutoSwitchInputs {
        AutoSwitchInputs(activeIsManaged: true, activeId: active, activeUsage: nil,
                         activeNeedsReconnect: true, candidates: candidates,
                         lastSwitchAt: lastSwitchAt, now: now)
    }
    try check(AutoSwitchPlanner.plan(deadInputs(candidates: [.init(id: fresh, usage: usage(10))]))
            == .switchTo(id: fresh, reason: "the previous account's sign-in expired"),
              "a dead active account must escape to a viable candidate")

    // The cooldown must NOT hold the switcher hostage on a dead account.
    try check(AutoSwitchPlanner.plan(deadInputs(candidates: [.init(id: fresh, usage: usage(10))],
                                                lastSwitchAt: now.addingTimeInterval(-10)))
            == .switchTo(id: fresh, reason: "the previous account's sign-in expired"),
              "the dead-sign-in escape must bypass the cooldown")

    // Dead active + unknown-usage candidate → still escape (unknown is viable).
    let unknownTarget = UUID()
    try check(AutoSwitchPlanner.plan(deadInputs(candidates: [.init(id: unknownTarget, usage: nil)]))
            == .switchTo(id: unknownTarget, reason: "the previous account's sign-in expired"),
              "a dead active escapes onto an unknown-usage candidate")

    // Dead active with NO candidates → noViableAccount(false).
    try check(AutoSwitchPlanner.plan(deadInputs(candidates: []))
            == .noViableAccount(allKnownMaxed: false),
              "dead active with no candidates → noViableAccount(false)")

    // Dead active where every candidate is KNOWN-walled → noViableAccount(true).
    try check(AutoSwitchPlanner.plan(deadInputs(candidates: [.init(id: UUID(), usage: usage(100, overage: true))]))
            == .noViableAccount(allKnownMaxed: true),
              "dead active with only walled candidates → noViableAccount(true)")

    // build() derives activeNeedsReconnect from `excluding` containing the active id.
    let deadProfile = AccountProfile(tool: .claude, name: "d", slug: "d", homePath: "/tmp/d",
                                     isImported: false, emailAddress: "d@x.com")
    let builtDead = AutoSwitchInputs.build(
        activeMatch: deadProfile, claudeProfiles: [deadProfile],
        usageByAccount: [:], excluding: [deadProfile.id], lastSwitchAt: nil, now: now)
    try check(builtDead.activeNeedsReconnect, "build must flag a quarantined active as needing reconnect")

    // --- P3: weekly trigger ---

    // The weekly wall fires even when the 5-hour window is comfortable (the shipped
    // pre-P3 code stalled indefinitely here).
    let dWeekly = AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 50, weekly: 99.6),
        candidates: [.init(id: fresh, usage: usage(10))]))
    try check(dWeekly == .switchTo(id: fresh, reason: "the previous account reached its weekly limit"),
              "a drained weekly should trigger a switch even at 5h<95")
    if case let .switchTo(_, reason) = dWeekly {
        try check(reason.contains("weekly limit"), "weekly-trigger reason should mention the weekly limit")
    }

    // A weekly at 99 (below 99.5) with 5h at 50 does NOT trigger.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 50, weekly: 99),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "a weekly below 99.5 must not trigger")

    // --- P3: overage trigger ---

    let dOverage = AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 80, overage: true),
        candidates: [.init(id: fresh, usage: usage(10))]))
    try check(dOverage == .switchTo(id: fresh, reason: "the previous account is on extra usage"),
              "an active account paying overage should switch even at 5h<95")

    // --- P3: imminent-reset stay exception ---

    // The active 5h wall lifts in 1 minute and nothing else is walled → stay.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 97, fiveResetsInMin: 1, weekly: 40),
        candidates: [.init(id: fresh, usage: usage(10))])) == .stay,
              "an active 5h reset within 2 minutes should stay (the wall lifts by itself)")

    // But a drained weekly overrides the exception — the 5h reset won't unblock it.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 97, fiveResetsInMin: 1, weekly: 99.6),
        candidates: [.init(id: fresh, usage: usage(10))]))
            == .switchTo(id: fresh, reason: "the previous account reached its weekly limit"),
              "imminent 5h reset must NOT hold a weekly-drained account")

    // A reset 10 minutes out is not imminent → normal switch.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 97, fiveResetsInMin: 10),
        candidates: [.init(id: fresh, usage: usage(10))]))
            == .switchTo(id: fresh, reason: "the previous account hit its 5-hour limit"),
              "a 10-minute-out reset is not imminent")

    // --- P3: all-known-maxed → earliest 5-hour reset (replaces stall-forever) ---

    // Active resets in 100m; maxed candidates reset in 50m and 80m → the 50m one
    // wins. (Resets beyond 30m so the reset-soon discount can't make them viable.)
    let soonest = UUID(), later = UUID()
    let dMaxed = AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 96, fiveResetsInMin: 100),
        candidates: [.init(id: soonest, usage: usage2(five: 100, fiveResetsInMin: 50)),
                     .init(id: later, usage: usage2(five: 100, fiveResetsInMin: 80))]))
    try check(dMaxed == .switchTo(id: soonest, reason: "all accounts are maxed — this one resets soonest"),
              "all-known-maxed should switch to the earliest 5-hour reset")

    // The ACTIVE account's own reset is soonest → stay and ride it out.
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 96, fiveResetsInMin: 30),
        candidates: [.init(id: soonest, usage: usage2(five: 100, fiveResetsInMin: 50))])) == .stay,
              "all-known-maxed should stay when the active account resets soonest")

    // A weekly-drained candidate is skipped even if its 5h reset is earliest.
    let weeklyDead = UUID(), aliveLater = UUID()
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 96, fiveResetsInMin: 100),
        candidates: [.init(id: weeklyDead, usage: usage2(five: 100, fiveResetsInMin: 40, weekly: 99.9)),
                     .init(id: aliveLater, usage: usage2(five: 100, fiveResetsInMin: 80))]))
            == .switchTo(id: aliveLater, reason: "all accounts are maxed — this one resets soonest"),
              "a weekly-drained candidate must be skipped in the all-maxed path")

    // Active weekly-drained and no 5h-based winner → soonest 7-DAY reset wins.
    let weeklySooner = UUID()
    try check(AutoSwitchPlanner.plan(inputs(
        activeUsage: usage2(five: 50, weekly: 99.6, weeklyResetsInMin: 2000),
        candidates: [.init(id: weeklySooner, usage: usage2(five: 98, fiveResetsInMin: 40, weekly: 99.8, weeklyResetsInMin: 500))]))
            == .switchTo(id: weeklySooner, reason: "all accounts are maxed — this one resets soonest"),
              "with everyone weekly-drained, the soonest 7-day reset should win")
}

func checkAutoSwitchInputsBuild() throws {
    let now = Date()

    func claude(_ email: String) -> AccountProfile {
        AccountProfile(tool: .claude, name: email, slug: email, homePath: "/tmp/\(email)",
                       isImported: false, emailAddress: email)
    }
    let activeProfile = claude("active@x.com")
    let other = claude("other@x.com")
    let codex = AccountProfile(tool: .codex, name: "codex", slug: "codex",
                               homePath: "/tmp/codex", isImported: false, emailAddress: "codex@x.com")

    let usageByAccount: [UUID: UsageSnapshot] = [
        activeProfile.id: usage(96),
        other.id: usage(10),
        codex.id: usage(5)
    ]

    // A Codex profile is never a candidate; the active profile is excluded.
    let inputs = AutoSwitchInputs.build(
        activeMatch: activeProfile,
        claudeProfiles: [activeProfile, other],
        usageByAccount: usageByAccount,
        lastSwitchAt: nil,
        now: now
    )
    try check(inputs.activeIsManaged, "a resolved active match should mark managed")
    try check(inputs.activeId == activeProfile.id, "activeId should be the matched profile id")
    try check(inputs.candidates.count == 1, "active profile should be excluded from candidates")
    try check(inputs.candidates.first?.id == other.id, "the only candidate should be the other Claude profile")
    try check(!inputs.candidates.contains { $0.id == codex.id }, "a Codex profile is never a candidate")

    // activeMatch == nil → activeIsManaged == false.
    let unmanaged = AutoSwitchInputs.build(
        activeMatch: nil,
        claudeProfiles: [activeProfile, other],
        usageByAccount: usageByAccount,
        lastSwitchAt: nil,
        now: now
    )
    try check(!unmanaged.activeIsManaged, "no active match should mark unmanaged")
    try check(unmanaged.activeId == nil, "unmanaged build should have nil activeId")
    try check(unmanaged.candidates.count == 2, "with no active match, both Claude profiles are candidates")

    // An account with a known-dead sign-in (reconnect needed) is never a candidate —
    // switching onto it would just produce a login prompt.
    let dead = claude("dead@x.com")
    let excluded = AutoSwitchInputs.build(
        activeMatch: activeProfile,
        claudeProfiles: [activeProfile, other, dead],
        usageByAccount: usageByAccount,
        excluding: [dead.id],
        lastSwitchAt: nil,
        now: now
    )
    try check(excluded.candidates.count == 1, "a reconnect-needed account must be excluded from candidates")
    try check(!excluded.candidates.contains { $0.id == dead.id }, "the dead account must not be a candidate")
}

/// Structure sweep: the deletion-heavy refactor must actually remove these files.
func checkNoDeletedSymbols() throws {
    let cwd = FileManager.default.currentDirectoryPath
    let deleted = [
        "Sources/ChewyCore/FocusTarget.swift",
        "Sources/ChewyCore/HookConfigInstaller.swift",
        "Sources/ChewyCore/AttentionFilter.swift",
        "Sources/ChewyCore/AgentEvent.swift",
        "Sources/ChewyCore/EventStore.swift",
        "Sources/ChewyApp/HostAppFocuser.swift",
        "Resources/hooks"
    ]
    for relative in deleted {
        let path = (cwd as NSString).appendingPathComponent(relative)
        try check(!FileManager.default.fileExists(atPath: path),
                  "deleted path should not exist: \(relative)")
    }
}
