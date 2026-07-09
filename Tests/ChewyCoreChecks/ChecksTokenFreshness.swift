import ChewyCore
import Foundation

// Regression tests for the SAFE token-freshness pieces: re-capturing the OUTGOING
// account on swap (so a token rotated by a running CLI session is never stranded) and
// the upsert dedupe that makes Reconnect update in place. The proactive
// delegated-refresh of NON-ACTIVE accounts was removed — it rotated single-use refresh
// tokens and stranded the new ones, breaking switching.

/// Local swap environment (mirrors ChecksSliceC's private helper — kept local so this
/// file is self-contained).
private func makeFreshnessEnv(
    _ dir: URL
) -> (manager: CredentialSwapManager, vault: CredentialVault, runner: MockSecurityRunner, paths: CanonicalCredentialPaths, whoami: String) {
    let home = dir.appendingPathComponent("home", isDirectory: true)
    let paths = CanonicalCredentialPaths(
        claudeCredentialsFile: home.appendingPathComponent(".claude/.credentials.json"),
        claudeIdentityFile: home.appendingPathComponent(".claude.json"),
        codexAuthFile: home.appendingPathComponent(".codex/auth.json"),
        claudeKeychainService: "Claude Code-credentials"
    )
    let vault = CredentialVault(store: InMemoryCredentialStore())
    let runner = MockSecurityRunner()
    let whoami = "tester"
    let manager = CredentialSwapManager(
        securityRunner: runner,
        vault: vault,
        paths: paths,
        lockFileURL: dir.appendingPathComponent("locks/swap.lock"),
        whoami: whoami
    )
    return (manager, vault, runner, paths, whoami)
}

