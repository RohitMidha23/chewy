import ChewyCore
import Foundation

/// Regression: the active account must come from the REAL canonical identity, not
/// app-side selection. (Bug: the dropdown marked one account active while the
/// canonical credential actually belonged to another.)
func checkActiveAccountResolver() throws {
    func claude(_ email: String, _ accountId: String) -> AccountProfile {
        AccountProfile(tool: .claude, name: email, slug: email, homePath: "/tmp/\(email)",
                       isImported: false, emailAddress: email, accountId: accountId)
    }
    let accountA = claude("a@example.com", "11111111-aaaa")
    let accountB = claude("b@example.com", "22222222-bbbb")
    let profiles = [accountB, accountA] // deliberately out of order
    let emailFor: (AccountProfile) -> String? = { $0.emailAddress }

    // Matches by accountUuid even when app state would say otherwise.
    let byUuid = ActiveAccountResolver.resolve(
        profiles: profiles, canonicalAccountUuid: "11111111-aaaa", canonicalEmail: "a@example.com", emailFor: emailFor)
    try check(byUuid?.id == accountA.id, "active should resolve to the profile whose accountId matches canonical")

    // Falls back to email when accountUuid is absent.
    let byEmail = ActiveAccountResolver.resolve(
        profiles: profiles, canonicalAccountUuid: nil, canonicalEmail: "b@example.com", emailFor: emailFor)
    try check(byEmail?.id == accountB.id, "active should fall back to an email match when uuid is missing")

    // No match → nil (caller falls back to stored selection).
    let none = ActiveAccountResolver.resolve(
        profiles: profiles, canonicalAccountUuid: "ZZZ", canonicalEmail: "nobody@x.com", emailFor: emailFor)
    try check(none == nil, "no canonical match should return nil")
}
