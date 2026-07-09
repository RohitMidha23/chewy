import ChewyCore
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(description: message)
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChewyChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func checkSlugify() throws {
    try check(AccountProfileStore.slugify(" Work Codex ") == "work-codex", "slugify should trim and lowercase")
    try check(AccountProfileStore.slugify("Dev+OpenAI/Profile") == "dev-openai-profile", "slugify should normalize separators")
}

func checkProfileStore() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let paths = ChewyPaths(appSupportDirectory: temporaryDirectory)
    let store = AccountProfileStore(paths: paths)

    let first = try store.uniqueSlug(for: "Work Codex", tool: .codex)
    try check(first == "work-codex", "first slug should be base slug")

    _ = try store.addProfile(
        tool: .codex,
        name: "Work Codex",
        slug: first,
        homeURL: temporaryDirectory.appendingPathComponent("home", isDirectory: true),
        isImported: false
    )

    let second = try store.uniqueSlug(for: "Work Codex", tool: .codex)
    try check(second == "work-codex-2", "second slug should have numeric suffix")

    let profiles = try store.loadProfiles()
    try check(profiles.count == 1, "profile should round-trip")
    try check(profiles[0].name == "Work Codex", "profile name should round-trip")

    let permissions = try FileManager.default.attributesOfItem(atPath: paths.metadataURL.path)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue == 0o600, "metadata should be private")
}

func checkCodexHomeManager() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let paths = ChewyPaths(appSupportDirectory: temporaryDirectory.appendingPathComponent("app", isDirectory: true))
    let manager = CodexHomeManager(paths: paths)

    let overridden = manager.defaultCodexHome(environment: ["CODEX_HOME": "/tmp/custom-codex", "HOME": "/Users/test"])
    try check(overridden.path == "/tmp/custom-codex", "CODEX_HOME should override default")

    let fallback = manager.defaultCodexHome(environment: ["HOME": "/Users/test"])
    try check(fallback.path == "/Users/test/.codex", "default should use ~/.codex")

    let disposable = try manager.createDisposableHome(slug: "scratch")
    try check(FileManager.default.fileExists(atPath: disposable.path), "disposable home should exist")
    let disposablePermissions = try FileManager.default.attributesOfItem(atPath: disposable.path)[.posixPermissions] as? NSNumber
    try check(disposablePermissions?.intValue == 0o700, "disposable home should be private")

    let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try #"{"tokens":{"access_token":"fake"}}"#.write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    try "model = \"gpt-5.5\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    try "do not copy sessions".write(to: source.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

    let imported = try manager.importCurrentHome(slug: "imported", sourceHome: source)
    try check(FileManager.default.fileExists(atPath: imported.appendingPathComponent("auth.json").path), "auth.json should be copied")
    try check(FileManager.default.fileExists(atPath: imported.appendingPathComponent("config.toml").path), "config.toml should be copied")
    try check(!FileManager.default.fileExists(atPath: imported.appendingPathComponent("history.jsonl").path), "history should not be copied")

    let authPermissions = try FileManager.default.attributesOfItem(atPath: imported.appendingPathComponent("auth.json").path)[.posixPermissions] as? NSNumber
    try check(authPermissions?.intValue == 0o600, "imported auth should be private")
}

