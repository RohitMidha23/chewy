import Foundation

/// A versioned, app-owned credential envelope. The durable source of truth for an
/// account's credentials; profile-home paths are staging only.
///
/// `blob` holds the raw credential bytes (Claude `{claudeAiOauth, oauthAccount}` or
/// Codex `auth.json`). It MUST NOT be logged or printed.
public struct VaultEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var tool: AccountTool
    /// Where the live credential lives: "keychain" | "file" | "codex".
    public var backend: String
    /// Stable identity (Claude `accountUuid` / Codex `account_id`).
    public var identityFingerprint: String?
    public var email: String?
    public var capturedAt: Date
    /// Hash of the canonical sink as last written/seen, for drift attribution.
    public var lastCanonicalHash: String?
    /// Raw credential bytes. Never log or print.
    public var blob: Data

    public init(
        schemaVersion: Int = 1,
        tool: AccountTool,
        backend: String,
        identityFingerprint: String? = nil,
        email: String? = nil,
        capturedAt: Date = Date(),
        lastCanonicalHash: String? = nil,
        blob: Data
    ) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.backend = backend
        self.identityFingerprint = identityFingerprint
        self.email = email
        self.capturedAt = capturedAt
        self.lastCanonicalHash = lastCanonicalHash
        self.blob = blob
    }
}

/// App-owned credential vault built on `CredentialStore` (service
/// `app.chewy.credentials`). One entry per account id, value = a JSON-encoded
/// `VaultEnvelope`. Account ids are namespaced with a `vault.` prefix in the store.
///
/// The reserved id `system-default` holds the user's pre-existing identity snapshot.
public final class CredentialVault {
    /// Reserved account id for the pre-existing (original) identity snapshot.
    public static let systemDefaultAccountID = "system-default"

    private let store: CredentialStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(store: CredentialStore = KeychainCredentialStore()) {
        self.store = store
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // ALL accounts live in ONE keychain item. macOS prompts PER ITEM, so a single
    // consolidated entry means one "Always Allow" instead of one per account. The
    // decoded map is cached in memory so repeated reads (usage polling) never re-hit
    // the Keychain. Legacy per-account `vault.<id>` items are migrated in once.
    private static let consolidatedAccount = "__vault__"
    private static let legacyPrefix = "vault."
    private var cache: [String: VaultEnvelope]?

    public func put(accountId: String, _ env: VaultEnvelope) throws {
        var map = try loadAll()
        map[accountId] = env
        try persist(map)
    }

    public func get(accountId: String) throws -> VaultEnvelope? {
        if let env = try loadAll()[accountId] { return env }
        // Fallback: the account may still live in a legacy per-account item that a
        // bulk (match-all) migration didn't surface — e.g. it was created under a
        // previous app identity whose ACL excludes match-all. Read it directly (the
        // path that always worked), then fold it into the consolidated item.
        return try recoverLegacy(accountId: accountId)
    }

    private func recoverLegacy(accountId: String) throws -> VaultEnvelope? {
        guard
            let secret = try? store.readSecret(account: "\(Self.legacyPrefix)\(accountId)"),
            let data = Data(base64Encoded: secret),
            let env = try? decoder.decode(VaultEnvelope.self, from: data)
        else {
            return nil
        }
        // Fold into the consolidated item — but only when it is readable. Never
        // persist a near-empty map over an undecodable consolidated item.
        if var map = try? loadAll() {
            map[accountId] = env
            try? persist(map)
            try? store.deleteSecret(account: "\(Self.legacyPrefix)\(accountId)")
        }
        return env
    }

    public func delete(accountId: String) throws {
        var map = try loadAll()
        guard map.removeValue(forKey: accountId) != nil else { return }
        try persist(map)
    }

    /// The newest envelope schema this build can safely round-trip. A consolidated
    /// item carrying a HIGHER version was written by a newer build; re-persisting
    /// it through this build's model could drop fields, so treat it as read-only.
    private static let maxKnownSchemaVersion = 1

    /// Load (and cache) the whole account → envelope map from the single keychain
    /// item, migrating any legacy per-account items on first run.
    ///
    /// Fail SAFE: when the consolidated item EXISTS but cannot be decoded (corrupt
    /// or future schema), this throws instead of falling through to an empty map —
    /// otherwise the next `put`/`delete` would silently persist an empty map over
    /// every stored account. Callers that `try?` keep their prior in-memory state.
    private func loadAll() throws -> [String: VaultEnvelope] {
        if let cache { return cache }

        if let secret = try store.readSecret(account: Self.consolidatedAccount) {
            guard let data = Data(base64Encoded: secret),
                  let map = try? decoder.decode([String: VaultEnvelope].self, from: data) else {
                throw ChewyError.vaultUndecodable
            }
            if let newest = map.values.map(\.schemaVersion).max(),
               newest > Self.maxKnownSchemaVersion {
                throw ChewyError.vaultSchemaTooNew(newest)
            }
            cache = map
            return map
        }

        // No consolidated item yet → migrate legacy `vault.<id>` items (one bulk read).
        let migrated = migrateLegacy()
        cache = migrated
        if !migrated.isEmpty { try? persist(migrated) }
        return migrated
    }

    private func migrateLegacy() -> [String: VaultEnvelope] {
        guard let all = try? store.readAllSecrets() else { return [:] }
        var map: [String: VaultEnvelope] = [:]
        for (account, secret) in all where account.hasPrefix(Self.legacyPrefix) {
            let id = String(account.dropFirst(Self.legacyPrefix.count))
            if let data = Data(base64Encoded: secret),
               let env = try? decoder.decode(VaultEnvelope.self, from: data) {
                map[id] = env
            }
        }
        // Best-effort cleanup of the old per-account items.
        for account in all.keys where account.hasPrefix(Self.legacyPrefix) {
            try? store.deleteSecret(account: account)
        }
        return map
    }

    private func persist(_ map: [String: VaultEnvelope]) throws {
        let data = try encoder.encode(map)
        try store.saveSecret(data.base64EncodedString(), account: Self.consolidatedAccount)
        cache = map
    }
}
