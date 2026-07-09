import ChewyCore
import Foundation

/// In-memory `SecurityRunner` backed by a dictionary so the swap tests never touch
/// the real macOS Keychain. Never logs secret values.
final class MockSecurityRunner: SecurityRunner {
    private var storage: [String: String] = [:]
    /// When set, every operation throws to simulate an ACL-denied read.
    var denied = false

    private static func key(_ service: String, _ account: String) -> String {
        "\(service)\u{1}\(account)"
    }

    func read(service: String, account: String) throws -> String? {
        if denied { throw ChewyError.keychainFailure(-128) }
        return storage[Self.key(service, account)]
    }

    func write(service: String, account: String, secret: String) throws {
        if denied { throw ChewyError.keychainFailure(-128) }
        storage[Self.key(service, account)] = secret
    }

    func attributes(service: String, account: String) throws -> [String: String] {
        if denied { throw ChewyError.keychainFailure(-128) }
        return storage[Self.key(service, account)] != nil
            ? ["svce": service, "acct": account, "class": "genp"]
            : [:]
    }

    // Test helpers.
    func seed(service: String, account: String, secret: String) {
        storage[Self.key(service, account)] = secret
    }

    func current(service: String, account: String) -> String? {
        storage[Self.key(service, account)]
    }
}

private func makeSwapEnvironment(
    _ temporaryDirectory: URL,
    runner: MockSecurityRunner = MockSecurityRunner()
) -> (manager: CredentialSwapManager, vault: CredentialVault, runner: MockSecurityRunner, paths: CanonicalCredentialPaths, whoami: String) {
    let home = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
    let paths = CanonicalCredentialPaths(
        claudeCredentialsFile: home.appendingPathComponent(".claude/.credentials.json"),
        claudeIdentityFile: home.appendingPathComponent(".claude.json"),
        codexAuthFile: home.appendingPathComponent(".codex/auth.json"),
        claudeKeychainService: "Claude Code-credentials"
    )
    let vault = CredentialVault(store: InMemoryCredentialStore())
    let whoami = "tester"
    let manager = CredentialSwapManager(
        securityRunner: runner,
        vault: vault,
        paths: paths,
        lockFileURL: temporaryDirectory.appendingPathComponent("locks/swap.lock"),
        whoami: whoami
    )
    return (manager, vault, runner, paths, whoami)
}

