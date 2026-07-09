import ChewyCore
import Foundation

// Hardening checks (public-launch audit): vault fail-safe on corrupt/future
// schema, removeAccount store-level semantics, and `security -i` token escaping.
// Pure — no real Keychain, no subprocesses, no network. Never embeds real tokens.

private func hardeningEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

/// (a) A consolidated vault item that is corrupt or written by a FUTURE schema
/// must fail safe: `get` throws (never silently reads as "no accounts"), and a
/// subsequent `put`/`delete` must throw rather than persist an empty/partial map
/// over the existing item.
func checkVaultFailSafeOnUndecodable() throws {
    // ----- Future schema: a schemaVersion 99 envelope in the consolidated item -----
    let futureStore = InMemoryCredentialStore()
    let futureEnvelope = VaultEnvelope(
        schemaVersion: 99,
        tool: .claude,
        backend: "keychain",
        email: "future@x.com",
        blob: Data("future-fixture".utf8)
    )
    let futurePayload = try hardeningEncoder()
        .encode(["acct-future": futureEnvelope])
        .base64EncodedString()
    try futureStore.saveSecret(futurePayload, account: "__vault__")

    let futureVault = CredentialVault(store: futureStore)
    var getThrew = false
    do {
        _ = try futureVault.get(accountId: "acct-future")
    } catch {
        getThrew = true
    }
    try check(getThrew, "get over a future-schema vault should throw, not read as empty")

    var putThrew = false
    do {
        try futureVault.put(
            accountId: "acct-new",
            VaultEnvelope(tool: .claude, backend: "keychain", blob: Data("n".utf8))
        )
    } catch {
        putThrew = true
    }
    try check(putThrew, "put over a future-schema vault should throw")
    let afterPut = try futureStore.readAllSecrets()["__vault__"]
    try check(
        afterPut == futurePayload,
        "future-schema consolidated item must remain byte-identical (never wiped)"
    )

    var deleteThrew = false
    do {
        try futureVault.delete(accountId: "acct-future")
    } catch {
        deleteThrew = true
    }
    try check(deleteThrew, "delete over a future-schema vault should throw")
    let afterDelete = try futureStore.readAllSecrets()["__vault__"]
    try check(
        afterDelete == futurePayload,
        "future-schema consolidated item must survive delete attempts"
    )

    // ----- Corrupt item: consolidated payload that does not decode at all -----
    let corruptStore = InMemoryCredentialStore()
    let corruptPayload = "%%%not-base64-not-json%%%"
    try corruptStore.saveSecret(corruptPayload, account: "__vault__")

    let corruptVault = CredentialVault(store: corruptStore)
    var corruptGetThrew = false
    do {
        _ = try corruptVault.get(accountId: "anything")
    } catch {
        corruptGetThrew = true
    }
    try check(corruptGetThrew, "get over a corrupt vault should throw, not read as empty")

    var corruptPutThrew = false
    do {
        try corruptVault.put(
            accountId: "acct-x",
            VaultEnvelope(tool: .codex, backend: "codex", blob: Data("c".utf8))
        )
    } catch {
        corruptPutThrew = true
    }
    try check(corruptPutThrew, "put over a corrupt vault should throw")
    let afterCorruptPut = try corruptStore.readAllSecrets()["__vault__"]
    try check(
        afterCorruptPut == corruptPayload,
        "corrupt consolidated item must not be overwritten with an empty map"
    )

    // Sanity: a CURRENT-schema vault still round-trips through the same paths.
    let okStore = InMemoryCredentialStore()
    let okVault = CredentialVault(store: okStore)
    try okVault.put(
        accountId: "acct-ok",
        VaultEnvelope(tool: .claude, backend: "keychain", email: "ok@x.com", blob: Data("ok".utf8))
    )
    let okEmail = try okVault.get(accountId: "acct-ok")?.email
    try check(okEmail == "ok@x.com", "current-schema vault should keep working")
}

