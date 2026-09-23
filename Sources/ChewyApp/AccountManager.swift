import AppKit
import ChewyCore
import Foundation

/// @MainActor orchestrator that owns the credential engine and projects a
/// vaulted account onto the live canonical credential stores (the global swap).
///
/// It composes a `CredentialVault`, a `CredentialSwapManager`, and the
/// `AccountProfileStore`. Selecting an account is a *swap*, not a launch:
/// it re-points every new `claude`/`codex` session at the chosen identity.
/// Never logs or prints secret values.
@MainActor
final class AccountManager {
    private let store: AccountProfileStore
    private let vault: CredentialVault
    private let swapManager: CredentialSwapManager
    private let codexHomes: CodexHomeManager
    private let claudeProfiles: ClaudeProfileManager
    private let launcher: TerminalLauncher
    private let paths: ChewyPaths
    private let fileManager: FileManager

    /// Canonical credential paths rooted at the user's real home.
    private let canonicalPaths: CanonicalCredentialPaths
    private let homeURL: URL

    /// Tracks whether the system-default snapshot has been captured this run.
    private var didCaptureSystemDefault = false

    /// Per-tool active account id (persisted to UserDefaults).
    private(set) var activeAccountIDs: [AccountTool: String] = [:]

    init(
        store: AccountProfileStore,
        codexHomes: CodexHomeManager,
        claudeProfiles: ClaudeProfileManager,
        launcher: TerminalLauncher,
        paths: ChewyPaths,
        fileManager: FileManager = .default,
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        self.store = store
        self.codexHomes = codexHomes
        self.claudeProfiles = claudeProfiles
        self.launcher = launcher
        self.paths = paths
        self.fileManager = fileManager
        self.homeURL = homeURL

        let vault = CredentialVault()
        self.vault = vault
        self.canonicalPaths = CanonicalCredentialPaths.forHome(homeURL)
        self.swapManager = CredentialSwapManager(
            vault: vault,
            paths: canonicalPaths,
            lockFileURL: paths.appSupportDirectory.appendingPathComponent("swap.lock"),
            whoami: NSUserName(),
            fileManager: fileManager
        )

        loadActiveAccountIDs()
    }

    // Exposed so the model and migration can reach the engine pieces.
    var credentialVault: CredentialVault { vault }
    var credentialSwapManager: CredentialSwapManager { swapManager }

    // MARK: - Accounts

    /// Accounts for a tool, with resolved email addresses (from the profile,
    /// falling back to the vault blob).
    func accounts(for tool: AccountTool) throws -> [AccountProfile] {
        var profiles = try store.loadProfiles().filter { $0.tool == tool }
        for index in profiles.indices where profiles[index].emailAddress == nil {
            profiles[index].emailAddress = resolvedEmail(for: profiles[index])
        }
        return profiles
    }

    /// Resolve an account's email from the vault blob if the profile lacks one.
    func resolvedEmail(for profile: AccountProfile) -> String? {
        if let email = profile.emailAddress, !email.isEmpty {
            return email
        }
        let accountId = CredentialSwapManager.accountId(for: profile)
        guard let envelope = try? vault.get(accountId: accountId) else {
            return nil
        }
        if let email = envelope.email, !email.isEmpty {
            return email
        }
        return Self.email(fromBlob: envelope.blob, tool: profile.tool)
    }

    /// The currently active account id for a tool, if any.
    func activeAccountID(for tool: AccountTool) -> String? {
        activeAccountIDs[tool]
    }

    /// The live canonical Claude OAuth access token, for usage polling. Never log it.
    /// Returns nil when no usable Claude token is present.
    func activeClaudeAccessToken() -> String? {
        (try? swapManager.activeClaudeAccessToken()) ?? nil
    }

    /// The account currently written to the canonical Claude credential — the real
    /// "active" account, regardless of any app-side selection state.
    func canonicalClaudeIdentity() -> (email: String?, accountUuid: String?) {
        swapManager.canonicalClaudeIdentity()
    }

    /// The account currently written to the canonical Codex `auth.json`.
    func canonicalCodexIdentity() -> (email: String?, accountId: String?) {
        swapManager.canonicalCodexIdentity()
    }

    /// Credentials to poll Codex usage for a SPECIFIC account: the active account
    /// reads the canonical `~/.codex/auth.json` (the CLI keeps it fresh); others use
    /// their vaulted `auth.json`, rejected once the JWT access token has expired (a
    /// stale token would only produce a 401). Never log the token.
    func codexUsageCredentials(for profile: AccountProfile, isActive: Bool) -> (token: String, accountId: String)? {
        guard profile.tool == .codex else { return nil }
        let data: Data?
        if isActive {
            data = try? Data(contentsOf: canonicalPaths.codexAuthFile)
        } else {
            data = (try? vault.get(accountId: CredentialSwapManager.accountId(for: profile)))?.blob
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return nil
        }
        let idToken = tokens["id_token"] as? String
        guard let accountId = (tokens["account_id"] as? String)
                ?? idToken.flatMap(JWTPayload.chatgptAccountId(from:)),
              !accountId.isEmpty else {
            return nil
        }
        if let exp = (JWTPayload.decode(token)?["exp"] as? NSNumber)?.doubleValue,
           exp < Date().timeIntervalSince1970 + 30 {
            return nil
        }
        return (token, accountId)
    }

