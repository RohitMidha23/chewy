import ChewyCore
import Foundation

/// Covers the pure, defensive parser for Claude's usage endpoint:
/// - utilization given as a 0...100 percentage (never rescaled),
/// - the current `limits` array shape, with experimental keys ignored,
/// - resets_at parsing,
/// - missing/garbage JSON → nil,
/// - peakPercent picks the hottest window.
func checkUsageParsing() throws {
    // ---- 0...100 percentage form, with resets_at ----
    let percentForm = Data(#"""
    {
      "five_hour": { "utilization": 82, "resets_at": "2026-06-22T18:30:00Z" },
      "seven_day": { "utilization": 41, "resets_at": "2026-06-29T00:00:00Z" }
    }
    """#.utf8)

    guard let percentSnapshot = UsageMonitor.parseClaudeUsage(percentForm) else {
        throw CheckFailure(description: "percentage-form usage should parse")
    }
    try check(abs(percentSnapshot.peakPercent - 82) < 0.001, "peakPercent should be the hottest window (82)")
    guard let peak = percentSnapshot.peakWindow else {
        throw CheckFailure(description: "peakWindow should exist")
    }
    try check(peak.label == "5-hour", "hottest window should be the five_hour window, labeled 5-hour")
    guard let resets = peak.resetsAt else {
        throw CheckFailure(description: "resets_at should parse for the five_hour window")
    }
    // 2026-06-22T18:30:00Z == 1782153000 epoch seconds.
    try check(abs(resets.timeIntervalSince1970 - 1782153000) < 1.0, "resets_at should decode to the right instant")

    // ---- utilization is a PERCENTAGE, never rescaled ----
    // REGRESSION: a genuine 1% (right after a window reset) used to be read as a
    // 0…1 "fraction" and inflated to 100%, firing a bogus limit-reached switch.
    let lowForm = Data(#"""
    { "five_hour": { "utilization": 1.0 }, "seven_day": { "utilization": 0.5 } }
    """#.utf8)
    guard let lowSnapshot = UsageMonitor.parseClaudeUsage(lowForm) else {
        throw CheckFailure(description: "low-percentage usage should parse")
    }
    try check(abs((lowSnapshot.fiveHourWindow?.usedPercent ?? -1) - 1.0) < 0.001, "utilization 1.0 means 1%, not 100%")
    try check(abs((lowSnapshot.weeklyWindow?.usedPercent ?? -1) - 0.5) < 0.001, "utilization 0.5 means 0.5%, not 50%")
    try check(abs(lowSnapshot.peakPercent - 1.0) < 0.001, "peak of a fresh account stays ~1%")

    // ---- the current live response shape (Sept 2026): a structured `limits` array,
    // null placeholders for optional windows, and experimental buckets we must ignore.
    let liveForm = Data(#"""
    {"five_hour":{"utilization":3.0,"resets_at":"2026-09-21T13:30:00.190063+00:00","limit_dollars":null},
     "seven_day":{"utilization":39.0,"resets_at":"2026-09-21T09:00:00.190086+00:00"},
     "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,
     "nimbus_quill":{"utilization":0.0,"resets_at":null},"cinder_cove":null,
     "extra_usage":{"is_enabled":true,"used_credits":319033.0,"utilization":null},
     "limits":[
       {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-09-21T13:30:00.190063+00:00","scope":null,"is_active":false},
       {"kind":"weekly_all","group":"weekly","percent":39,"severity":"normal","resets_at":"2026-09-21T09:00:00.190086+00:00","scope":null,"is_active":false},
       {"kind":"weekly_scoped","group":"weekly","percent":71,"severity":"normal","resets_at":"2026-09-21T09:00:00.190347+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}
     ],
     "spend":{"used":{"amount_minor":319033,"currency":"USD","exponent":2},"percent":0,"severity":"normal"}}
    """#.utf8)
    guard let live = UsageMonitor.parseClaudeUsage(liveForm) else {
        throw CheckFailure(description: "live-shape usage should parse")
    }
    try check(abs((live.fiveHourWindow?.usedPercent ?? -1) - 3) < 0.001, "5-hour window comes from limits[kind=session] (3%)")
    try check(live.fiveHourWindow?.resetsAt != nil, "5-hour reset should parse from the +00:00 offset form")
    try check(live.windows.contains { $0.label == "7-day" && abs($0.usedPercent - 39) < 0.001 }, "weekly_all → 7-day 39%")
    try check(live.windows.contains { $0.label == "7-day (Fable)" && abs($0.usedPercent - 71) < 0.001 }, "weekly_scoped → 7-day (Fable) 71%")
    try check(abs((live.weeklyWindow?.usedPercent ?? -1) - 71) < 0.001, "weeklyWindow is the hottest 7-day window (the scoped one)")
    try check(!live.windows.contains { $0.label.lowercased().contains("nimbus") }, "experimental buckets (nimbus_quill) must not become windows")
    try check(live.windows.count == 3, "exactly session + weekly_all + weekly_scoped windows, deduped against the named keys")
    try check(live.extraUsageEnabled && !live.inOverageNow, "enabled extra usage with a 3% window is not overage")
    try check(abs((live.extraSpendThisCycle ?? 0) - 3190.33) < 0.001, "cumulative spend is $3190.33")

    // Unknown top-level keys alone yield nil (nothing recognisable).
    try check(UsageMonitor.parseClaudeUsage(Data(#"{"nimbus_quill":{"utilization":50.0}}"#.utf8)) == nil,
              "an unknown window key on its own is not a usage snapshot")

    // ---- nested container + alternate key (used_percent) ----
    let nestedForm = Data(#"""
    { "usage": { "five_hour": { "used_percent": 96.5, "resets_at": 1782498600 } } }
    """#.utf8)
    guard let nestedSnapshot = UsageMonitor.parseClaudeUsage(nestedForm) else {
        throw CheckFailure(description: "nested used_percent usage should parse")
    }
    try check(abs(nestedSnapshot.peakPercent - 96.5) < 0.001, "nested used_percent should be read")
    try check(nestedSnapshot.peakWindow?.resetsAt != nil, "epoch-seconds resets_at should decode")

    // ---- extra-usage / spend semantics (the real API shape) ----
    // REGRESSION: enabled + cumulative spend but a FRESH 5h window (38%) is NOT
    // "in overage now" — that's cumulative monthly spend, not a current-billing state.
    let cumulativeForm = Data(#"""
    {
      "five_hour": { "utilization": 38.0, "resets_at": "2026-06-24T20:00:00Z" },
      "seven_day": { "utilization": 15.0 },
      "extra_usage": { "is_enabled": true, "used_credits": 15000.0, "utilization": null },
      "spend": { "used": { "amount_minor": 15000, "currency": "USD", "exponent": 2 }, "percent": 0, "severity": "normal" }
    }
    """#.utf8)
    guard let cumulative = UsageMonitor.parseClaudeUsage(cumulativeForm) else {
        throw CheckFailure(description: "cumulative-spend form should parse")
    }
    try check(cumulative.extraUsageEnabled, "extra usage feature is enabled")
    try check(abs((cumulative.extraSpendThisCycle ?? 0) - 150.00) < 0.001, "cumulative spend should be $150.00")
    try check(!cumulative.inOverageNow, "enabled + cumulative spend at 38% window must NOT be 'in overage now'")
    try check(abs(cumulative.peakPercent - 38) < 0.001, "peak should be the 5h window (38%)")
    try check(!cumulative.windows.contains { $0.label.lowercased().contains("spend") }, "spend must not become a fake window")

    // In overage: window at the limit while enabled → inOverageNow true.
    let overageForm = Data(#"""
    { "five_hour": { "utilization": 100.0 }, "extra_usage": { "is_enabled": true },
      "spend": { "used": { "amount_minor": 50000, "exponent": 2 }, "severity": "normal" } }
    """#.utf8)
    try check(UsageMonitor.parseClaudeUsage(overageForm)?.inOverageNow == true,
              "enabled + window at 100% → in overage now")

    // Escalated severity also counts as overage even if the window reads below 100.
    let severityForm = Data(#"{ "five_hour": { "utilization": 90.0 }, "extra_usage": { "is_enabled": true }, "spend": { "severity": "critical" } }"#.utf8)
    try check(UsageMonitor.parseClaudeUsage(severityForm)?.inOverageNow == true,
              "enabled + escalated severity → in overage now")

    // ---- garbage / missing → nil ----
    try check(UsageMonitor.parseClaudeUsage(Data("not json at all".utf8)) == nil, "garbage JSON should yield nil")
    try check(UsageMonitor.parseClaudeUsage(Data("{}".utf8)) == nil, "empty object (no windows) should yield nil")
    try check(UsageMonitor.parseClaudeUsage(Data(#"{"five_hour":{"foo":"bar"}}"#.utf8)) == nil,
              "a window with no utilization should yield nil")

    // ---- empty snapshot peakPercent is 0 (no crash) ----
    try check(UsageSnapshot(windows: []).peakPercent == 0, "empty snapshot peakPercent should be 0")

    // ---- reset countdown formatting (compact: "2m" / "3h" / "3d") ----
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    try check(UsageMonitor.shortTimeUntil(nil, now: t0) == nil, "nil reset → nil")
    try check(UsageMonitor.shortTimeUntil(t0.addingTimeInterval(-10), now: t0) == "now", "past reset → now")
    try check(UsageMonitor.shortTimeUntil(t0.addingTimeInterval(120), now: t0) == "2m", "2 min → 2m")
    try check(UsageMonitor.shortTimeUntil(t0.addingTimeInterval(3 * 3600), now: t0) == "3h", "3 hours → 3h")
    try check(UsageMonitor.shortTimeUntil(t0.addingTimeInterval(3 * 86400), now: t0) == "3d", "3 days → 3d")
}
