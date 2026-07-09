import Foundation

/// Maps the active account's usage to a menu-bar meter state: a severity level and
/// a compact label. Pure, so the thresholds are unit-tested.
public enum UsageMeter {
    public enum Level: Equatable, Sendable {
        case normal   // plenty of headroom — neutral icon
        case warning  // >= 80% of a window — amber
        case critical // extra-usage spend, or >= 95% — red
    }

    public static let warningThreshold: Double = 80
    public static let criticalThreshold: Double = 95

    public static func level(for usage: UsageSnapshot?) -> Level {
        guard let usage else { return .normal }
        if usage.inOverageNow { return .critical }
        if usage.peakPercent >= criticalThreshold { return .critical }
        if usage.peakPercent >= warningThreshold { return .warning }
        return .normal
    }

    /// Compact menu-bar label for the meter, or nil when nothing's worth showing.
    /// In overage a plan window is exhausted, so lead with "limit" — NOT the cumulative
    /// cycle dollars (monthly info, not the current rate-limit state). Otherwise show
    /// the hottest window % once it's notable.
    public static func label(for usage: UsageSnapshot?) -> String? {
        guard let usage else { return nil }
        if usage.inOverageNow { return "limit" }
        guard usage.peakPercent >= warningThreshold else { return nil }
        return "\(Int(usage.peakPercent.rounded()))%"
    }
}
