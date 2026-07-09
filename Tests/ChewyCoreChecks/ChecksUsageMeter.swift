import ChewyCore
import Foundation

/// Regression: the menu-bar usage meter maps the active account's usage to the right
/// severity + label (so the icon warns before you open it).
func checkUsageMeter() throws {
    // `overage`: enabled + window at 100 (the real "paying API rates now" state).
    func snap(_ pct: Double, overage: Bool = false, dollars: Double? = nil, enabled: Bool = false) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(label: "5-hour", usedPercent: overage ? 100 : pct, resetsAt: nil)],
                      extraUsageEnabled: overage || enabled, extraSpendThisCycle: dollars)
    }

    // Levels.
    try check(UsageMeter.level(for: nil) == .normal, "no data → normal")
    try check(UsageMeter.level(for: snap(10)) == .normal, "10% → normal")
    try check(UsageMeter.level(for: snap(80)) == .warning, "80% → warning")
    try check(UsageMeter.level(for: snap(96)) == .critical, "96% → critical")
    try check(UsageMeter.level(for: snap(0, overage: true, dollars: 150)) == .critical,
              "in overage (window at limit) → critical")

    // REGRESSION: cumulative cycle spend with a FRESH window is NOT overage — the
    // meter must not flash red just because the feature is enabled + money was spent.
    try check(UsageMeter.level(for: snap(38, dollars: 1800, enabled: true)) == .normal,
              "enabled + $1800 cumulative but window at 38% → NOT critical")
    try check(UsageMeter.label(for: snap(38, dollars: 1800, enabled: true)) == nil,
              "cumulative spend at low window usage shows no menu-bar label")

    // Labels.
    try check(UsageMeter.label(for: snap(10)) == nil, "below threshold → no label")
    try check(UsageMeter.label(for: snap(82)) == "82%", "warning → percent label")
    // REGRESSION: in overage the menu bar leads with the LIMIT, never the cumulative
    // cycle dollars (which are monthly info, not the current rate-limit state).
    try check(UsageMeter.label(for: snap(0, overage: true, dollars: 1800)) == "limit",
              "in overage → 'limit', not the cumulative dollar amount")
    try check(UsageMeter.label(for: snap(0, overage: true)) == "limit",
              "in overage without a dollar amount → 'limit'")
}