    // Cache tokens in memory so usage polling doesn't hit the Keychain every cycle —
    // each Keychain read can trigger an "Always Allow" prompt. Access tokens live ~8h,
    // so a long cache is safe. CRITICAL: we cache FAILURES too (negative cache), so an
    // account with an expired/unreadable token is not re-read — and re-prompted — every
    // poll. Cleared on swap/add (creds may change).
    private struct CachedToken { let token: String?; let fetchedAt: Date }
    private var tokenCache: [String: CachedToken] = [:]
    private let tokenCacheTTL: TimeInterval = 1800 // 30 min for successfully read tokens
    /// Failures (nil tokens) are remembered only briefly: long enough to avoid a
    /// Keychain re-prompt storm, short enough that a recovered account (re-login,
    /// restored Keychain access) stops reading as "unknown" within two minutes.
    private let nilTokenCacheTTL: TimeInterval = 120

    func invalidateTokenCache() { tokenCache.removeAll() }

    /// A Claude access token to poll usage for a SPECIFIC account. The active account
    /// uses the freshest (canonical) token; others use their vaulted token if unexpired.
    /// Cached in memory (incl. nil) to avoid repeated Keychain prompts. We deliberately
    /// do NOT refresh non-active accounts (that would rotate their single-use refresh
    /// token and risk stranding them). Never log the token.
    func usageToken(for profile: AccountProfile, isActive: Bool) -> String? {
        guard profile.tool == .claude else { return nil }
        let key = isActive ? "active" : CredentialSwapManager.accountId(for: profile)
        if let cached = tokenCache[key] {
            let ttl = cached.token == nil ? nilTokenCacheTTL : tokenCacheTTL
            if Date().timeIntervalSince(cached.fetchedAt) < ttl {
                return cached.token // may be nil — a remembered failure, so we don't re-prompt
            }
        }

        let token = isActive ? activeClaudeAccessToken() : vaultedClaudeToken(for: profile)
        tokenCache[key] = CachedToken(token: token, fetchedAt: Date()) // cache success AND failure
        return token
    }