/// The outgoing account's freshly-rotated canonical is re-captured into ITS OWN vault
/// entry BEFORE we overwrite with the target, so switching back later never restores a
/// dead refresh token.
func checkSwapRecapturesOutgoing() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // --- Re-capture on swap: canonical belongs to A (rotated), we switch to B. ---
    do {
        let env = makeFreshnessEnv(root.appendingPathComponent("recapture"))
        let aStale = Data(#"{"claudeAiOauth":{"accessToken":"A-OLD","refreshToken":"A-RT-OLD"},"oauthAccount":{"accountUuid":"A-uuid","emailAddress":"a@x.com"}}"#.utf8)
        try env.vault.put(accountId: "A-uuid", VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "A-uuid",
            lastCanonicalHash: "stale-hash", blob: aStale
        ))
        let aRotated = #"{"claudeAiOauth":{"accessToken":"A-NEW","refreshToken":"A-RT-NEW"},"oauthAccount":{"accountUuid":"A-uuid","emailAddress":"a@x.com"}}"#
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: aRotated)
        try FileManager.default.createDirectory(at: env.paths.claudeIdentityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauthAccount":{"accountUuid":"A-uuid","emailAddress":"a@x.com"}}"#
            .write(to: env.paths.claudeIdentityFile, atomically: true, encoding: .utf8)
        let bBlob = Data(#"{"claudeAiOauth":{"accessToken":"B-TOK","refreshToken":"B-RT"},"oauthAccount":{"accountUuid":"B-uuid","emailAddress":"b@x.com"}}"#.utf8)
        try env.vault.put(accountId: "B-uuid", VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "B-uuid", blob: bBlob
        ))
        let b = AccountProfile(tool: .claude, name: "B", slug: "b", homePath: "", isImported: false, accountId: "B-uuid")

        try env.manager.swapToClaude(account: b)

        let aAfter = String(decoding: (try env.vault.get(accountId: "A-uuid"))?.blob ?? Data(), as: UTF8.self)
        try check(aAfter.contains("A-RT-NEW"), "outgoing account's rotated refresh token must be re-captured on swap")
        try check(!aAfter.contains("A-RT-OLD"), "outgoing account's stale refresh token must be replaced")
        let canonical = env.runner.current(service: env.paths.claudeKeychainService, account: env.whoami) ?? ""
        try check(canonical.contains("B-TOK"), "canonical should carry the target after swap")
    }

    // --- No prior canonical ({}) : swap is a no-op re-capture, no throw. ---
    do {
        let env = makeFreshnessEnv(root.appendingPathComponent("nocanon"))
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: #"{"claudeAiOauth":{}}"#)
        let bBlob = Data(#"{"claudeAiOauth":{"accessToken":"B","refreshToken":"B-RT"},"oauthAccount":{"accountUuid":"B2-uuid"}}"#.utf8)
        try env.vault.put(accountId: "B2-uuid", VaultEnvelope(tool: .claude, backend: "keychain", identityFingerprint: "B2-uuid", blob: bBlob))
        let b = AccountProfile(tool: .claude, name: "B2", slug: "b2", homePath: "", isImported: false, accountId: "B2-uuid")
        try env.manager.swapToClaude(account: b) // must not throw
        let canonical = env.runner.current(service: env.paths.claudeKeychainService, account: env.whoami) ?? ""
        try check(canonical.contains("\"accessToken\":\"B\""), "swap still writes the target when there's no prior canonical to re-capture")
    }

    // --- Malformed/partial canonical (matching uuid but NO refreshToken) must NOT
    //     overwrite the owner's vault entry (guards against vault corruption). ---
    do {
        let env = makeFreshnessEnv(root.appendingPathComponent("partial"))
        let aGood = Data(#"{"claudeAiOauth":{"accessToken":"A-GOOD","refreshToken":"A-RT-GOOD"},"oauthAccount":{"accountUuid":"AP-uuid"}}"#.utf8)
        try env.vault.put(accountId: "AP-uuid", VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "AP-uuid",
            lastCanonicalHash: "stale", blob: aGood
        ))
        let partial = #"{"claudeAiOauth":{"accessToken":"A-PARTIAL"},"oauthAccount":{"accountUuid":"AP-uuid"}}"#
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: partial)
        let bBlob = Data(#"{"claudeAiOauth":{"accessToken":"B","refreshToken":"B-RT"},"oauthAccount":{"accountUuid":"BP-uuid"}}"#.utf8)
        try env.vault.put(accountId: "BP-uuid", VaultEnvelope(tool: .claude, backend: "keychain", identityFingerprint: "BP-uuid", blob: bBlob))
        let b = AccountProfile(tool: .claude, name: "BP", slug: "bp", homePath: "", isImported: false, accountId: "BP-uuid")

        try env.manager.swapToClaude(account: b)

        let aAfter = String(decoding: (try env.vault.get(accountId: "AP-uuid"))?.blob ?? Data(), as: UTF8.self)
        try check(aAfter.contains("A-RT-GOOD"), "a partial canonical (no refreshToken) must NOT overwrite the good vault blob")
        try check(!aAfter.contains("A-PARTIAL"), "the vault must keep its valid credential, not the partial canonical")
    }
}

/// Reconnect updates in place even when organizationUuid is nil, by matching on the
/// stable accountId. Without this, re-login (fresh uniqueSlug) would duplicate.
func checkReconnectDedupe() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AccountProfileStore(paths: ChewyPaths(appSupportDirectory: dir))
    let home = dir.appendingPathComponent("home", isDirectory: true)

    let first = try store.upsert(
        tool: .claude, name: "Personal", slug: "personal", homeURL: home, isImported: false,
        emailAddress: "solo@x.com", organizationUuid: nil, accountId: "acct-uuid-1"
    )
    let second = try store.upsert(
        tool: .claude, name: "Personal", slug: "personal-2", homeURL: home, isImported: false,
        emailAddress: "solo@x.com", organizationUuid: nil, accountId: "acct-uuid-1"
    )
    try check(first.id == second.id, "same accountId (nil org) should update in place, same id")
    let profileCount = try store.loadProfiles().count
    try check(profileCount == 1, "Reconnect with nil org must NOT create a duplicate profile")
}

