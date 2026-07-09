import ChewyCore
import Foundation

/// Regression guard for BLOCKER 1: capture, migration, and the swap manager must
/// derive an account's vault key the SAME way, so the same credential blob always
/// resolves to ONE vault id (the canonical accountUuid / ChatGPT account id).
///
/// Capture and migration both now: parse identity with `CredentialBlob`, set the
/// profile `accountId` to that canonical id, and key the vault via
/// `CredentialSwapManager.accountId(for:)`. This check reproduces each path's key
/// derivation from one blob and proves they all agree.
func checkVaultKeyConsistency() throws {
    // ---- Claude ----
    let claudeBlob = Data(
        #"{"claudeAiOauth":{"accessToken":"x","accountUuid":"acct-uuid-CLAUDE"},"oauthAccount":{"accountUuid":"acct-uuid-CLAUDE","emailAddress":"u@x.com","organizationUuid":"org-CLAUDE","organizationName":"Org"}}"#.utf8
    )

    // The single canonical parser every path now uses.
    guard let claudeIdentity = CredentialBlob.claudeIdentity(fromBlob: claudeBlob) else {
        throw CheckFailure(description: "claudeIdentity should parse the blob")
    }
    let claudeAccountUuid = claudeIdentity.accountUuid
    try check(claudeAccountUuid == "acct-uuid-CLAUDE", "Claude identity should extract accountUuid")

    // Capture path: sets profile.accountId = accountUuid (canonical key).
    let capturedProfile = AccountProfile(
        tool: .claude,
        name: "Captured",
        slug: "captured",
        homePath: "",
        isImported: false,
        emailAddress: claudeIdentity.email,
        organizationUuid: claudeIdentity.orgUuid,
        organizationName: claudeIdentity.orgName,
        accountId: claudeAccountUuid
    )
    // Migration path: same canonical parser, same accountId assignment.
    let migratedProfile = AccountProfile(
        tool: .claude,
        name: "Migrated",
        slug: "migrated",
        homePath: "/legacy/home",
        isImported: true,
        emailAddress: claudeIdentity.email,
        organizationUuid: claudeIdentity.orgUuid,
        organizationName: claudeIdentity.orgName,
        accountId: claudeAccountUuid
    )

    let captureKey = CredentialSwapManager.accountId(for: capturedProfile)
    let migrationKey = CredentialSwapManager.accountId(for: migratedProfile)

    try check(captureKey == migrationKey, "Claude capture and migration vault keys must agree")
    try check(captureKey == claudeAccountUuid, "Claude vault key must equal the accountUuid")

    // ---- Codex ----
    // tokens.account_id is the canonical ChatGPT account id used as the key.
    let codexBlob = Data(
        #"{"auth_mode":"chatgpt","tokens":{"account_id":"chatgpt-acct-CODEX","id_token":"redacted"}}"#.utf8
    )
    guard let codexIdentity = CredentialBlob.codexIdentity(fromAuthJSON: codexBlob) else {
        throw CheckFailure(description: "codexIdentity should parse the auth.json blob")
    }
    let codexAccountId = codexIdentity.accountId
    try check(codexAccountId == "chatgpt-acct-CODEX", "Codex identity should extract account_id")

    let codexCaptured = AccountProfile(
        tool: .codex, name: "Captured", slug: "codex-captured", homePath: "", isImported: false,
        emailAddress: codexIdentity.email, accountId: codexAccountId,
        workspaceAccountId: codexIdentity.workspaceAccountId
    )
    let codexMigrated = AccountProfile(
        tool: .codex, name: "Migrated", slug: "codex-migrated", homePath: "/legacy/codex", isImported: true,
        emailAddress: codexIdentity.email, accountId: codexAccountId,
        workspaceAccountId: codexIdentity.workspaceAccountId
    )

    let codexCaptureKey = CredentialSwapManager.accountId(for: codexCaptured)
    let codexMigrationKey = CredentialSwapManager.accountId(for: codexMigrated)

    try check(codexCaptureKey == codexMigrationKey, "Codex capture and migration vault keys must agree")
    try check(codexCaptureKey == codexAccountId, "Codex vault key must equal the account_id")
}
