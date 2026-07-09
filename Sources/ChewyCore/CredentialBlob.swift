import Foundation

/// Canonical, single-source identity extraction for credential blobs.
///
/// Capture, migration, and the swap manager MUST all derive an account's identity
/// the SAME way so the vault is keyed consistently (one identity → one vault key).
/// These helpers never print or log token values.
public enum CredentialBlob {
    /// Identity fields for a Claude credential/identity blob.
    ///
    /// `blob` may be the vault blob (`{claudeAiOauth, oauthAccount, mcpOAuth?}`),
    /// a live canonical blob, or a captured staging blob — the identity always
    /// lives under `oauthAccount`, falling back to `claudeAiOauth`.
    public struct ClaudeIdentity: Equatable, Sendable {
        public let accountUuid: String?
        public let email: String?
        public let orgUuid: String?
        public let orgName: String?
    }

    /// Identity fields for a Codex `auth.json` blob.
    public struct CodexIdentity: Equatable, Sendable {
        public let accountId: String?
        public let email: String?
        public let workspaceAccountId: String?
    }

    /// Parse Claude identity from a credential/identity blob. Returns nil only when
    /// the bytes are not a JSON object at all.
    public static func claudeIdentity(fromBlob blob: Data) -> ClaudeIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: blob),
              let dict = object as? [String: Any] else {
            return nil
        }
        // Prefer the displayed identity block; fall back to the auth block.
        let identity = (dict["oauthAccount"] as? [String: Any])
            ?? (dict["claudeAiOauth"] as? [String: Any])
            ?? [:]
        return ClaudeIdentity(
            accountUuid: identity["accountUuid"] as? String,
            email: identity["emailAddress"] as? String,
            orgUuid: identity["organizationUuid"] as? String,
            orgName: identity["organizationName"] as? String
        )
    }

    /// Parse Codex identity from an `auth.json` blob. The ChatGPT account id is
    /// derived from `tokens.account_id`, falling back to the JWT `id_token` claim.
    public static func codexIdentity(fromAuthJSON authJSON: Data) -> CodexIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: authJSON),
              let dict = object as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any] else {
            return nil
        }
        let idToken = tokens["id_token"] as? String
        let workspaceAccountId = idToken.flatMap { JWTPayload.chatgptAccountId(from: $0) }
        let email = idToken.flatMap { JWTPayload.email(from: $0) }
        let accountId = (tokens["account_id"] as? String) ?? workspaceAccountId
        return CodexIdentity(
            accountId: accountId,
            email: email,
            workspaceAccountId: workspaceAccountId
        )
    }
}