func checkTerminalLauncher() throws {
    try check(
        TerminalLauncher.shellQuote("/tmp/dev's codex") == #"'/tmp/dev'\''s codex'"#,
        "shell quote should handle embedded single quotes"
    )

    let profile = AccountProfile(
        tool: .codex,
        name: "Work",
        slug: "work",
        homePath: "/Users/dev/Library/Application Support/Chewy/Profiles/codex/work/home",
        isImported: true
    )
    let launcher = TerminalLauncher(paths: ChewyPaths(appSupportDirectory: URL(fileURLWithPath: "/tmp/Chewy")))
    let script = launcher.renderCodexLaunchScript(
        profile: profile,
        workingDirectory: URL(fileURLWithPath: "/tmp/project with spaces")
    )

    try check(script.contains("export CODEX_HOME='/Users/dev/Library/Application Support/Chewy/Profiles/codex/work/home'"), "script should export CODEX_HOME")
    try check(script.contains("cd '/tmp/project with spaces'"), "script should quote working directory")
    try check(script.contains("exec /usr/bin/env codex"), "script should exec codex through env")
    try check(!script.contains("access_token"), "script must not contain access tokens")
    try check(!script.contains("refresh_token"), "script must not contain refresh tokens")

    let codexLoginScript = launcher.renderCodexCommandScript(profile: profile, arguments: ["login"])
    try check(codexLoginScript.contains("export CODEX_HOME='/Users/dev/Library/Application Support/Chewy/Profiles/codex/work/home'"), "Codex login script should export CODEX_HOME")
    try check(codexLoginScript.contains("exec /usr/bin/env codex 'login'"), "Codex login script should run codex login")

    let claudeProfile = AccountProfile(
        tool: .claude,
        name: "Claude",
        slug: "claude-work",
        homePath: "/tmp/Chewy/Profiles/claude/claude-work",
        isImported: false,
        credentialReference: "claude.claude-work.fake-reference",
        authEnvironmentVariable: ClaudeAuthEnvironment.anthropicAPIKey.rawValue
    )
    let claudeScript = try launcher.renderClaudeLaunchScript(
        profile: claudeProfile,
        workingDirectory: URL(fileURLWithPath: "/tmp/claude project")
    )

    try check(claudeScript.contains("/usr/bin/security find-generic-password"), "Claude script should read from Keychain")
    try check(claudeScript.contains("-a 'claude.claude-work.fake-reference'"), "Claude script should use opaque credential reference")
    try check(claudeScript.contains("export ANTHROPIC_API_KEY=\"$SECRET\""), "Claude script should export selected auth env var")
    try check(claudeScript.contains("cd '/tmp/claude project'"), "Claude script should quote Claude working directory")
    try check(claudeScript.contains("exec /usr/bin/env claude"), "Claude script should exec claude")
    try check(!claudeScript.contains("sk-ant"), "Claude script must not contain literal Claude tokens")

    let claudeOAuthProfile = AccountProfile(
        tool: .claude,
        name: "Claude OAuth",
        slug: "claude-oauth",
        homePath: "/tmp/Chewy/Profiles/claude/claude-oauth",
        isImported: false
    )
    let claudeOAuthScript = try launcher.renderClaudeLaunchScript(
        profile: claudeOAuthProfile,
        workingDirectory: URL(fileURLWithPath: "/tmp/oauth project")
    )

    try check(claudeOAuthScript.contains("export CLAUDE_CONFIG_DIR='/tmp/Chewy/Profiles/claude/claude-oauth'"), "Claude OAuth script should export isolated config dir")
    try check(claudeOAuthScript.contains("cd '/tmp/oauth project'"), "Claude OAuth script should quote working directory")
    try check(claudeOAuthScript.contains("exec /usr/bin/env claude \"$@\""), "Claude OAuth script should exec claude")
    try check(!claudeOAuthScript.contains("/usr/bin/security find-generic-password"), "Claude OAuth script should not read Chewy token keychain entries")
    try check(!claudeOAuthScript.contains("CLAUDE_CODE_OAUTH_TOKEN="), "Claude OAuth script must not embed OAuth tokens")

    let claudeLoginScript = launcher.renderClaudeOAuthCommandScript(profile: claudeOAuthProfile, arguments: ["auth", "login"])
    try check(claudeLoginScript.contains("export CLAUDE_CONFIG_DIR='/tmp/Chewy/Profiles/claude/claude-oauth'"), "Claude login script should export isolated config dir")
    try check(claudeLoginScript.contains("exec /usr/bin/env claude 'auth' 'login'"), "Claude login script should run auth login")
}

func checkClaudeProfileManager() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let paths = ChewyPaths(appSupportDirectory: temporaryDirectory)
    let manager = ClaudeProfileManager(paths: paths)
    let home = try manager.createOAuthConfigHome(slug: "oauth")

    try check(FileManager.default.fileExists(atPath: home.path), "Claude OAuth config home should exist")
    let permissions = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue == 0o700, "Claude OAuth config home should be private")
}

do {
    try checkSlugify()
    try checkProfileStore()
    try checkCodexHomeManager()
    try checkTerminalLauncher()
    try checkClaudeProfileManager()
    try checkJWTPayload()
    try checkCredentialMath()
    try checkCredentialVault()
    try checkEmailDedupe()
    try checkSwapManager()
    try checkVaultKeyConsistency()
    try checkUsageParsing()
    try checkAccountAdvisor()
    try checkActiveAccountResolver()
    try checkUsageMeter()
    try checkAutoSwitchPlanner()
    try checkAutoSwitchInputsBuild()
    try checkSwapRecapturesOutgoing()
    try checkReconnectDedupe()
    try checkNewFormatCanonicalCapture()
    try checkVaultFailSafeOnUndecodable()
    try checkRemoveAccountStoreSemantics()
    try checkSecurityInteractiveEscaping()
    try checkCanonicalWriteSafety()
    try checkUsageCache()
    try checkHealGate()
    try checkPolicySimulation()
    try checkNoDeletedSymbols()
    print("ChewyCoreChecks passed")
} catch {
    fputs("ChewyCoreChecks failed: \(error)\n", stderr)
    exit(1)
}