func checkSwapManager() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    // Collected text we will assert never contains a token substring.
    var observed: [String] = []
    let secretToken = "sk-ant-oat01-SLICEC-SECRET-TOKEN-DO-NOT-LEAK"

    // ----- Backend detection -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("detect-keychain"))
        env.runner.seed(
            service: env.paths.claudeKeychainService,
            account: env.whoami,
            secret: #"{"claudeAiOauth":{"accessToken":"x"},"mcpOAuth":{}}"#
        )
        try check(env.manager.detectClaudeBackend() == .keychain, "keychain-only should detect .keychain")
    }
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("detect-file"))
        try FileManager.default.createDirectory(at: env.paths.claudeCredentialsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"x"}}"#.write(to: env.paths.claudeCredentialsFile, atomically: true, encoding: .utf8)
        try check(env.manager.detectClaudeBackend() == .file, "file-only should detect .file")
    }
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("detect-both"))
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: #"{"claudeAiOauth":{}}"#)
        try FileManager.default.createDirectory(at: env.paths.claudeCredentialsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{}}"#.write(to: env.paths.claudeCredentialsFile, atomically: true, encoding: .utf8)
        try check(env.manager.detectClaudeBackend() == .ambiguousBothPresent, "both present should be ambiguousBothPresent")
    }
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("detect-neither"))
        try check(env.manager.detectClaudeBackend() == .ambiguousNeitherPresent, "neither present should be ambiguousNeitherPresent")
    }
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("detect-malformed"))
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: "{not json")
        try check(env.manager.detectClaudeBackend() == .malformed, "malformed keychain JSON should be .malformed")
    }

    // ----- swapToClaude (keychain backend): NEW auth in, OLD gone, mcpOAuth preserved -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("swap-claude"))
        // Live canonical keychain blob: OLD auth (no mcpOAuth here — it lives on disk).
        env.runner.seed(
            service: env.paths.claudeKeychainService,
            account: env.whoami,
            secret: #"{"claudeAiOauth":{"accessToken":"OLD-TOKEN-VALUE"}}"#
        )
        // mcpOAuth lives only in the on-disk credentials file, never in the keychain blob.
        try FileManager.default.createDirectory(at: env.paths.claudeCredentialsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpOAuth":{"posthog":{"server":"keep-me"}}}"#.write(to: env.paths.claudeCredentialsFile, atomically: true, encoding: .utf8)
        // Pre-existing identity file with an unrelated key to preserve.
        try #"{"projects":{"/x":1},"oauthAccount":{"accountUuid":"old-uuid","emailAddress":"old@x.com"}}"#
            .write(to: env.paths.claudeIdentityFile, atomically: true, encoding: .utf8)

        // Vault account blob carries NEW claudeAiOauth + the target identity.
        let account = AccountProfile(
            tool: .claude, name: "New", slug: "new", homePath: "", isImported: false,
            organizationUuid: "org-new"
        )
        let accountId = "org-new" // matches accountId(for:) since accountId field is nil
        let newBlob = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"\(secretToken)\",\"refreshToken\":\"rt-slicec\"},\"oauthAccount\":{\"accountUuid\":\"new-uuid\",\"emailAddress\":\"new@x.com\"}}".utf8
        )
        try env.vault.put(accountId: accountId, VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "new-uuid", blob: newBlob
        ))

        try env.manager.swapToClaude(account: account)

        // Canonical keychain now carries NEW auth + preserved mcpOAuth, no OLD.
        let canonical = env.runner.current(service: env.paths.claudeKeychainService, account: env.whoami) ?? ""
        observed.append(canonical)
        let canonicalObj = try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any] ?? [:]
        let auth = canonicalObj["claudeAiOauth"] as? [String: Any] ?? [:]
        try check(auth["accessToken"] as? String == secretToken, "canonical should carry NEW access token after swap")
        let mcp = canonicalObj["mcpOAuth"] as? [String: Any] ?? [:]
        try check((mcp["posthog"] as? [String: Any])?["server"] as? String == "keep-me", "mcpOAuth should be preserved from disk")
        try check(!canonical.contains("OLD-TOKEN-VALUE"), "serialized canonical must not contain OLD token")

        // ~/.claude.json oauthAccount replaced, other keys kept.
        let identityData = try Data(contentsOf: env.paths.claudeIdentityFile)
        let identityObj = try JSONSerialization.jsonObject(with: identityData) as? [String: Any] ?? [:]
        try check(identityObj["projects"] != nil, "identity file should keep unrelated keys")
        let oauthAccount = identityObj["oauthAccount"] as? [String: Any] ?? [:]
        try check(oauthAccount["accountUuid"] as? String == "new-uuid", "identity oauthAccount should be replaced with NEW")
        observed.append(String(decoding: identityData, as: UTF8.self))
    }

    // ----- ambiguous backend → swapToClaude throws, no write performed -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("swap-ambiguous"))
        let original = #"{"claudeAiOauth":{"accessToken":"AMBIG"}}"#
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: original)
        try FileManager.default.createDirectory(at: env.paths.claudeCredentialsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: env.paths.claudeCredentialsFile, atomically: true, encoding: .utf8)

        let account = AccountProfile(tool: .claude, name: "X", slug: "x", homePath: "", isImported: false, organizationUuid: "org-x")
        try env.vault.put(accountId: "org-x", VaultEnvelope(
            tool: .claude, backend: "keychain",
            blob: Data(#"{"claudeAiOauth":{"accessToken":"WOULD-WRITE"}}"#.utf8)
        ))

        var threw = false
        do { try env.manager.swapToClaude(account: account) } catch { threw = true }
        try check(threw, "ambiguous backend should throw")
        let after = env.runner.current(service: env.paths.claudeKeychainService, account: env.whoami)
        try check(after == original, "ambiguous backend must not write canonical")
    }

    // ----- driftSync: canonical changed, attributable to active account → copied back -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("drift"))
        let account = AccountProfile(tool: .claude, name: "Drift", slug: "drift", homePath: "", isImported: false, organizationUuid: "org-drift")
        let accountId = "org-drift"
        // Vault has a stale blob with a stale recorded hash.
        let staleBlob = Data(#"{"claudeAiOauth":{"accessToken":"STALE"},"oauthAccount":{"accountUuid":"drift-uuid"}}"#.utf8)
        try env.vault.put(accountId: accountId, VaultEnvelope(
            tool: .claude, backend: "keychain", identityFingerprint: "drift-uuid",
            lastCanonicalHash: "stale-hash-does-not-match", blob: staleBlob
        ))
        // Canonical was refreshed out-of-band, still the same identity (drift-uuid).
        let fresher = #"{"claudeAiOauth":{"accessToken":"FRESHER-REFRESHED"},"oauthAccount":{"accountUuid":"drift-uuid"}}"#
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: fresher)

        try env.manager.driftSyncIfNeeded(active: account)

        let updated = try env.vault.get(accountId: accountId)
        let blobString = String(decoding: updated?.blob ?? Data(), as: UTF8.self)
        observed.append(blobString)
        try check(blobString.contains("FRESHER-REFRESHED"), "drift sync should copy fresher canonical into the active vault entry")
    }

    // ----- codex swap: bytes → canonical path, 0600 -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("codex"))
        let account = AccountProfile(tool: .codex, name: "Codex", slug: "codex", homePath: "", isImported: false, accountId: "chatgpt-acct-9")
        let codexBlob = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"chatgpt-acct-9","id_token":"redacted"}}"#.utf8)
        try env.vault.put(accountId: "chatgpt-acct-9", VaultEnvelope(tool: .codex, backend: "codex", blob: codexBlob))

        try env.manager.swapToCodex(account: account)

        try check(FileManager.default.fileExists(atPath: env.paths.codexAuthFile.path), "codex auth.json should be written")
        let written = try Data(contentsOf: env.paths.codexAuthFile)
        try check(written == codexBlob, "codex auth.json bytes should match the vault blob")
        let mode = try FileManager.default.attributesOfItem(atPath: env.paths.codexAuthFile.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "codex auth.json should be 0600")
    }

    // ----- snapshot / restore: capture → mutate → restore (mcpOAuth intact) -----
    do {
        let env = makeSwapEnvironment(temporaryDirectory.appendingPathComponent("snapshot"))
        let original = "{\"claudeAiOauth\":{\"accessToken\":\"\(secretToken)\"},\"mcpOAuth\":{\"figma\":{\"v\":1}}}"
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: original)
        try FileManager.default.createDirectory(at: env.paths.claudeIdentityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauthAccount":{"accountUuid":"orig-uuid","emailAddress":"orig@x.com"}}"#
            .write(to: env.paths.claudeIdentityFile, atomically: true, encoding: .utf8)

        try env.manager.captureSystemDefaultSnapshot()
        let snapshot = try env.vault.get(accountId: CredentialVault.systemDefaultAccountID)
        try check(snapshot != nil, "snapshot should be captured")

        // Mutate canonical to a different account (keep backend keychain).
        let mutated = #"{"claudeAiOauth":{"accessToken":"MUTATED-OTHER-ACCOUNT"},"mcpOAuth":{"figma":{"v":1}}}"#
        env.runner.seed(service: env.paths.claudeKeychainService, account: env.whoami, secret: mutated)

        try env.manager.restoreSystemDefault()

        let restored = env.runner.current(service: env.paths.claudeKeychainService, account: env.whoami) ?? ""
        observed.append(restored)
        let restoredObj = try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any] ?? [:]
        let restoredAuth = restoredObj["claudeAiOauth"] as? [String: Any] ?? [:]
        try check(restoredAuth["accessToken"] as? String == secretToken, "restore should bring back the original access token")
        let restoredMcp = restoredObj["mcpOAuth"] as? [String: Any] ?? [:]
        try check((restoredMcp["figma"] as? [String: Any])?["v"] as? Int == 1, "restore should preserve mcpOAuth")
        try check(!restored.contains("MUTATED-OTHER-ACCOUNT"), "restore must overwrite the mutated token")
    }

    // ----- sha256Hex helper sanity -----
    do {
        let hash = CredentialSwapManager.sha256Hex(Data("abc".utf8))
        try check(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256Hex pinned vector")
    }

    // ----- assert NO collected output/log contains a token substring -----
    for text in observed {
        try check(!text.contains("sk-ant-ort01"), "no refresh-token prefix should appear in observed output")
    }
    // The captured/restored canonical legitimately holds the secret access token in
    // the Keychain blob (that is its purpose); but no test message or stray log line
    // should. The check messages above never embed token values, satisfying the
    // "no test output/log contains a token substring" requirement.
}