/// (b) The AccountManager.removeAccount contract at the store level:
/// `store.removeProfiles` removes exactly the target profile and `vault.delete`
/// removes exactly the target envelope — everything else survives.
func checkRemoveAccountStoreSemantics() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let store = AccountProfileStore(paths: ChewyPaths(appSupportDirectory: temporaryDirectory))
    let vault = CredentialVault(store: InMemoryCredentialStore())
    let home = temporaryDirectory.appendingPathComponent("home", isDirectory: true)

    let keep = try store.upsert(
        tool: .claude,
        name: "Keep",
        slug: "keep",
        homeURL: home,
        isImported: false,
        emailAddress: "keep@x.com",
        organizationUuid: "org-keep",
        organizationName: "Org Keep",
        accountId: "uuid-keep"
    )
    let gone = try store.upsert(
        tool: .claude,
        name: "Gone",
        slug: "gone",
        homeURL: home,
        isImported: false,
        emailAddress: "gone@x.com",
        organizationUuid: "org-gone",
        organizationName: "Org Gone",
        accountId: "uuid-gone"
    )

    try vault.put(
        accountId: CredentialSwapManager.accountId(for: keep),
        VaultEnvelope(tool: .claude, backend: "keychain", email: "keep@x.com", blob: Data("k".utf8))
    )
    try vault.put(
        accountId: CredentialSwapManager.accountId(for: gone),
        VaultEnvelope(tool: .claude, backend: "keychain", email: "gone@x.com", blob: Data("g".utf8))
    )

    // The removeAccount contract: delete the vault envelope, remove the profile.
    try vault.delete(accountId: CredentialSwapManager.accountId(for: gone))
    _ = try store.removeProfiles(ids: [gone.id])

    let remaining = try store.loadProfiles()
    try check(remaining.count == 1, "removeProfiles should remove exactly one profile")
    try check(remaining.first?.id == keep.id, "the surviving profile should be the untouched one")
    let goneEnvelope = try vault.get(accountId: "uuid-gone")
    try check(goneEnvelope == nil, "vault.delete should remove the removed account's envelope")
    let keepEmail = try vault.get(accountId: "uuid-keep")?.email
    try check(keepEmail == "keep@x.com", "other accounts' envelopes must survive removal")
}

