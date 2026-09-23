import ChewyCore
import Foundation

/// Regression for the "second account overwrote the first" bug: Claude profiles
/// dedupe on the stable accountUuid when both sides carry one. Same email + org
/// but a DIFFERENT accountUuid is a different account and must appear as a second
/// profile; the same accountUuid with a changed email updates in place.
func checkIdentityFirstDedupe() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AccountProfileStore(paths: ChewyPaths(appSupportDirectory: dir))
    let home = dir.appendingPathComponent("home", isDirectory: true)

    let first = try store.upsert(
        tool: .claude, name: "Claude", slug: "claude", homeURL: home, isImported: false,
        emailAddress: "rohit@example.com", organizationUuid: "org-1", organizationName: "Org",
        accountId: "uuid-A"
    )
    let second = try store.upsert(
        tool: .claude, name: "Claude", slug: "claude-2", homeURL: home, isImported: false,
        emailAddress: "rohit@example.com", organizationUuid: "org-1", organizationName: "Org",
        accountId: "uuid-B"
    )
    try check(first.id != second.id, "different accountUuid must NOT merge, even with identical email + org")
    let afterSecond = try store.loadProfiles()
    try check(afterSecond.filter { $0.tool == .claude }.count == 2, "two distinct accounts → two profiles")
    try check(afterSecond.contains { $0.slug == "claude" && $0.accountId == "uuid-A" },
              "the first account keeps its own slug/home")

    // Same account, email changed → update in place (no third profile).
    let renamed = try store.upsert(
        tool: .claude, name: "Claude", slug: "claude-3", homeURL: home, isImported: false,
        emailAddress: "rohit.new@example.com", organizationUuid: "org-1", organizationName: "Org",
        accountId: "uuid-A"
    )
    try check(renamed.id == first.id, "same accountUuid updates in place even when the email changed")
    let afterRename = try store.loadProfiles()
    try check(afterRename.filter { $0.tool == .claude }.count == 2, "still two Claude profiles")
}

/// `security -g` prints Keychain timestamps as `"mdat"<timedate>=0x…  "20260921083026Z\\000"`;
/// the capture poll uses them to reject a staging item left over from an earlier
/// login attempt.
func checkSecurityAttributeDates() throws {
    let raw = """
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        0x00000007 <blob>="Claude Code-credentials-a12b96d7"
        "acct"<blob>="rohit"
        "cdat"<timedate>=0x32303236303932313038323835305A00  "20260921082850Z\\000"
        "mdat"<timedate>=0x32303236303932313038333032365A00  "20260921083026Z\\000"
        "svce"<blob>="Claude Code-credentials-a12b96d7"
    """
    let attributes = SystemSecurityRunner.parseAttributes(raw)
    try check(attributes["svce"] == "Claude Code-credentials-a12b96d7", "blob attributes still parse")
    try check(attributes["acct"] == "rohit", "acct parses")
    guard let mdatRaw = attributes["mdat"], let mdat = SystemSecurityRunner.keychainDate(from: mdatRaw) else {
        throw CheckFailure(description: "mdat timedate should be exposed and parse")
    }
    // 2026-09-21T08:30:26Z
    try check(abs(mdat.timeIntervalSince1970 - 1789979426) < 1, "mdat should decode to 2026-09-21T08:30:26Z, got \(mdat.timeIntervalSince1970)")
    guard let cdatRaw = attributes["cdat"], let cdat = SystemSecurityRunner.keychainDate(from: cdatRaw) else {
        throw CheckFailure(description: "cdat should parse")
    }
    try check(cdat < mdat, "creation precedes modification")
    try check(SystemSecurityRunner.keychainDate(from: "garbage") == nil, "non-timestamps yield nil")
}

/// Codex usage comes from the ChatGPT backend (`/backend-api/wham/usage`): the
/// primary (5h) / secondary (7d) windows map onto the same "5-hour" / "7-day"
/// labels the planner keys on, and credits + a reached limit read as overage.
func checkCodexUsageParsing() throws {
    let live = Data(#"""
    {"user_id":"user-x","account_id":"bd21fb61-8440-41e5-b685-c1b0e287d733","email":"r@example.com","plan_type":"team",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1790000323},
       "secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1790587123}},
     "code_review_rate_limit":null,"additional_rate_limits":null,
     "credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null}
    """#.utf8)
    guard let snapshot = UsageMonitor.parseCodexUsage(live) else {
        throw CheckFailure(description: "codex usage should parse")
    }
    try check(abs((snapshot.fiveHourWindow?.usedPercent ?? -1) - 12) < 0.001, "primary 18000s window → 5-hour 12%")
    try check(abs((snapshot.weeklyWindow?.usedPercent ?? -1) - 64) < 0.001, "secondary 604800s window → 7-day 64%")
    try check(abs((snapshot.fiveHourWindow?.resetsAt?.timeIntervalSince1970 ?? 0) - 1790000323) < 1, "reset_at epoch parses")
    try check(snapshot.extraUsageEnabled && !snapshot.inOverageNow, "credits available but no limit reached → not overage")

    let reached = Data(#"""
    {"rate_limit":{"allowed":false,"limit_reached":true,
       "primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_at":1790000323},
       "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1790587123}},
     "credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false},
     "rate_limit_reached_type":"primary"}
    """#.utf8)
    guard let walled = UsageMonitor.parseCodexUsage(reached) else {
        throw CheckFailure(description: "reached-limit codex usage should parse")
    }
    try check(walled.inOverageNow, "limit reached with credits → burning credits → overage")
    try check(abs(walled.peakPercent - 100) < 0.001, "peak is the exhausted 5-hour window")

    try check(UsageMonitor.parseCodexUsage(Data(#"{"credits":{"has_credits":true}}"#.utf8)) == nil,
              "no rate_limit block → nil")
}
