import Foundation

/// Decides when it is SAFE to delegate a canonical-token refresh to the CLI.
///
/// Refresh tokens are single-use, and running Claude sessions hold theirs in
/// memory: a heal that races a live session's own refresh strands that session
/// (forced /login). Two situations provably cannot race a live refresher:
///
///  1. RIGHT AFTER OUR OWN SWAP — the landing account was idle; no session is
///     mid-flight on its token chain.
///  2. THE CANONICAL HAS BEEN STABLE for several polls — if any live session
///     were refreshing this chain, the canonical bytes would have changed.
///
/// Everywhere else we WAIT: a live session will refresh the chain itself on its
/// next API call, and the poll's drift-capture folds that rotation into the
/// vault within a minute. Pure and fully testable.
public enum HealGate {
    /// Polls the canonical must stay byte-identical before a steady-state heal.
    public static let requiredStablePolls = 3

    public static func shouldHeal(
        armedBySwap: Bool,
        stablePolls: Int,
        inFlight: Bool,
        lastHealAt: Date?,
        cooldown: TimeInterval,
        now: Date
    ) -> Bool {
        guard !inFlight else { return false }
        if let last = lastHealAt, now.timeIntervalSince(last) < cooldown { return false }
        if armedBySwap { return true }
        return stablePolls >= requiredStablePolls
    }
}