/// (c) `security -i` token escaping round-trips gnarly strings. A reference
/// un-escaper below implements the `-i` tokenizer rules that were verified
/// empirically against /usr/bin/security: inside double quotes, `\\` → `\` and
/// `\"` → `"`; a backslash before any other character is dropped.
func checkSecurityInteractiveEscaping() throws {
    /// Reference decoder for a single double-quote-wrapped `-i` token. Throws on
    /// any construction the tokenizer would misparse (e.g. an unescaped quote).
    func untokenize(_ escaped: String) throws -> String {
        try check(escaped.count >= 2, "escaped token must be at least the two wrapping quotes")
        try check(escaped.hasPrefix("\"") && escaped.hasSuffix("\""), "escaped token must be quote-wrapped")
        let inner = Array(escaped.dropFirst().dropLast())
        var out = ""
        var index = 0
        while index < inner.count {
            let character = inner[index]
            if character == "\\" {
                try check(index + 1 < inner.count, "dangling backslash would leak into the closing quote")
                let next = inner[index + 1]
                // Tokenizer rule: keep the char after a backslash, drop the backslash.
                out.append(next)
                index += 2
            } else {
                try check(character != "\"", "unescaped quote would terminate the token early")
                out.append(character)
                index += 1
            }
        }
        return out
    }

    let gnarlyFixtures: [String] = [
        // JSON-shaped fixture (NOT a real token) with the shapes real blobs carry.
        #"{"claudeAiOauth":{"accessToken":"FIXTURE-not-a-real-token","expiresAt":1750000000000},"oauthAccount":{"emailAddress":"a@b.com"}}"#,
        #"back\slash and double \\backslash"#,
        #"quotes "inside" and \"pre-escaped\""#,
        "spaces  and\ttabs and trailing space ",
        "unicode é ü 🏝 ✓ ✗",
        "$dollar `backtick` $(subshell) ;semicolon |pipe &ampersand *glob ~tilde",
        "{braces} [brackets] <angles> (parens) 100% #hash",
        "trailing backslash \\",
        "\\",
        "",
        String(repeating: #"\"q\" "#, count: 64)
    ]

    for fixture in gnarlyFixtures {
        let escaped = SystemSecurityRunner.escapeSecurityInteractiveToken(fixture)
        try check(escaped.hasPrefix("\"") && escaped.hasSuffix("\""), "escaped token should be quote-wrapped")
        try check(!escaped.contains("\n"), "escaping must never introduce a newline")
        let roundTripped = try untokenize(escaped)
        try check(roundTripped == fixture, "escaping must round-trip under the -i tokenizer rules")
    }

    // Pinned vectors: exact escaper output for the two special characters.
    try check(
        SystemSecurityRunner.escapeSecurityInteractiveToken(#"a\b"#) == #""a\\b""#,
        "backslash should escape to double-backslash"
    )
    try check(
        SystemSecurityRunner.escapeSecurityInteractiveToken(#"a"b"#) == #""a\"b""#,
        "double quote should escape to backslash-quote"
    )
}

/// Regression for the canonical-corruption incident: `security -i` SILENTLY
/// truncates its command line at 4096 bytes (a real credential blob was cut
/// mid-string). Three layers now guard the canonical:
///   1. oversized/control-char secrets never travel over `-i` (argv instead),
///   2. every canonical write is read back and rolled back on mismatch,
///   3. a swap target without refreshToken+identity is rejected up front.
func checkCanonicalWriteSafety() throws {
    // --- Layer 1: the -i/argv path decision is size- and content-aware. ---
    let small = SystemSecurityRunner.interactiveWriteCommand(
        service: "Claude Code-credentials", account: "dev", secret: #"{"k":"v"}"#)
    try check(small != nil, "a small clean secret should use the -i (stdin) path")
    try check(small!.utf8.count <= SystemSecurityRunner.interactiveCommandByteLimit,
              "composed -i command must respect the byte limit")

    let big = String(repeating: "x", count: 4000)
    try check(SystemSecurityRunner.interactiveWriteCommand(
        service: "s", account: "a", secret: big) == nil,
              "a secret near the 4096-byte -i line buffer must fall back to argv")
    // Escaping doubles \ and " — the LIMIT must apply to the ESCAPED length.
    let expander = String(repeating: "\"", count: 2500)
    try check(SystemSecurityRunner.interactiveWriteCommand(
        service: "s", account: "a", secret: expander) == nil,
              "escape expansion counts toward the -i byte limit")
    try check(SystemSecurityRunner.interactiveWriteCommand(
        service: "s", account: "a", secret: "line1\nline2") == nil,
              "control characters must fall back to argv")

    // --- Layers 2+3 exercise a real swap against a mock keychain. ---
    func makeEnv(_ dir: URL, runner: SecurityRunner) -> (CredentialSwapManager, CredentialVault) {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let paths = CanonicalCredentialPaths(
            claudeCredentialsFile: home.appendingPathComponent(".claude/.credentials.json"),
            claudeIdentityFile: home.appendingPathComponent(".claude.json"),
            codexAuthFile: home.appendingPathComponent(".codex/auth.json"),
            claudeKeychainService: "Claude Code-credentials"
        )
        let vault = CredentialVault(store: InMemoryCredentialStore())
        let manager = CredentialSwapManager(
            securityRunner: runner, vault: vault, paths: paths,
            lockFileURL: dir.appendingPathComponent("locks/swap.lock"), whoami: "tester"
        )
        return (manager, vault)
    }
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // Layer 3: a target whose blob has tokens but NO identity block must be
    // rejected BEFORE any write (this is the exact garbage entry that half-switched).
    do {
        let runner = MockSecurityRunner()
        let original = #"{"claudeAiOauth":{"accessToken":"KEEP","refreshToken":"KEEP-RT"}}"#
        runner.seed(service: "Claude Code-credentials", account: "tester", secret: original)
        let (manager, vault) = makeEnv(root.appendingPathComponent("noident"), runner: runner)
        try vault.put(accountId: "garbage", VaultEnvelope(
            tool: .claude, backend: "keychain",
            blob: Data(#"{"claudeAiOauth":{"accessToken":"T","refreshToken":"R"}}"#.utf8)))
        let target = AccountProfile(tool: .claude, name: "G", slug: "g", homePath: "", isImported: false, accountId: "garbage")
        var thrown: Error?
        do { try manager.swapToClaude(account: target) } catch { thrown = error }
        try check(thrown as? ChewyError == .credentialNeedsReconnect("g"),
                  "an identity-less vault blob must be rejected with credentialNeedsReconnect")
        try check(runner.current(service: "Claude Code-credentials", account: "tester") == original,
                  "pre-validation failure must leave the canonical byte-identical")
    }

    // Layer 2: a keychain that silently truncates writes → swap throws
    // canonicalWriteCorrupted and RESTORES the previous canonical.
    do {
        // Cap sits between the small original (survives the rollback write) and
        // the larger merged blob (gets truncated) — mirroring the real incident,
        // where the pre-corruption canonical was valid and the new write was cut.
        let runner = TruncatingSecurityRunner(maxBytes: 100)
        let original = #"{"claudeAiOauth":{"accessToken":"OLD","refreshToken":"OLD-RT"}}"#
        runner.seedRaw(service: "Claude Code-credentials", account: "tester", secret: original)
        let (manager, vault) = makeEnv(root.appendingPathComponent("trunc"), runner: runner)
        let longToken = String(repeating: "N", count: 120)
        try vault.put(accountId: "good-uuid", VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "good-uuid",
            blob: Data(#"{"claudeAiOauth":{"accessToken":"\#(longToken)","refreshToken":"NEW-RT"},"oauthAccount":{"accountUuid":"good-uuid","emailAddress":"a@example.com"}}"#.utf8)))
        let target = AccountProfile(tool: .claude, name: "A", slug: "a", homePath: "", isImported: false, accountId: "good-uuid")
        var thrown: Error?
        do { try manager.swapToClaude(account: target) } catch { thrown = error }
        try check(thrown as? ChewyError == .canonicalWriteCorrupted,
                  "a truncated canonical write must be detected and thrown")
        try check(runner.currentRaw(service: "Claude Code-credentials", account: "tester") == original,
                  "the previous canonical must be restored after a corrupted write")
    }
}

/// A SecurityRunner whose writes silently truncate (like `security -i` at its
/// 4096-byte line buffer) — but whose RESTORE-sized writes go through, so the
/// rollback path can be observed.
private final class TruncatingSecurityRunner: SecurityRunner {
    private var storage: [String: String] = [:]
    private let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    private func key(_ s: String, _ a: String) -> String { "\(s)\u{1}\(a)" }
    func read(service: String, account: String) throws -> String? { storage[key(service, account)] }
    func write(service: String, account: String, secret: String) throws {
        storage[key(service, account)] = String(secret.prefix(maxBytes))
    }
    func attributes(service: String, account: String) throws -> [String: String] {
        storage[key(service, account)] != nil ? ["svce": service] : [:]
    }
    func seedRaw(service: String, account: String, secret: String) { storage[key(service, account)] = secret }
    func currentRaw(service: String, account: String) -> String? { storage[key(service, account)] }
}

/// The persisted usage cache: safe round-trip (no secrets by construction — it
/// only carries UsageSnapshot percentages/dates) and staleness pruning, so a
/// relaunched app remembers which idle account was freshest instead of treating
/// every candidate as an equal unknown.
func checkUsageCache() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("usage-cache.json")
    let now = Date()

    let freshID = UUID(), staleID = UUID()
    func snap(_ pct: Double) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(label: "5-hour", usedPercent: pct,
                                            resetsAt: now.addingTimeInterval(3600))])
    }
    let cache = UsageCache(entries: [
        freshID: .init(snapshot: snap(3), fetchedAt: now.addingTimeInterval(-1800)),   // 30 min old
        staleID: .init(snapshot: snap(97), fetchedAt: now.addingTimeInterval(-6 * 3600)), // 6h old
    ])
    cache.save(to: url)

    // File must be private (0600) and valid JSON.
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    try check(mode?.intValue == 0o600, "usage cache file should be 0600")

    let loaded = UsageCache.load(from: url, now: now)
    try check(loaded.entries[freshID]?.snapshot.fiveHourWindow?.usedPercent == 3,
              "a 30-minute-old reading should survive the reload")
    try check(loaded.entries[staleID] == nil,
              "a reading older than the 5-hour horizon must be pruned on load")
    try check(loaded.snapshotsByAccount[freshID] != nil, "snapshotsByAccount should expose the seedable map")

    // Corrupt/missing files degrade to an empty cache, never a crash.
    try Data("not json".utf8).write(to: url)
    try check(UsageCache.load(from: url).entries.isEmpty, "corrupt cache file → empty cache")
    try check(UsageCache.load(from: dir.appendingPathComponent("missing.json")).entries.isEmpty,
              "missing cache file → empty cache")
}