/// Newer Claude CLI keychain blobs carry NO embedded accountUuid — the identity
/// lives only in ~/.claude.json (written together with the credential). Every
/// capture path must pair the two, or a manual /login gets silently thrown away
/// (the exact bug: user re-signed-in, vault stayed stale, next switch restored a
/// dead token).
func checkNewFormatCanonicalCapture() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let env = makeFreshnessEnv(root)
    // Vault holds a STALE credential for account A.
    let stale = Data(#"{"claudeAiOauth":{"accessToken":"A-OLD","refreshToken":"A-RT-OLD"},"oauthAccount":{"accountUuid":"A-uuid","emailAddress":"a@example.com"}}"#.utf8)
    try env.vault.put(accountId: "A-uuid", VaultEnvelope(
        tool: .claude, backend: "keychain", identityFingerprint: "A-uuid",
        lastCanonicalHash: "stale", blob: stale
    ))
    // The user /login'd: the CLI wrote a NEW-FORMAT canonical (no accountUuid
    // anywhere in the blob) plus the identity file.
    let newFormat = #"{"claudeAiOauth":{"accessToken":"A-FRESH","refreshToken":"A-RT-FRESH","expiresAt":9999999999999}}"#
    env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: newFormat)
    try FileManager.default.createDirectory(at: env.paths.claudeIdentityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"oauthAccount":{"accountUuid":"A-uuid","emailAddress":"a@example.com"}}"#
        .write(to: env.paths.claudeIdentityFile, atomically: true, encoding: .utf8)

    try env.manager.captureCanonicalDrift()

    let after = String(decoding: (try env.vault.get(accountId: "A-uuid"))?.blob ?? Data(), as: UTF8.self)
    try check(after.contains("A-RT-FRESH"), "a new-format canonical must be captured via the identity file")
    try check(!after.contains("A-RT-OLD"), "the stale vault credential must be replaced")
    try check(after.contains("A-uuid"), "the captured vault blob must carry the paired identity")

    // Safety: with NO identity file and no embedded uuid, capture must no-op
    // (never guess an owner).
    try FileManager.default.removeItem(at: env.paths.claudeIdentityFile)
    let other = #"{"claudeAiOauth":{"accessToken":"B-???","refreshToken":"B-RT-???"}}"#
    env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: other)
    try env.manager.captureCanonicalDrift()
    let unchanged = String(decoding: (try env.vault.get(accountId: "A-uuid"))?.blob ?? Data(), as: UTF8.self)
    try check(unchanged.contains("A-RT-FRESH"), "an unattributable canonical must never be captured onto another account")
}

/// The heal gate must never let a delegated refresh race a live session's own
/// refresh (single-use tokens: the loser gets a forced /login). Safe cases only:
/// just-swapped (landing account was idle) or a canonical that nobody else is
/// rotating (stable across polls).
func checkHealGate() throws {
    let now = Date()
    func gate(armed: Bool = false, stable: Int = 0, inFlight: Bool = false,
              lastHealAgo: TimeInterval? = nil) -> Bool {
        HealGate.shouldHeal(
            armedBySwap: armed, stablePolls: stable, inFlight: inFlight,
            lastHealAt: lastHealAgo.map { now.addingTimeInterval(-$0) },
            cooldown: 300, now: now)
    }
    try check(gate(armed: true), "a heal armed by our own swap is safe (landing account was idle)")
    try check(!gate(stable: 1), "an unstable canonical means a live refresher may exist — wait")
    try check(!gate(stable: 2), "two stable polls are not yet proof of no live refresher")
    try check(gate(stable: 3), "a canonical stable across 3 polls has no live refresher — heal")
    try check(!gate(armed: true, inFlight: true), "never stack heals")
    try check(!gate(armed: true, lastHealAgo: 60), "cooldown still applies to armed heals")
    try check(gate(armed: true, lastHealAgo: 400), "cooldown released → armed heal proceeds")
    try check(!gate(), "steady state with a changing canonical never heals")
}