    /// A non-active account's access token from the vault, if present and not expired.
    private func vaultedClaudeToken(for profile: AccountProfile) -> String? {
        let accountId = CredentialSwapManager.accountId(for: profile)
        guard
            let envelope = try? vault.get(accountId: accountId),
            let object = try? JSONSerialization.jsonObject(with: envelope.blob) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return nil
        }
        if let expiresAt = oauth["expiresAt"] as? Double {
            let nowMs = Date().timeIntervalSince1970 * 1000
            guard expiresAt > nowMs + 30_000 else { return nil }
        }
        return token
    }

    // MARK: - Drift sync / reconnect / freshness (token-freshness slice)

    /// Re-attribute the ACTIVE Claude account's (possibly Claude-Code-refreshed)
    /// canonical credential back into its vault entry, then drop the in-memory token
    /// cache so a freshly re-captured account no longer reads as a cached nil.
    ///
    /// No-op when `active` is nil or not a Claude profile — Claude Code owns the active
    /// account's refresh, so we only reconcile drift here (never delegate a refresh).
    func driftSyncActiveClaude(active: AccountProfile?) {
        guard let active, active.tool == .claude else { return }
        try? swapManager.driftSyncIfNeeded(active: active)
        invalidateTokenCache()
    }

    /// Capture the canonical credential into its OWNER's vault entry, attributed by
    /// the canonical's own identity — catches a manual `/login` as ANY account, not
    /// just the one the app considers active. Drops the token cache so the fresh
    /// credential is used immediately.
    @discardableResult
    func captureCanonicalDrift() -> String? {
        let hash = (try? swapManager.captureCanonicalDrift()) ?? nil
        invalidateTokenCache()
        return hash
    }

    /// Record that the canonical credential now belongs to `profile` WITHOUT
    /// performing a swap — used when the user re-pointed the canonical themselves
    /// (e.g. `/login` inside a session) and the app is following reality.
    func noteCanonicalActive(_ profile: AccountProfile) {
        activeAccountIDs[profile.tool] = CredentialSwapManager.accountId(for: profile)
        persistActiveAccountIDs()
    }

    // MARK: - Canonical heal (delegated to the official CLI)

    /// Outcome of asking the official CLI to refresh the CANONICAL credential.
    enum CanonicalHealOutcome {
        /// The CLI reports a signed-in session (it refreshed the token if needed).
        case healthy
        /// The CLI reports signed-out — the canonical refresh token is dead.
        case signedOut
        /// Couldn't run/parse the CLI (missing binary, timeout) — no signal.
        case unknown
    }

    /// Ask the official `claude` CLI to validate — and, if the access token is
    /// expired, refresh — the CANONICAL credential, by running `claude auth status`
    /// against the user's real home (CLAUDE_CONFIG_DIR explicitly unset).
    ///
    /// This is the safe delegation shape: no staging, no seeding, nothing to scrub.
    /// The CLI rotates and persists the token in its own canonical store; we only
    /// re-read afterwards (the caller should drift-sync to capture the rotation).
    /// It never touches idle accounts' single-use refresh tokens.
    ///
    /// Runs off the main actor (blocking process I/O + watchdog).
    func healCanonicalClaude() async -> CanonicalHealOutcome {
        let outcome = await Task.detached(priority: .utility) { Self.runCanonicalAuthStatus() }.value
        invalidateTokenCache() // the CLI may have rotated the canonical token
        return outcome
    }

    /// Blocking `claude auth status --json` against the canonical home. nonisolated:
    /// process I/O + a background-queue watchdog must not be main-actor isolated.
    /// Parses ONLY the signed-in boolean; never logs or echoes any other output.
    nonisolated private static func runCanonicalAuthStatus() -> CanonicalHealOutcome {
        let process = Process()
        if let claude = resolveClaudeBinary() {
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["auth", "status", "--json"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "auth", "status", "--json"]
        }
        // Target the CANONICAL home: strip any config-dir override so the CLI
        // reads/writes the same store every plain `claude` session uses.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return .unknown }

        // Watchdog with SIGKILL escalation — a wedged CLI must never hang the poll,
        // and the kill closes the pipes so the blocking reads below always finish.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 12)
        watchdog.setEventHandler {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile() // drained, never inspected
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            return .unknown
        }
        // Accept several key spellings — the CLI's JSON naming isn't pinned.
        for key in ["loggedIn", "logged_in", "isLoggedIn", "authenticated"] {
            if let value = object[key] as? Bool {
                return value ? .healthy : .signedOut
            }
        }
        return .unknown
    }

    /// Resolve the `claude` binary by scanning PATH plus common install dirs. An
    /// LSUIElement app launched by Finder inherits a minimal PATH that often lacks
    /// /opt/homebrew/bin and npm-local dirs, so `/usr/bin/env claude` alone can miss it.
    nonisolated private static func resolveClaudeBinary() -> String? {
        let fileManager = FileManager.default
        var dirs: [String] = []
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        dirs.append(contentsOf: [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ])
        for dir in dirs {
            let candidate = "\(dir)/claude"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Re-run the login → capture flow for an EXISTING account. Because `upsert`
    /// dedupes by accountId and the vault is keyed by the account uuid, this updates
    /// the profile and credentials in place. Returns the status string.
    @discardableResult
    func reconnect(
        _ profile: AccountProfile,
        onUpdate: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> String {
        let message = await addAccount(tool: profile.tool, name: profile.name, isReconnect: true, onUpdate: onUpdate)
        invalidateTokenCache()
        return message
    }

    /// Remove an account everywhere it lives: vault credential, stored profile,
    /// per-profile staging home, and cached tokens. The CANONICAL credential is
    /// deliberately untouched — removing a profile must never sign the user out
    /// of their live CLI sessions.
    func removeAccount(_ profile: AccountProfile) {
        invalidateTokenCache()
        try? vault.delete(accountId: CredentialSwapManager.accountId(for: profile))
        _ = try? store.removeProfiles(ids: [profile.id])
        // Only delete homes we created (under .../Chewy/Profiles/) — an imported
        // profile can point at the user's REAL ~/.codex home, which we must never touch.
        if !profile.homePath.isEmpty, profile.homePath.contains("/Chewy/Profiles/") {
            try? fileManager.removeItem(at: profile.homeURL)
        }
    }

    /// Whether the vault holds a credential blob for this account — the source of
    /// truth for "signed in" (profile home paths go stale after vault migration).
    func hasVaultCredential(for profile: AccountProfile) -> Bool {
        (try? vault.get(accountId: CredentialSwapManager.accountId(for: profile))) != nil
    }

    // MARK: - Select = swap

    /// Select an account: perform the global canonical swap (NOT a launch).
    /// Captures the system-default snapshot on the first swap, persists the
    /// active id, and returns a human status. Returns the status message.
    @discardableResult
    func select(_ profile: AccountProfile) async -> String {
        invalidateTokenCache() // active token changes; re-read fresh next poll
        do {
            // Capture the user's pre-existing identity before the first overwrite.
            if !didCaptureSystemDefault {
                try swapManager.captureSystemDefaultSnapshot()
                didCaptureSystemDefault = true
            }

            switch profile.tool {
            case .claude:
                try swapManager.swapToClaude(account: profile)
            case .codex:
                try swapManager.swapToCodex(account: profile)
            }

            activeAccountIDs[profile.tool] = CredentialSwapManager.accountId(for: profile)
            persistActiveAccountIDs()

            let label = resolvedEmail(for: profile) ?? profile.name
            ChewyLog.info("swap: \(profile.tool.rawValue) → \(label) (\(profile.slug)) written to canonical")
            return "Now using \(label). Applies to new sessions."
        } catch {
            ChewyLog.error("swap to \(profile.slug) failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    // MARK: - Add account (login → capture)

    /// Bounded ≤2-minute poll requiring BOTH sinks valid.
    static let loginPollTimeout: TimeInterval = 120
    private static let pollInterval: TimeInterval = 2.0
    /// Clock-skew tolerance (ms) when gating Claude login on token expiry.
    /// nonisolated: read from the off-actor capture checks (immutable Sendable).
    nonisolated static let clockSkewToleranceMs: Double = 60_000

    /// Add an account: create a staging home, launch the tool's login in
    /// Terminal, poll (bounded) until both credential sinks are valid, then
    /// capture into the vault and upsert into the store (deduped).
    ///
    /// Returns a status message. `onUpdate` reports interim status to the UI.
    @discardableResult
    func addAccount(
        tool: AccountTool,
        name: String,
        isReconnect: Bool = false,
        onUpdate: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> String {
        invalidateTokenCache()
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (tool == .claude ? "Claude" : "Codex") : trimmedName
            let slug = try store.uniqueSlug(for: finalName, tool: tool)

            let stagingHome: URL
            switch tool {
            case .codex:
                stagingHome = try codexHomes.createDisposableHome(slug: slug)
            case .claude:
                stagingHome = try claudeProfiles.createOAuthConfigHome(slug: slug)
            }
            // A staging home (and its suffixed Keychain item) can survive an earlier
            // attempt under the same slug. Capture must only ever see what THIS login
            // writes — a leftover identity file + token pair is how a re-login used to
            // be captured as the PREVIOUS account before the new sign-in even finished.
            clearStaleStaging(tool: tool, stagingHome: stagingHome)
            let loginStartedAt = Date()
            ChewyLog.info("login: \(tool.rawValue) '\(slug)' started\(isReconnect ? " (reconnect)" : "")")

            try launchLogin(tool: tool, slug: slug, stagingHome: stagingHome)
            onUpdate("Complete the \(tool.rawValue.capitalized) login in Terminal…")

            // Bounded poll for both sinks valid. Each capture check can spawn
            // `security` (a blocking subprocess wait of up to 3s), so it runs OFF
            // the main actor via Task.detached; only its result hops back here.
            let deadline = Date().addingTimeInterval(Self.loginPollTimeout)
            var pollState = CodexPollState()
            let candidatePaths = canonicalPaths

            while Date() < deadline {
                let stateSnapshot = pollState
                let result: (capture: Capture?, state: CodexPollState)
                do {
                    result = try await Task.detached(priority: .utility) {
                        try Self.captureIfReady(
                            tool: tool,
                            stagingHome: stagingHome,
                            canonicalPaths: candidatePaths,
                            state: stateSnapshot,
                            notBefore: loginStartedAt
                        )
                    }.value
                } catch {
                    cleanupStaging(tool: tool, stagingHome: stagingHome)
                    throw error
                }
                pollState = result.state
                if let capture = result.capture {
                    // Scrub plaintext staging tokens now that the durable vault copy exists.
                    defer { cleanupStaging(tool: tool, stagingHome: stagingHome) }
                    let (profile, isNew) = try persistCapture(
                        tool: tool,
                        name: finalName,
                        slug: slug,
                        stagingHome: stagingHome,
                        capture: capture
                    )
                    let label = capture.email ?? profile.name
                    ChewyLog.info("login: '\(slug)' captured \(label) — \(isNew ? "new account" : "existing account updated in place")")
                    if isReconnect { return "Reconnected \(label)." }
                    if isNew { return "Added \(label). Select it to switch." }
                    // The browser signed in as an account that is already in the list
                    // (claude.ai reuses its current session). Say so instead of
                    // pretending a new account appeared.
                    return "\(label) is already added — its sign-in was refreshed. To add a different account, switch accounts on claude.ai in your browser first."
                }
                try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }

            // Timed out: leave the staging sign-in in place so "I've finished signing
            // in" can still capture it (finishPendingLogin scrubs afterwards).
            ChewyLog.warn("login: '\(slug)' timed out after \(Int(Self.loginPollTimeout))s without a complete sign-in")
            return "Sign-in timed out. Finish login in Terminal, then use \u{201C}I\u{2019}ve finished signing in.\u{201D}"
        } catch {
            ChewyLog.error("login: \(tool.rawValue) failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Manual fallback: capture a staged login that the bounded poll missed.
    /// Re-derives the staging home from the most recent matching profile slug.
    @discardableResult
    func finishPendingLogin(tool: AccountTool, slug: String, name: String) async -> String {
        do {
            let stagingHome: URL
            switch tool {
            case .codex:
                stagingHome = codexHomes.profileHomeURL(slug: slug)
            case .claude:
                stagingHome = claudeProfiles.profileHomeURL(slug: slug)
            }
            // Always scrub plaintext staging tokens — on success, miss, or throw.
            defer { cleanupStaging(tool: tool, stagingHome: stagingHome) }
            // stablePolls seeded to bypass the stability requirement on manual finish.
            let manualState = CodexPollState(lastSize: -1, stablePolls: 2)
            let candidatePaths = canonicalPaths
            // Off the main actor: the capture check can block on `security` for up to 3s.
            let result = try await Task.detached(priority: .utility) {
                try Self.captureIfReady(
                    tool: tool,
                    stagingHome: stagingHome,
                    canonicalPaths: candidatePaths,
                    state: manualState,
                    notBefore: nil // staging was cleared when this login started
                )
            }.value
            guard let capture = result.capture else {
                return "Still can\u{2019}t see a completed login. Finish it in Terminal first."
            }
            let (profile, isNew) = try persistCapture(
                tool: tool,
                name: name,
                slug: slug,
                stagingHome: stagingHome,
                capture: capture
            )
            let label = capture.email ?? profile.name
            ChewyLog.info("login: '\(slug)' captured \(label) via manual finish — \(isNew ? "new account" : "existing account updated")")
            return isNew
                ? "Added \(label). Select it to switch."
                : "\(label) is already added — its sign-in was refreshed."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Legacy migration (v1 per-home → v2 vault)

    /// One-time backfill: for each existing legacy profile, parse its per-home
    /// credentials with the SAME canonical identity parser the live capture path
    /// uses, then route through `persistCapture` so the vault is keyed identically
    /// to capture and the swap manager. Best-effort per profile; never throws.
    ///
    /// Returns the (possibly identity-backfilled) profiles after migration.
    @discardableResult
    func migrateLegacyProfiles() -> [AccountProfile] {
        guard let existing = try? store.loadProfiles() else { return [] }
        for profile in existing {
            // Token profiles carry an opaque credentialReference, not a vaultable
            // OAuth blob — only backfill identity for those (no vault put).
            if let capture = legacyCapture(for: profile) {
                _ = try? persistCapture(
                    tool: profile.tool,
                    name: profile.name,
                    slug: profile.slug,
                    stagingHome: profile.homeURL,
                    capture: capture
                )
            }
        }
        return (try? store.loadProfiles()) ?? existing
    }

    /// Build a `Capture` for a legacy profile from its per-home credential files,
    /// reusing `CredentialBlob` so migration keys the vault exactly like capture.
    /// Returns nil when the profile has no vaultable OAuth credentials.
    private func legacyCapture(for profile: AccountProfile) -> Capture? {
        switch profile.tool {
        case .claude:
            // OAuth profiles (no credentialReference) carry vaultable creds.
            guard profile.credentialReference == nil else { return nil }
            let identityURL = profile.homeURL.appendingPathComponent(".claude.json", isDirectory: false)
            guard let data = try? Data(contentsOf: identityURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any],
                  let oauthAccount = dict["oauthAccount"] as? [String: Any] else {
                return nil
            }

            var blobDict: [String: Any] = ["oauthAccount": oauthAccount]
            let suffix = CredentialMath.keychainSuffix(forHome: profile.homePath)
            if let secret = try? SystemSecurityRunner().read(
                service: "\(canonicalPaths.claudeKeychainService)-\(suffix)", account: NSUserName()
            ),
               let credObject = try? JSONSerialization.jsonObject(with: Data(secret.utf8)),
               let credDict = credObject as? [String: Any] {
                if let oauth = credDict["claudeAiOauth"] { blobDict["claudeAiOauth"] = oauth }
                if let mcp = credDict["mcpOAuth"] { blobDict["mcpOAuth"] = mcp }
            }
            guard let blob = try? JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys]) else {
                return nil
            }
            let identity = CredentialBlob.claudeIdentity(fromBlob: blob)
            return Capture(
                blob: blob,
                email: identity?.email,
                identityFingerprint: identity?.accountUuid,
                organizationUuid: identity?.orgUuid,
                organizationName: identity?.orgName,
                accountId: identity?.accountUuid,
                workspaceAccountId: nil,
                backend: ClaudeBackend.keychain.rawValue
            )
        case .codex:
            let authURL = profile.homeURL.appendingPathComponent("auth.json", isDirectory: false)
            guard let data = try? Data(contentsOf: authURL),
                  let identity = CredentialBlob.codexIdentity(fromAuthJSON: data) else {
                return nil
            }
            return Capture(
                blob: data,
                email: identity.email,
                identityFingerprint: identity.accountId,
                organizationUuid: nil,
                organizationName: nil,
                accountId: identity.accountId,
                workspaceAccountId: identity.workspaceAccountId,
                backend: "codex"
            )
        }
    }

    // MARK: - Restore

    /// Restore the user's original (system-default) identity through the swap path.
    @discardableResult
    func restoreOriginal() async -> String {
        do {
            try swapManager.restoreSystemDefault()
            return "Restored your original account. Applies to new sessions."
        } catch {
            return error.localizedDescription
        }
    }

    /// True if a system-default snapshot has been captured (Restore is available).
    func canRestoreOriginal() -> Bool {
        (try? vault.get(accountId: CredentialVault.systemDefaultAccountID)) != nil
    }

    // MARK: - Env override warning

    /// If a shell env var overrides the canonical swap, return a warning; else nil.
    /// The swap can't strip a user's shell, so these env vars win at runtime.
    func envOverrideWarning(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let overriders = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]
        let present = overriders.filter { (environment[$0]?.isEmpty == false) }
        guard !present.isEmpty else { return nil }
        let names = present.joined(separator: ", ")
        return "\(names) is set in your environment — it overrides account switching for Claude."
    }

    // MARK: - Capture plumbing

    private struct Capture: Sendable {
        var blob: Data
        var email: String?
        var identityFingerprint: String?
        var organizationUuid: String?
        var organizationName: String?
        var accountId: String?
        var workspaceAccountId: String?
        var backend: String
    }

    /// Codex poll stability state, passed BY VALUE through the off-actor capture
    /// checks (`inout` cannot cross an await) and threaded back by the caller.
    private struct CodexPollState: Sendable {
        var lastSize: Int = -1
        var stablePolls: Int = 0
    }

    /// Inspect both sinks in a staging home; return a `Capture` only when the
    /// login is provably complete, else nil (keep polling).
    ///
    /// `nonisolated static` on purpose: this can spawn `security` and block up to
    /// 3s, so callers run it via `Task.detached` — it must never touch main-actor
    /// state. Everything it needs is passed in (Sendable values only).
    ///
    /// `notBefore`: when set, only credentials/identity written at or after this
    /// instant (minus clock-skew tolerance) count — anything older is a leftover
    /// from a previous attempt, not this login.
    private nonisolated static func captureIfReady(
        tool: AccountTool,
        stagingHome: URL,
        canonicalPaths: CanonicalCredentialPaths,
        state: CodexPollState,
        notBefore: Date?
    ) throws -> (capture: Capture?, state: CodexPollState) {
        switch tool {
        case .claude:
            return (try captureClaudeIfReady(stagingHome: stagingHome, canonicalPaths: canonicalPaths, notBefore: notBefore), state)
        case .codex:
            return captureCodexIfReady(stagingHome: stagingHome, state: state, notBefore: notBefore)
        }
    }

    /// Whether a sink written at `written` may belong to a login that started at
    /// `notBefore` (nil ⇒ no constraint). Tolerates clock skew / second-resolution
    /// Keychain timestamps.
    private nonisolated static func isFresh(_ written: Date?, notBefore: Date?) -> Bool {
        guard let notBefore, let written else { return true }
        return written >= notBefore.addingTimeInterval(-clockSkewToleranceMs / 1000)
    }

    /// Claude completion requires BOTH: a suffixed Keychain blob with a parseable
    /// `claudeAiOauth` (refreshToken + expiresAt > now) AND a `<home>/.claude.json`
    /// `oauthAccount` whose `accountUuid` matches.
    private nonisolated static func captureClaudeIfReady(
        stagingHome: URL,
        canonicalPaths: CanonicalCredentialPaths,
        notBefore: Date?
    ) throws -> Capture? {
        // The staging login ran with CLAUDE_CONFIG_DIR=<stagingHome>, so the
        // suffixed Keychain item is keyed off that path.
        let suffix = CredentialMath.keychainSuffix(forHome: stagingHome.path)
        let service = "\(canonicalPaths.claudeKeychainService)-\(suffix)"
        let runner = SystemSecurityRunner()
        guard let secret = try? runner.read(service: service, account: NSUserName()),
              !secret.isEmpty
        else {
            return nil
        }
        // Freshness: the Keychain item must have been (re)written by THIS login.
        if notBefore != nil,
           let attributes = try? runner.attributes(service: service, account: NSUserName()),
           let modified = attributes["mdat"].flatMap(SystemSecurityRunner.keychainDate(from:)),
           !isFresh(modified, notBefore: notBefore) {
            return nil
        }
        guard let credObject = try? JSONSerialization.jsonObject(with: Data(secret.utf8)),
              let credDict = credObject as? [String: Any],
              let claudeAiOauth = credDict["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        guard let refreshToken = claudeAiOauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return nil
        }
        // expiresAt may be ms-since-epoch (number) — require it in the future with
        // a 60s clock-skew tolerance (`> now - skew`).
        if let expiresAt = claudeAiOauth["expiresAt"] as? Double {
            let nowMs = Date().timeIntervalSince1970 * 1000
            guard expiresAt > nowMs - Self.clockSkewToleranceMs else { return nil }
        }

        // Second sink: <home>/.claude.json oauthAccount — also written by THIS login.
        let identityURL = stagingHome.appendingPathComponent(".claude.json", isDirectory: false)
        let identityModified = (try? FileManager.default.attributesOfItem(atPath: identityURL.path))?[.modificationDate] as? Date
        guard isFresh(identityModified, notBefore: notBefore) else { return nil }
        guard let identityData = try? Data(contentsOf: identityURL),
              let identityObject = try? JSONSerialization.jsonObject(with: identityData),
              let identityDict = identityObject as? [String: Any],
              let oauthAccount = identityDict["oauthAccount"] as? [String: Any],
              let accountUuid = oauthAccount["accountUuid"] as? String else {
            return nil
        }
        // accountUuid must match between the two sinks when both carry it.
        if let credUuid = claudeAiOauth["accountUuid"] as? String, credUuid != accountUuid {
            return nil
        }

        // Build the vault blob: {claudeAiOauth, oauthAccount}.
        var blobDict: [String: Any] = ["claudeAiOauth": claudeAiOauth, "oauthAccount": oauthAccount]
        if let mcp = credDict["mcpOAuth"] { blobDict["mcpOAuth"] = mcp }
        let blob = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])

        // Derive identity through the single canonical parser so capture, migration,
        // and the swap manager all key the vault the SAME way.
        let identity = CredentialBlob.claudeIdentity(fromBlob: blob)

        return Capture(
            blob: blob,
            email: identity?.email,
            identityFingerprint: accountUuid,
            organizationUuid: identity?.orgUuid,
            organizationName: identity?.orgName,
            // Canonical vault key: the Claude accountUuid.
            accountId: accountUuid,
            workspaceAccountId: nil,
            backend: ClaudeBackend.keychain.rawValue
        )
    }

    /// Codex completion requires an `auth.json` with a decodable `tokens.id_token`,
    /// stable size across two consecutive polls. Runs off-actor (see captureIfReady);
    /// uses `FileManager.default`, which is thread-safe for these path/read checks.
    private nonisolated static func captureCodexIfReady(
        stagingHome: URL,
        state: CodexPollState,
        notBefore: Date?
    ) -> (capture: Capture?, state: CodexPollState) {
        var state = state
        let authURL = stagingHome.appendingPathComponent("auth.json", isDirectory: false)
        let authModified = (try? FileManager.default.attributesOfItem(atPath: authURL.path))?[.modificationDate] as? Date
        guard FileManager.default.fileExists(atPath: authURL.path),
              isFresh(authModified, notBefore: notBefore),
              let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              JWTPayload.decode(idToken) != nil else {
            state.lastSize = -1
            state.stablePolls = 0
            return (nil, state)
        }

        // Stable size across two polls. Only reset stability on a real change to a
        // previously-observed size: when lastSize is the manual-finish sentinel
        // (< 0), seed it instead of resetting — otherwise the manual "I've finished
        // signing in" fallback (which seeds stablePolls to bypass stability)
        // would be reset to 0 and never capture.
        let size = data.count
        if state.lastSize < 0 {
            state.lastSize = size
        } else if size != state.lastSize {
            state.stablePolls = 0
            state.lastSize = size
        } else {
            state.stablePolls += 1
        }
        guard state.stablePolls >= 1 else { return (nil, state) }

        // Derive identity through the single canonical parser (same key everywhere).
        let identity = CredentialBlob.codexIdentity(fromAuthJSON: data)

        let capture = Capture(
            blob: data,
            email: identity?.email,
            identityFingerprint: identity?.accountId,
            organizationUuid: nil,
            organizationName: nil,
            accountId: identity?.accountId,
            workspaceAccountId: identity?.workspaceAccountId,
            backend: "codex"
        )
        return (capture, state)
    }

    /// Persist a capture: write to the vault keyed by the stable identity, then
    /// upsert (dedupe) into the profile store. `isNew` is false when the capture
    /// matched an account that was already in the list (updated in place).
    private func persistCapture(
        tool: AccountTool,
        name: String,
        slug: String,
        stagingHome: URL,
        capture: Capture
    ) throws -> (profile: AccountProfile, isNew: Bool) {
        let countBefore = (try? store.loadProfiles().count) ?? 0
        let envelope = VaultEnvelope(
            tool: tool,
            backend: capture.backend,
            identityFingerprint: capture.identityFingerprint,
            email: capture.email,
            lastCanonicalHash: nil,
            blob: capture.blob
        )

        let profile = try store.upsert(
            tool: tool,
            name: name,
            slug: slug,
            homeURL: stagingHome,
            isImported: false,
            emailAddress: capture.email,
            organizationUuid: capture.organizationUuid,
            organizationName: capture.organizationName,
            accountId: capture.accountId,
            workspaceAccountId: capture.workspaceAccountId
        )

        // Key the vault by the same id the swap manager will look up.
        let accountId = CredentialSwapManager.accountId(for: profile)
        try vault.put(accountId: accountId, envelope)
        let countAfter = (try? store.loadProfiles().count) ?? countBefore
        return (profile, countAfter > countBefore)
    }

    /// Remove anything a PREVIOUS attempt left in a staging home so the capture
    /// poll can only see this login's output: the identity file (Claude) or
    /// `auth.json` (Codex), and the suffixed Keychain item. Best-effort.
    private func clearStaleStaging(tool: AccountTool, stagingHome: URL) {
        switch tool {
        case .codex:
            try? fileManager.removeItem(at: stagingHome.appendingPathComponent("auth.json", isDirectory: false))
        case .claude:
            let identity = stagingHome.appendingPathComponent(".claude.json", isDirectory: false)
            if fileManager.fileExists(atPath: identity.path) {
                try? fileManager.removeItem(at: identity)
                ChewyLog.info("login: cleared stale identity file in staging home '\(stagingHome.lastPathComponent)'")
            }
            try? fileManager.removeItem(at: stagingHome.appendingPathComponent("backups", isDirectory: true))
            deleteStagingKeychainItem(stagingHome: stagingHome)
        }
    }

    /// Delete the suffixed Claude staging Keychain item. The CLI creates it via
    /// `/usr/bin/security`, so deleting through `security` is what actually works;
    /// `SecItemDelete` from the app is kept as a fallback.
    private func deleteStagingKeychainItem(stagingHome: URL) {
        let suffix = CredentialMath.keychainSuffix(forHome: stagingHome.path)
        let service = "\(canonicalPaths.claudeKeychainService)-\(suffix)"
        let account = NSUserName()
        do {
            try SystemSecurityRunner().delete(service: service, account: account)
        } catch {
            ChewyLog.warn("login: `security delete` of the staging Keychain item for '\(stagingHome.lastPathComponent)' failed (\(error.localizedDescription)); trying SecItemDelete")
            try? KeychainCredentialStore.deleteGenericPassword(service: service, account: account)
        }
    }

    /// Remove plaintext tokens left in the staging home after a login attempt.
    ///
    /// Run in a `defer` so it fires on success, timeout, AND throw — we never want
    /// live tokens lingering on disk / in a transient Keychain item once the durable
    /// vault copy exists (or once the attempt has ended). Never logs token values.
    private func cleanupStaging(tool: AccountTool, stagingHome: URL) {
        switch tool {
        case .codex:
            // The Codex staging home holds `auth.json` with live tokens.
            try? fileManager.removeItem(at: stagingHome)
        case .claude:
            // The Claude staging login wrote a suffixed Keychain item keyed off the
            // staging path. Delete it; the credentials now live only in the vault.
            deleteStagingKeychainItem(stagingHome: stagingHome)
        }
    }

    // MARK: - Login launch

    private func launchLogin(tool: AccountTool, slug: String, stagingHome: URL) throws {
        let profile = AccountProfile(
            tool: tool,
            name: slug,
            slug: slug,
            homePath: stagingHome.path,
            isImported: false
        )
        let script: URL
        switch tool {
        case .codex:
            script = try launcher.makeCodexLoginScript(profile: profile)
        case .claude:
            script = try launcher.makeClaudeLoginScript(profile: profile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        try process.run()
    }

    // MARK: - Active id persistence

    private static let activeIDsDefaultsKey = "chewy.activeAccountIDs"

    private func loadActiveAccountIDs() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.activeIDsDefaultsKey) as? [String: String] else {
            return
        }
        var result: [AccountTool: String] = [:]
        for (key, value) in raw {
            if let tool = AccountTool(rawValue: key) {
                result[tool] = value
            }
        }
        activeAccountIDs = result
    }

    private func persistActiveAccountIDs() {
        var raw: [String: String] = [:]
        for (tool, id) in activeAccountIDs {
            raw[tool.rawValue] = id
        }
        UserDefaults.standard.set(raw, forKey: Self.activeIDsDefaultsKey)
    }

    // MARK: - Identity helpers

    /// Pull an email from a vaulted blob (Claude oauthAccount / Codex JWT).
    static func email(fromBlob blob: Data, tool: AccountTool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: blob),
              let dict = object as? [String: Any] else {
            return nil
        }
        switch tool {
        case .claude:
            if let oauth = dict["oauthAccount"] as? [String: Any],
               let email = oauth["emailAddress"] as? String, !email.isEmpty {
                return email
            }
            return nil
        case .codex:
            if let tokens = dict["tokens"] as? [String: Any],
               let idToken = tokens["id_token"] as? String {
                return JWTPayload.email(from: idToken)
            }
            return nil
        }
    }
}
