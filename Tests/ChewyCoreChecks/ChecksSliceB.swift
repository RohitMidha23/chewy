import ChewyCore
import Foundation

/// Dictionary-backed in-memory CredentialStore so the vault test never touches the real Keychain.
final class InMemoryCredentialStore: CredentialStore {
    private var storage: [String: String] = [:]

    func saveSecret(_ secret: String, account: String) throws {
        storage[account] = secret
    }

    func readSecret(account: String) throws -> String? {
        storage[account]
    }

    func deleteSecret(account: String) throws {
        storage.removeValue(forKey: account)
    }

    func readAllSecrets() throws -> [String: String] {
        storage
    }
}

func checkCredentialVault() throws {
    let store = InMemoryCredentialStore()
    let vault = CredentialVault(store: store)

    let missing = try vault.get(accountId: "missing")
    try check(missing == nil, "get(missing) should be nil")

    let blob = Data(#"{"claudeAiOauth":{"x":1},"oauthAccount":{"emailAddress":"a@b.com"}}"#.utf8)
    let envelope = VaultEnvelope(
        tool: .claude,
        backend: "keychain",
        identityFingerprint: "uuid-123",
        email: "a@b.com",
        lastCanonicalHash: "deadbeef",
        blob: blob
    )

    try vault.put(accountId: "acct-1", envelope)

    guard let roundTripped = try vault.get(accountId: "acct-1") else {
        throw CheckFailure(description: "vault get should return stored envelope")
    }
    try check(roundTripped.schemaVersion == 1, "envelope schemaVersion should round-trip")
    try check(roundTripped.tool == .claude, "envelope tool should round-trip")
    try check(roundTripped.backend == "keychain", "envelope backend should round-trip")
    try check(roundTripped.identityFingerprint == "uuid-123", "envelope fingerprint should round-trip")
    try check(roundTripped.email == "a@b.com", "envelope email should round-trip")
    try check(roundTripped.lastCanonicalHash == "deadbeef", "envelope canonical hash should round-trip")
    try check(roundTripped.blob == blob, "envelope blob bytes should round-trip exactly")

    // Reserved snapshot id.
    let codexBlob = Data(#"{"tokens":{"id_token":"redacted"}}"#.utf8)
    try vault.put(
        accountId: CredentialVault.systemDefaultAccountID,
        VaultEnvelope(tool: .codex, backend: "codex", blob: codexBlob)
    )
    let snapshot = try vault.get(accountId: CredentialVault.systemDefaultAccountID)
    try check(snapshot?.blob == codexBlob, "system-default snapshot blob should round-trip")

    try vault.delete(accountId: "acct-1")
    let afterDelete = try vault.get(accountId: "acct-1")
    try check(afterDelete == nil, "delete should remove the envelope")

    // Consolidation: everything lives under ONE keychain item (one prompt, not N).
    let consolidatedKeys = try store.readAllSecrets().keys
    try check(consolidatedKeys.allSatisfy { $0 == "__vault__" },
              "vault should persist as a single consolidated item")

    // Migration: legacy per-account `vault.<id>` items are folded into the consolidated
    // item on first access, and the legacy items are removed.
    let legacyStore = InMemoryCredentialStore()
    let legacyEnv = VaultEnvelope(tool: .claude, backend: "keychain", email: "old@b.com", blob: Data("x".utf8))
    let legacyData = try JSONEncoder.iso().encode(legacyEnv).base64EncodedString()
    try legacyStore.saveSecret(legacyData, account: "vault.legacy-id")
    let migratedVault = CredentialVault(store: legacyStore)
    let migratedEmail = try migratedVault.get(accountId: "legacy-id")?.email
    try check(migratedEmail == "old@b.com",
              "legacy per-account item should migrate into the vault")
    let afterMigration = try legacyStore.readAllSecrets()
    try check(afterMigration["vault.legacy-id"] == nil,
              "legacy item should be removed after migration")
    try check(afterMigration["__vault__"] != nil,
              "migrated data should live in the consolidated item")

    // Regression (switching broke): when a legacy item is NOT surfaced by the bulk
    // match-all read (e.g. created under a previous app identity), get() must still
    // recover it via a direct per-account read — otherwise the swap has no creds.
    let hidden = HiddenFromBulkStore()
    let env = VaultEnvelope(tool: .claude, backend: "keychain", email: "recover@b.com", blob: Data("y".utf8))
    try hidden.saveSecret(try JSONEncoder.iso().encode(env).base64EncodedString(), account: "vault.acct-9")
    let recoverVault = CredentialVault(store: hidden)
    let recovered = try recoverVault.get(accountId: "acct-9")?.email
    try check(recovered == "recover@b.com",
              "get() must recover a legacy item that match-all doesn't surface (the switch-broke bug)")
}

/// A store whose bulk `readAllSecrets()` returns nothing (simulating items whose ACL
/// excludes them from a match-all under a changed app identity), but whose per-account
/// `readSecret` still works. Used to regress the vault legacy-recovery path.
private final class HiddenFromBulkStore: CredentialStore {
    private var storage: [String: String] = [:]
    func saveSecret(_ secret: String, account: String) throws { storage[account] = secret }
    func readSecret(account: String) throws -> String? { storage[account] }
    func deleteSecret(account: String) throws { storage.removeValue(forKey: account) }
    func readAllSecrets() throws -> [String: String] { [:] } // hides everything from bulk reads
}

private extension JSONEncoder {
    static func iso() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}

func checkEmailDedupe() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let paths = ChewyPaths(appSupportDirectory: temporaryDirectory)
    let store = AccountProfileStore(paths: paths)
    let home = temporaryDirectory.appendingPathComponent("home", isDirectory: true)

    // Claude: same (email, org) twice → 1 profile, updated in place, same id.
    let first = try store.upsert(
        tool: .claude,
        name: "Work",
        slug: "work",
        homeURL: home,
        isImported: false,
        emailAddress: "user@example.com",
        organizationUuid: "org-A",
        organizationName: "Org A"
    )
    let second = try store.upsert(
        tool: .claude,
        name: "Work Renamed",
        slug: "work-renamed",
        homeURL: home,
        isImported: true,
        emailAddress: "user@example.com",
        organizationUuid: "org-A",
        organizationName: "Org A (renamed)"
    )
    try check(first.id == second.id, "same (email, org) should update in place with same id")
    try check(second.name == "Work Renamed", "updated profile should refresh name")

    var profiles = try store.loadProfiles()
    try check(profiles.count == 1, "same (email, org) should produce one Claude profile")

    // Different org, same email → 2 profiles.
    _ = try store.upsert(
        tool: .claude,
        name: "Personal",
        slug: "personal",
        homeURL: home,
        isImported: false,
        emailAddress: "user@example.com",
        organizationUuid: "org-B",
        organizationName: "Org B"
    )
    profiles = try store.loadProfiles()
    try check(profiles.count == 2, "different org with same email should be distinct")

    // Codex dedupe on (email, workspaceAccountId).
    let codexFirst = try store.upsert(
        tool: .codex,
        name: "Codex Work",
        slug: "codex-work",
        homeURL: home,
        isImported: false,
        emailAddress: "user@example.com",
        accountId: "chatgpt-acct-1",
        workspaceAccountId: "ws-1"
    )
    let codexSecond = try store.upsert(
        tool: .codex,
        name: "Codex Work 2",
        slug: "codex-work-2",
        homeURL: home,
        isImported: false,
        emailAddress: "user@example.com",
        accountId: "chatgpt-acct-1",
        workspaceAccountId: "ws-1"
    )
    try check(codexFirst.id == codexSecond.id, "same (email, workspace) Codex should dedupe to same id")

    profiles = try store.loadProfiles()
    try check(profiles.count == 3, "Codex dedupe should leave 2 Claude + 1 Codex profiles")

    // Different workspace, same email → distinct Codex profile.
    _ = try store.upsert(
        tool: .codex,
        name: "Codex Other",
        slug: "codex-other",
        homeURL: home,
        isImported: false,
        emailAddress: "user@example.com",
        accountId: "chatgpt-acct-1",
        workspaceAccountId: "ws-2"
    )
    profiles = try store.loadProfiles()
    try check(profiles.count == 4, "different workspace with same email should be distinct")
}
