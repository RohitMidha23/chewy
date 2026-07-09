import Foundation

/// Determines which account is *actually* active from the real canonical identity,
/// rather than trusting app-side selection state (which can drift if the user
/// switched elsewhere or state went stale). Pure, so it's unit-tested.
public enum ActiveAccountResolver {
    /// The profile matching the canonical identity: by `accountId` (stable account
    /// UUID) first, then by resolved email. Returns nil if nothing matches.
    public static func resolve(
        profiles: [AccountProfile],
        canonicalAccountUuid: String?,
        canonicalEmail: String?,
        emailFor: (AccountProfile) -> String?
    ) -> AccountProfile? {
        if let uuid = canonicalAccountUuid, !uuid.isEmpty,
           let match = profiles.first(where: { $0.accountId == uuid }) {
            return match
        }
        if let email = canonicalEmail, !email.isEmpty,
           let match = profiles.first(where: { emailFor($0) == email }) {
            return match
        }
        return nil
    }
}
