import CryptoKit
import Foundation

// MARK: - SecurityRunner

/// Abstraction over the canonical macOS Keychain so the swap manager is testable
/// without ever touching the real login Keychain.
///
/// Implementations MUST NOT print or log secret values.
public protocol SecurityRunner {
    /// Read the generic-password secret for (service, account). Returns nil if absent.
    func read(service: String, account: String) throws -> String?
    /// Upsert the generic-password secret for (service, account).
    func write(service: String, account: String, secret: String) throws
    /// Best-effort non-secret attributes for (service, account) (e.g. svce/acct/class).
    func attributes(service: String, account: String) throws -> [String: String]
}

/// Real `SecurityRunner` that shells to `/usr/bin/security`.
///
/// Reads via `find-generic-password -w`; writes via `security -i` with the full
/// `add-generic-password -U` command supplied on STDIN, so the secret never
/// appears in argv (argv is visible to every same-UID process via `ps`).
/// Every invocation is bounded by a hard 3s watchdog that terminates the process,
/// because the Keychain ACL prompt can hang indefinitely. Secret values are never
/// echoed and never logged.
public struct SystemSecurityRunner: SecurityRunner {
    /// Hard wall-clock timeout for any `security` invocation.
    public static let timeout: TimeInterval = 3.0

    private let executable: String

    public init(executable: String = "/usr/bin/security") {
        self.executable = executable
    }

    public func read(service: String, account: String) throws -> String? {
        let result = try runSecurity([
            "find-generic-password", "-s", service, "-a", account, "-w"
        ])
        // security exits 44 (errSecItemNotFound) when the item is absent.
        if result.exitCode == 44 {
            return nil
        }
        guard result.exitCode == 0 else {
            throw ChewyError.keychainFailure(OSStatus(result.exitCode))
        }
        let trimmed = result.standardOutput.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func write(service: String, account: String, secret: String) throws {
        // The secret must never be an argv element: `ps` exposes argv to every
        // same-UID process. Direct SecItemAdd/SecItemUpdate is not an option
        // either — the canonical "Claude Code-credentials" item is created and
        // ACL-owned by the claude CLI, so SecItem writes from this process hit
        // ACL denials/prompts; the `security` CLI write is the proven path.
        // Instead, drive `security -i` (interactive mode) and pass the whole
        // add-generic-password command on STDIN.
        //
        // The `-i` tokenizer honors `\` and `"` escapes inside double quotes
        // (verified empirically: JSON secrets round-trip byte-exact, including
        // unicode, `$`, and backticks), but its protocol is line-based with TWO
        // hard limits, both measured on this machine:
        //   1. raw newlines are unrepresentable, and
        //   2. the whole command line is SILENTLY TRUNCATED at 4096 bytes
        //      (exit 0, corrupted payload — it once truncated a real canonical
        //      credential blob mid-string).
        // Oversized or control-character secrets therefore use the argv path
        // (brief same-UID `ps` exposure) — a corrupting write is never OK.
        let result: SecurityResult
        if let command = Self.interactiveWriteCommand(service: service, account: account, secret: secret) {
            result = try runSecurity(["-i"], stdin: Data(command.utf8))
        } else {
            result = try runSecurity([
                "add-generic-password", "-U", "-s", service, "-a", account, "-w", secret
            ])
        }
        guard result.exitCode == 0 else {
            throw ChewyError.keychainFailure(OSStatus(result.exitCode))
        }
    }

    /// The `security -i` line buffer is 4096 bytes and truncates SILENTLY; stay
    /// comfortably below it. (Measured: payloads survive to ~4033 bytes with our
    /// command prefix; beyond that the line is cut with exit code 0.)
    public static let interactiveCommandByteLimit = 3800

    /// Compose the `security -i` command for an upsert, or nil when the secret
    /// cannot travel safely over the line-based `-i` protocol (contains raw
    /// control characters, or the composed command would approach the 4096-byte
    /// line buffer). Nil means: use the argv path. Pure — unit-tested.
    public static func interactiveWriteCommand(service: String, account: String, secret: String) -> String? {
        guard !secret.contains("\n"), !secret.contains("\r"), !secret.contains("\0") else { return nil }
        let command = "add-generic-password -U"
            + " -s \(escapeSecurityInteractiveToken(service))"
            + " -a \(escapeSecurityInteractiveToken(account))"
            + " -w \(escapeSecurityInteractiveToken(secret))\n"
        guard command.utf8.count <= interactiveCommandByteLimit else { return nil }
        return command
    }

    /// Escape one token for the `security -i` line tokenizer: escape backslashes
    /// and double quotes, then wrap the token in double quotes. Inside quotes the
    /// tokenizer maps `\\` → `\` and `\"` → `"` (and drops a backslash before any
    /// other character — which this escaper never emits), so the round-trip is
    /// exact for any single-line string. Raw newlines are NOT representable on
    /// the line-based protocol; callers must handle them separately.
    public static func escapeSecurityInteractiveToken(_ token: String) -> String {
        "\"" + token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func attributes(service: String, account: String) throws -> [String: String] {
        // `-g` prints attributes to stderr without the password value.
        let result = try runSecurity([
            "find-generic-password", "-s", service, "-a", account, "-g"
        ])
        if result.exitCode == 44 {
            return [:]
        }
        guard result.exitCode == 0 else {
            throw ChewyError.keychainFailure(OSStatus(result.exitCode))
        }
        return Self.parseAttributes(result.standardError)
    }

    /// Delete the generic-password item for (service, account). Items the Claude
    /// CLI creates through `/usr/bin/security` are reliably deletable this way,
    /// whereas `SecItemDelete` from the app silently leaves them behind — and a
    /// stale staging item is exactly what let a re-login capture the PREVIOUS
    /// account's token. A missing item is not an error.
    public func delete(service: String, account: String) throws {
        let result = try runSecurity([
            "delete-generic-password", "-s", service, "-a", account
        ])
        if result.exitCode == 44 { return }
        guard result.exitCode == 0 else {
            throw ChewyError.keychainFailure(OSStatus(result.exitCode))
        }
    }

    /// Parse the `"20260921083026Z"` form `security -g` prints for `cdat`/`mdat`.
    public static func keychainDate(from raw: String) -> Date? {
        // `security` renders the trailing NUL as a literal `\000`; take the leading
        // 14-digit run and ignore whatever follows the `Z`.
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let digits = String(trimmed.prefix { $0.isNumber })
        guard digits.count == 14, trimmed.dropFirst(14).first == "Z" else { return nil }
        var components = DateComponents()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(digits.prefix(4))
        components.month = Int(digits.dropFirst(4).prefix(2))
        components.day = Int(digits.dropFirst(6).prefix(2))
        components.hour = Int(digits.dropFirst(8).prefix(2))
        components.minute = Int(digits.dropFirst(10).prefix(2))
        components.second = Int(digits.dropFirst(12).prefix(2))
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: Process plumbing

    private struct SecurityResult {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Thread-safe byte buffer for draining a pipe off the calling thread.
    private final class DrainBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private func runSecurity(_ arguments: [String], stdin stdinData: Data? = nil) throws -> SecurityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var stdinHandle: FileHandle?
        if stdinData != nil {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinHandle = stdinPipe.fileHandleForWriting
        }

        do {
            try process.run()
        } catch {
            throw ChewyError.missingExecutable(executable)
        }

        // Hard 3s watchdog: macOS has no GNU `timeout`, and the Keychain ACL prompt
        // can hang. Terminate (then kill) if the process overruns.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + Self.timeout)
        watchdog.setEventHandler {
            if process.isRunning {
                process.terminate()
                // Escalate to SIGKILL shortly after, in case terminate is ignored.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        // Drain stdout/stderr CONCURRENTLY on background queues, then wait for
        // exit. A blocking read on the calling thread before waitUntilExit can
        // deadlock: if the child fills a pipe buffer, or the watchdog kills it
        // mid-write, the read may never return. Background reads always unblock
        // at EOF when the child exits (including via SIGKILL).
        let outBuffer = DrainBuffer()
        let errBuffer = DrainBuffer()
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async {
            outBuffer.append(outHandle.readDataToEndOfFile())
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            errBuffer.append(errHandle.readDataToEndOfFile())
            drainGroup.leave()
        }

        // Feed stdin off-thread too (a full stdin pipe must never wedge us),
        // then close it so line-based readers (`security -i`) see EOF.
        if let stdinData, let stdinHandle {
            DispatchQueue.global().async {
                // write(contentsOf:) throws on EPIPE instead of raising an ObjC
                // exception; ignore — the exit-code check reports the failure.
                try? stdinHandle.write(contentsOf: stdinData)
                try? stdinHandle.close()
            }
        }

        process.waitUntilExit()
        // EOF arrives when the child exits (or is SIGKILLed), so this returns
        // promptly; the timeout is a belt-and-braces bound only.
        _ = drainGroup.wait(timeout: .now() + Self.timeout)

        return SecurityResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outBuffer.value, as: UTF8.self),
            standardError: String(decoding: errBuffer.value, as: UTF8.self)
        )
    }

    /// Parse the non-secret `key: "value"` / `key=<...>` lines `security -g` emits.
    /// `<timedate>` attributes (`cdat`, `mdat`) are exposed as their trailing
    /// `"20260921083026Z"` literal, for `keychainDate(from:)`.
    public static func parseAttributes(_ raw: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let tagRange = text.range(of: "<timedate>="),
               let lastQuote = text.lastIndex(of: "\""),
               let openQuote = text[..<lastQuote].lastIndex(of: "\"") {
                let key = String(text[..<tagRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                attributes[key] = String(text[text.index(after: openQuote)..<lastQuote])
                continue
            }
            if let range = text.range(of: "=\"") {
                // `"svce"<blob>="…"` → key `svce` (drop the `<type>` tag and quotes).
                var key = String(text[..<range.lowerBound])
                if let tag = key.range(of: "<") { key = String(key[..<tag.lowerBound]) }
                key = key.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                var value = String(text[range.upperBound...])
                if value.hasSuffix("\"") { value.removeLast() }
                attributes[key] = value
            }
        }
        return attributes
    }
}

// MARK: - Canonical paths (injectable)

/// All canonical credential-store file paths, injectable so tests use temp dirs
/// instead of the real `~/.claude` / `~/.codex`.
public struct CanonicalCredentialPaths: Sendable {
    /// `~/.claude/.credentials.json` — disk credential file (mcpOAuth, and on
    /// Keychain-less machines also claudeAiOauth).
    public let claudeCredentialsFile: URL
    /// `~/.claude.json` — displayed-identity file (oauthAccount).
    public let claudeIdentityFile: URL
    /// `~/.codex/auth.json` — Codex canonical auth.
    public let codexAuthFile: URL
    /// Keychain service for the canonical, suffixless Claude credential item.
    public let claudeKeychainService: String

    public init(
        claudeCredentialsFile: URL,
        claudeIdentityFile: URL,
        codexAuthFile: URL,
        claudeKeychainService: String = "Claude Code-credentials"
    ) {
        self.claudeCredentialsFile = claudeCredentialsFile
        self.claudeIdentityFile = claudeIdentityFile
        self.codexAuthFile = codexAuthFile
        self.claudeKeychainService = claudeKeychainService
    }

    /// Canonical paths rooted at a real home directory.
    public static func forHome(_ home: URL) -> CanonicalCredentialPaths {
        CanonicalCredentialPaths(
            claudeCredentialsFile: home.appendingPathComponent(".claude/.credentials.json"),
            claudeIdentityFile: home.appendingPathComponent(".claude.json"),
            codexAuthFile: home.appendingPathComponent(".codex/auth.json")
        )
    }
}

// MARK: - Backend detection

/// The live Claude credential backend, detected fail-closed. Ambiguous/malformed/
/// denied states are returned verbatim; the caller treats them as a hard error and
/// never guesses.
public enum ClaudeBackend: String, Equatable, Sendable {
    case keychain
    case file
    case ambiguousBothPresent
    case ambiguousNeitherPresent
    case malformed
    case aclDenied
}

// MARK: - CredentialSwapManager

/// The locked, reversible projection of a vaulted account onto the canonical
/// credential stores. Never prints or logs secret values.
public final class CredentialSwapManager {
    private let securityRunner: SecurityRunner
    private let vault: CredentialVault
    private let paths: CanonicalCredentialPaths
    private let lockFileURL: URL
    private let whoami: String
    private let fileManager: FileManager

    public init(
        securityRunner: SecurityRunner = SystemSecurityRunner(),
        vault: CredentialVault,
        paths: CanonicalCredentialPaths,
        lockFileURL: URL,
        whoami: String,
        fileManager: FileManager = .default
    ) {
        self.securityRunner = securityRunner
        self.vault = vault
        self.paths = paths
        self.lockFileURL = lockFileURL
        self.whoami = whoami
        self.fileManager = fileManager
    }

    // MARK: Backend detection

    /// Detect the live Claude backend by inspecting which canonical store holds
    /// `claudeAiOauth`. Fail-closed: ambiguous/malformed/denied are returned as-is.
    public func detectClaudeBackend() -> ClaudeBackend {
        let keychainState = keychainClaudeAuthState()
        if keychainState == .aclDenied {
            return .aclDenied
        }
        if keychainState == .malformed {
            return .malformed
        }
        let keychainHasAuth = (keychainState == .present)
        let fileState = fileClaudeAuthState()
        if fileState == .malformed {
            return .malformed
        }
        let fileHasAuth = (fileState == .present)

        switch (keychainHasAuth, fileHasAuth) {
        case (true, false): return .keychain
        case (false, true): return .file
        case (true, true): return .ambiguousBothPresent
        case (false, false): return .ambiguousNeitherPresent
        }
    }

    private enum AuthPresence {
        case present
        case absent
        case malformed
        case aclDenied
    }

    private func keychainClaudeAuthState() -> AuthPresence {
        let secret: String?
        do {
            secret = try securityRunner.read(service: paths.claudeKeychainService, account: whoami)
        } catch {
            return .aclDenied
        }
        guard let secret, !secret.isEmpty else { return .absent }
        guard let object = try? JSONSerialization.jsonObject(with: Data(secret.utf8)),
              let dict = object as? [String: Any] else {
            return .malformed
        }
        return dict["claudeAiOauth"] != nil ? .present : .absent
    }

    private func fileClaudeAuthState() -> AuthPresence {
        guard fileManager.fileExists(atPath: paths.claudeCredentialsFile.path) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: paths.claudeCredentialsFile) else {
            return .absent
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return .malformed
        }
        return dict["claudeAiOauth"] != nil ? .present : .absent
    }

    // MARK: Claude swap

    /// Project a vaulted Claude account onto the live canonical stores, under lock,
    /// preserving `mcpOAuth` from the live source per the backend's MCP-source rule.
    public func swapToClaude(account: AccountProfile) throws {
        try withLock {
            try driftSyncIfNeededLocked(active: account)

            let backend = detectClaudeBackend()
            switch backend {
            case .keychain, .file:
                break
            case .ambiguousBothPresent, .ambiguousNeitherPresent, .malformed, .aclDenied:
                throw ChewyError.ambiguousClaudeBackend(backend.rawValue)
            }

            let accountId = Self.accountId(for: account)
            guard let envelope = try vault.get(accountId: accountId) else {
                throw ChewyError.missingCredentialReference(account.slug)
            }

            // PRE-VALIDATE the target BEFORE touching the canonical: a vault entry
            // without a live refresh token or without an identity block cannot
            // produce a working sign-in — writing it would half-switch (credential
            // updated, identity stale). Fail cleanly instead; the app surfaces
            // "Reconnect <email>".
            guard Self.claudeHasRefreshToken(envelope.blob),
                  Self.claudeIdentityBlock(in: envelope.blob) != nil else {
                throw ChewyError.credentialNeedsReconnect(account.slug)
            }

            // Re-capture the OUTGOING account's (possibly Claude-Code-rotated) canonical
            // into its OWN vault entry before we overwrite it with the target, so
            // switching back later never restores a dead refresh token. Best-effort: a
            // re-capture hiccup must NEVER block the actual switch.
            if let outgoing = try? readClaudeCanonicalBlobLocked(backend: backend) {
                try? attributeAndRecaptureClaude(canonical: outgoing)
            }

            try writeClaudeCanonicalLocked(blob: envelope.blob, backend: backend)
            try rewriteClaudeIdentityLocked(from: envelope.blob)

            // Record the hash of what we wrote so later drift checks are meaningful.
            let written = try readClaudeCanonicalBlobLocked(backend: backend)
            try recordCanonicalHash(Self.sha256Hex(written), for: accountId)

            // Re-read once to confirm we did not stomp a concurrent external refresh.
            let confirm = try readClaudeCanonicalBlobLocked(backend: backend)
            if Self.sha256Hex(confirm) != Self.sha256Hex(written) {
                try attributeAndRecaptureClaude(canonical: confirm)
            }
        }
    }

    /// Build the canonical Claude blob (account `claudeAiOauth` + live `mcpOAuth`)
    /// and write it to the detected backend — then VERIFY the written bytes and
    /// roll back to the previous canonical if they don't match. A silently
    /// corrupted write here (e.g. a truncating keychain tool) would otherwise
    /// break every new CLI session AND wedge all future swaps on a malformed
    /// backend, so this path is verify-or-restore, never fire-and-forget.
    private func writeClaudeCanonicalLocked(blob: Data, backend: ClaudeBackend) throws {
        let liveCanonical = try readClaudeCanonicalBlobLocked(backend: backend)
        // MCP-source rule: Claude stores mcpOAuth only in ~/.claude/.credentials.json
        // even when auth lives in the Keychain, so merge it forward from the disk
        // file when present.
        let mcpSource = try mcpSourceBlob(backend: backend, liveCanonical: liveCanonical)
        let merged = try CredentialMath.mergedCanonicalBlob(profileBlob: blob, currentCanonical: mcpSource)

        func writeCanonical(_ data: Data) throws {
            switch backend {
            case .keychain:
                try securityRunner.write(
                    service: paths.claudeKeychainService,
                    account: whoami,
                    secret: String(decoding: data, as: UTF8.self)
                )
            case .file:
                try AtomicFileWriter.write(data: data, to: paths.claudeCredentialsFile, fileManager: fileManager)
                try setPrivatePermissions(paths.claudeCredentialsFile)
            default:
                throw ChewyError.ambiguousClaudeBackend(backend.rawValue)
            }
        }

        try writeCanonical(merged)

        // Verify: the canonical must now hold exactly what we intended.
        let readBack = try readClaudeCanonicalBlobLocked(backend: backend)
        if readBack != merged {
            // Restore the previous canonical (best-effort — it was at least valid),
            // then fail loudly so the swap reports .failed instead of half-applying.
            if !liveCanonical.isEmpty, liveCanonical != Data("{}".utf8) {
                try? writeCanonical(liveCanonical)
            }
            throw ChewyError.canonicalWriteCorrupted
        }
    }

    /// Determine the canonical blob whose `mcpOAuth` should be carried forward.
    private func mcpSourceBlob(backend: ClaudeBackend, liveCanonical: Data) throws -> Data {
        // If the live canonical already carries mcpOAuth, use it as-is.
        if let object = try? JSONSerialization.jsonObject(with: liveCanonical),
           let dict = object as? [String: Any], dict["mcpOAuth"] != nil {
            return liveCanonical
        }

        // Keychain backend: mcpOAuth may live only on disk — fold it in.
        if backend == .keychain,
           fileManager.fileExists(atPath: paths.claudeCredentialsFile.path),
           let diskData = try? Data(contentsOf: paths.claudeCredentialsFile),
           let diskObject = try? JSONSerialization.jsonObject(with: diskData),
           let diskDict = diskObject as? [String: Any],
           let mcp = diskDict["mcpOAuth"] {
            var base = (try? JSONSerialization.jsonObject(with: liveCanonical)) as? [String: Any] ?? [:]
            base["mcpOAuth"] = mcp
            return try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
        }

        return liveCanonical
    }

    /// Read the current canonical Claude blob from the detected backend (empty
    /// object if absent).
    private func readClaudeCanonicalBlobLocked(backend: ClaudeBackend) throws -> Data {
        switch backend {
        case .keychain:
            let secret = try securityRunner.read(service: paths.claudeKeychainService, account: whoami)
            guard let secret, !secret.isEmpty else { return Data("{}".utf8) }
            return Data(secret.utf8)
        case .file:
            guard fileManager.fileExists(atPath: paths.claudeCredentialsFile.path),
                  let data = try? Data(contentsOf: paths.claudeCredentialsFile) else {
                return Data("{}".utf8)
            }
            return data
        default:
            return Data("{}".utf8)
        }
    }

    /// The identity (email + accountUuid) currently written to the canonical
    /// `~/.claude.json` — i.e. the account every NEW `claude` session actually uses.
    /// This is the source of truth for "which account is active", not any app state.
    public func canonicalClaudeIdentity() -> (email: String?, accountUuid: String?) {
        guard
            let data = try? Data(contentsOf: paths.claudeIdentityFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (oauth["emailAddress"] as? String, oauth["accountUuid"] as? String)
    }

    /// The identity (email + ChatGPT account id) currently in the canonical
    /// `~/.codex/auth.json` — the account every NEW `codex` session uses.
    public func canonicalCodexIdentity() -> (email: String?, accountId: String?) {
        guard let data = try? Data(contentsOf: paths.codexAuthFile),
              let identity = CredentialBlob.codexIdentity(fromAuthJSON: data) else {
            return (nil, nil)
        }
        return (identity.email, identity.accountId)
    }

    /// Rewrite ONLY the `oauthAccount` key of `~/.claude.json`, preserving every
    /// other key and the file mode. Atomic.
    private func rewriteClaudeIdentityLocked(from blob: Data) throws {
        guard let blobObject = try? JSONSerialization.jsonObject(with: blob),
              let blobDict = blobObject as? [String: Any],
              let oauthAccount = blobDict["oauthAccount"] else {
            // No identity in the vault blob — leave the identity file untouched.
            return
        }

        var existing: [String: Any] = [:]
        var existingMode: NSNumber?
        if fileManager.fileExists(atPath: paths.claudeIdentityFile.path) {
            if let data = try? Data(contentsOf: paths.claudeIdentityFile),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                existing = dict
            }
            existingMode = try? fileManager.attributesOfItem(atPath: paths.claudeIdentityFile.path)[.posixPermissions] as? NSNumber
        }

        existing["oauthAccount"] = oauthAccount
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys])
        try AtomicFileWriter.write(data: data, to: paths.claudeIdentityFile, fileManager: fileManager)
        // Preserve a pre-existing file mode; on first creation default to 0600 so a
        // freshly written identity file is never world/group readable.
        let mode = existingMode ?? NSNumber(value: 0o600)
        try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: paths.claudeIdentityFile.path)
    }

    // MARK: Codex swap

    /// Atomically copy a vaulted Codex `auth.json` blob onto the canonical path (0600).
    public func swapToCodex(account: AccountProfile) throws {
        try withLock {
            try driftSyncIfNeededLocked(active: account)

            let accountId = Self.accountId(for: account)
            guard let envelope = try vault.get(accountId: accountId) else {
                throw ChewyError.missingCredentialReference(account.slug)
            }

            try AtomicFileWriter.write(data: envelope.blob, to: paths.codexAuthFile, fileManager: fileManager)
            try setPrivatePermissions(paths.codexAuthFile)

            let written = (try? Data(contentsOf: paths.codexAuthFile)) ?? envelope.blob
            try recordCanonicalHash(Self.sha256Hex(written), for: accountId)
        }
    }

    // MARK: Drift sync

    /// Before overwriting, re-read canonical for the active account; if its hash
    /// differs from the vault's recorded hash, attribute it by identity and copy
    /// the fresher canonical back into that account's vault entry first.
    ///
    /// Public entry takes the lock; the locked variant is used internally.
    public func driftSyncIfNeeded(active: AccountProfile) throws {
        try withLock { try driftSyncIfNeededLocked(active: active) }
    }

    /// Capture the current canonical Claude credential into WHOSE-EVER vault entry
    /// it belongs to — attributed purely by the canonical's own accountUuid, with
    /// no assumption about which account the app thinks is active.
    ///
    /// This is what makes a manual `/login` inside any Claude session stick: the
    /// CLI writes fresh tokens to the canonical store, and the next poll folds
    /// them into that account's vault entry. Without it, a login as any account
    /// other than the app's notion of "active" was silently thrown away.
    /// Identity-guarded and hash-guarded like every other capture; a canonical
    /// without a valid refresh token or a matching vault entry is a no-op.
    /// Returns the sha256 of the canonical blob (nil when unreadable) so callers
    /// can track cross-poll stability — a canonical that keeps changing has a live
    /// refresher (a running session) attached to it.
    @discardableResult
    public func captureCanonicalDrift() throws -> String? {
        try withLock {
            let backend = detectClaudeBackend()
            guard backend == .keychain || backend == .file else { return nil }
            let canonical = try readClaudeCanonicalBlobLocked(backend: backend)
            try attributeAndRecaptureClaude(canonical: canonical)
            return Self.sha256Hex(canonical)
        }
    }

    private func driftSyncIfNeededLocked(active: AccountProfile) throws {
        let accountId = Self.accountId(for: active)
        guard let envelope = try vault.get(accountId: accountId) else { return }

        switch active.tool {
        case .claude:
            let backend = detectClaudeBackend()
            guard backend == .keychain || backend == .file else { return }
            let canonical = try readClaudeCanonicalBlobLocked(backend: backend)
            try reconcileClaudeDrift(canonical: canonical, envelope: envelope, accountId: accountId)
        case .codex:
            guard fileManager.fileExists(atPath: paths.codexAuthFile.path),
                  let canonical = try? Data(contentsOf: paths.codexAuthFile) else { return }
            try reconcileCodexDrift(canonical: canonical, envelope: envelope, accountId: accountId)
        }
    }

    private func reconcileClaudeDrift(canonical rawCanonical: Data, envelope: VaultEnvelope, accountId: String) throws {
        // Pair a new-format canonical (no embedded accountUuid) with the identity
        // file so the attribution guard below can actually run.
        let canonical = identityPairedCanonical(rawCanonical)
        let canonicalHash = Self.sha256Hex(canonical)
        guard canonicalHash != envelope.lastCanonicalHash else { return }
        // Attribute by identity: only copy back if the canonical belongs to the
        // active account (Claude oauthAccount.accountUuid).
        guard let canonicalUuid = Self.claudeAccountUuid(from: canonical),
              let envelopeUuid = envelope.identityFingerprint ?? Self.claudeAccountUuid(fromBlob: envelope.blob),
              canonicalUuid == envelopeUuid else {
            return
        }
        var updated = envelope
        updated.blob = mergeClaudeIdentityIntoBlob(canonical: canonical, existingBlob: envelope.blob)
        updated.lastCanonicalHash = canonicalHash
        try vault.put(accountId: accountId, updated)
    }

    private func reconcileCodexDrift(canonical: Data, envelope: VaultEnvelope, accountId: String) throws {
        let canonicalHash = Self.sha256Hex(canonical)
        guard canonicalHash != envelope.lastCanonicalHash else { return }
        guard let canonicalId = Self.codexAccountId(from: canonical),
              let envelopeId = envelope.identityFingerprint ?? Self.codexAccountId(from: envelope.blob),
              canonicalId == envelopeId else {
            return
        }
        var updated = envelope
        updated.blob = canonical
        updated.lastCanonicalHash = canonicalHash
        try vault.put(accountId: accountId, updated)
    }

    /// After a write race, re-attribute the changed canonical back to its owning
    /// vault account.
    private func attributeAndRecaptureClaude(canonical rawCanonical: Data) throws {
        // Newer Claude CLI versions write a keychain blob with NO embedded
        // accountUuid — the identity lives ONLY in ~/.claude.json (written together
        // with the credential at login/refresh). Pair them so attribution still
        // works; without this every capture path silently no-ops on new-format
        // blobs and a manual /login is thrown away.
        let canonical = identityPairedCanonical(rawCanonical)
        guard let uuid = Self.claudeAccountUuid(from: canonical) else { return }
        // Require a well-formed claudeAiOauth carrying a non-empty refreshToken, so a
        // partial/foreign/half-written canonical can never corrupt the vault entry.
        guard Self.claudeHasRefreshToken(canonical) else { return }
        // Look up the single vault entry keyed by this canonical's accountUuid and copy
        // the canonical in. (Identity-attributed: an unknown uuid silently no-ops, never
        // mis-attributes. Best-effort: never lose a rotated token silently.)
        if let env = try vault.get(accountId: uuid) {
            let canonicalHash = Self.sha256Hex(canonical)
            // Skip redundant writes when the canonical already is this account.
            guard canonicalHash != env.lastCanonicalHash else { return }
            var updated = env
            updated.blob = mergeClaudeIdentityIntoBlob(canonical: canonical, existingBlob: env.blob)
            updated.lastCanonicalHash = canonicalHash
            try vault.put(accountId: uuid, updated)
        }
    }

    /// Pair a canonical credential blob with its identity when the blob itself
    /// carries none: newer Claude CLI versions embed no accountUuid in the keychain
    /// item — the identity lives only in `~/.claude.json`, which the CLI writes
    /// together with the credential. Merging its `oauthAccount` in lets the
    /// identity-attribution guards work on new-format blobs. A blob that already
    /// carries an identity is returned untouched (never overridden).
    private func identityPairedCanonical(_ canonical: Data) -> Data {
        guard Self.claudeAccountUuid(from: canonical) == nil else { return canonical }
        guard
            var dict = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any],
            dict["claudeAiOauth"] != nil, // only pair a real credential blob
            let identityData = try? Data(contentsOf: paths.claudeIdentityFile),
            let identity = (try? JSONSerialization.jsonObject(with: identityData)) as? [String: Any],
            let oauthAccount = identity["oauthAccount"] as? [String: Any],
            oauthAccount["accountUuid"] is String
        else {
            return canonical
        }
        dict["oauthAccount"] = oauthAccount
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? canonical
    }

    /// Whether a canonical Claude blob carries a `claudeAiOauth.refreshToken` that is a
    /// non-empty string. Never logs the token value.
    private static func claudeHasRefreshToken(_ canonical: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: canonical),
              let dict = object as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String,
              !refresh.isEmpty else {
            return false
        }
        return true
    }

    /// The `oauthAccount` identity block of a vault blob, if present. A blob without
    /// one cannot complete a swap (the identity file rewrite would silently no-op,
    /// leaving credential and identity pointing at different accounts).
    private static func claudeIdentityBlock(in blob: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: blob),
              let dict = object as? [String: Any] else { return nil }
        return dict["oauthAccount"] as? [String: Any]
    }

    /// Carry the live canonical `claudeAiOauth`/`mcpOAuth` into a vault blob while
    /// preserving its `oauthAccount` identity block.
    private func mergeClaudeIdentityIntoBlob(canonical: Data, existingBlob: Data) -> Data {
        guard let canonObject = try? JSONSerialization.jsonObject(with: canonical),
              var canonDict = canonObject as? [String: Any] else {
            return existingBlob
        }
        if let existingObject = try? JSONSerialization.jsonObject(with: existingBlob),
           let existingDict = existingObject as? [String: Any],
           let oauthAccount = existingDict["oauthAccount"] {
            canonDict["oauthAccount"] = oauthAccount
        }
        return (try? JSONSerialization.data(withJSONObject: canonDict, options: [.sortedKeys])) ?? existingBlob
    }

    // MARK: System-default snapshot / restore

    /// Capture the user's current canonical identity into the vault under the
    /// reserved `system-default` id. Idempotent: a no-op if a snapshot exists.
    public func captureSystemDefaultSnapshot() throws {
        try withLock {
            if (try vault.get(accountId: CredentialVault.systemDefaultAccountID)) != nil {
                return
            }

            let backend = detectClaudeBackend()
            if backend == .keychain || backend == .file {
                let canonical = try readClaudeCanonicalBlobLocked(backend: backend)
                let identity = (try? Data(contentsOf: paths.claudeIdentityFile))
                let blob = composeClaudeSnapshotBlob(canonical: canonical, identityFile: identity)
                let envelope = VaultEnvelope(
                    tool: .claude,
                    backend: backend.rawValue,
                    identityFingerprint: Self.claudeAccountUuid(from: canonical),
                    lastCanonicalHash: Self.sha256Hex(canonical),
                    blob: blob
                )
                try vault.put(accountId: CredentialVault.systemDefaultAccountID, envelope)
            } else if fileManager.fileExists(atPath: paths.codexAuthFile.path),
                      let canonical = try? Data(contentsOf: paths.codexAuthFile) {
                let envelope = VaultEnvelope(
                    tool: .codex,
                    backend: "codex",
                    identityFingerprint: Self.codexAccountId(from: canonical),
                    lastCanonicalHash: Self.sha256Hex(canonical),
                    blob: canonical
                )
                try vault.put(accountId: CredentialVault.systemDefaultAccountID, envelope)
            }
        }
    }

    /// Compose a Claude snapshot blob `{claudeAiOauth, mcpOAuth, oauthAccount}` from
    /// the live canonical credential blob plus the `~/.claude.json` identity file.
    private func composeClaudeSnapshotBlob(canonical: Data, identityFile: Data?) -> Data {
        var dict = ((try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any]) ?? [:]
        if let identityFile,
           let object = try? JSONSerialization.jsonObject(with: identityFile),
           let identityDict = object as? [String: Any],
           let oauthAccount = identityDict["oauthAccount"] {
            dict["oauthAccount"] = oauthAccount
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? canonical
    }

    /// Restore the captured `system-default` identity, routed through the SAME swap
    /// path so `mcpOAuth` is preserved.
    public func restoreSystemDefault() throws {
        guard let envelope = try vault.get(accountId: CredentialVault.systemDefaultAccountID) else {
            throw ChewyError.missingCredentialReference(CredentialVault.systemDefaultAccountID)
        }
        let profile = AccountProfile(
            tool: envelope.tool,
            name: "System Default",
            slug: CredentialVault.systemDefaultAccountID,
            homePath: "",
            isImported: false
        )
        switch envelope.tool {
        case .claude:
            try swapToClaudeUsingSnapshot(profile: profile)
        case .codex:
            try swapToCodex(account: profile)
        }
    }

    /// Restore path for Claude: same locked merge/write as swapToClaude, but sources
    /// the blob from the system-default envelope by id.
    private func swapToClaudeUsingSnapshot(profile: AccountProfile) throws {
        try withLock {
            let backend = detectClaudeBackend()
            switch backend {
            case .keychain, .file:
                break
            default:
                throw ChewyError.ambiguousClaudeBackend(backend.rawValue)
            }
            guard let envelope = try vault.get(accountId: CredentialVault.systemDefaultAccountID) else {
                throw ChewyError.missingCredentialReference(CredentialVault.systemDefaultAccountID)
            }
            try writeClaudeCanonicalLocked(blob: envelope.blob, backend: backend)
            try rewriteClaudeIdentityLocked(from: envelope.blob)
            let written = try readClaudeCanonicalBlobLocked(backend: backend)
            try recordCanonicalHash(Self.sha256Hex(written), for: CredentialVault.systemDefaultAccountID)
        }
    }

    // MARK: Active token (read-only, for usage polling)

    /// Read the live canonical Claude OAuth access token (`claudeAiOauth.accessToken`)
    /// from whichever backend is active. Returns nil if no usable token is present
    /// (no account, ambiguous/malformed/denied backend, or missing field).
    ///
    /// Reuses the same backend detection and canonical read as the swap path. The
    /// returned secret is for in-process use only — NEVER log or print it.
    public func activeClaudeAccessToken() throws -> String? {
        // Detect the backend INSIDE the lock: a concurrent swap could change the
        // live backend between detection and the canonical read otherwise.
        let canonical: Data? = try withLock {
            let backend = detectClaudeBackend()
            guard backend == .keychain || backend == .file else {
                // Ambiguous/malformed/denied: fail soft — no token rather than guess.
                return nil
            }
            return try readClaudeCanonicalBlobLocked(backend: backend)
        }
        guard let canonical,
              let object = try? JSONSerialization.jsonObject(with: canonical),
              let dict = object as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    // MARK: Vault hash bookkeeping

    private func recordCanonicalHash(_ hash: String, for accountId: String) throws {
        guard var envelope = try vault.get(accountId: accountId) else { return }
        envelope.lastCanonicalHash = hash
        try vault.put(accountId: accountId, envelope)
    }

    // MARK: Locking

    /// Serializes in-process callers. `flock` is per-file-descriptor: two callers
    /// in THIS process each opening a fresh fd would both "acquire" the flock, so
    /// the flock alone only excludes other processes. `withLock` is never nested
    /// (the `*Locked` variants are used inside locked regions), so a plain
    /// non-recursive lock cannot self-deadlock.
    private let inProcessLock = NSLock()

    /// Acquire the in-process lock, then a cross-process advisory (flock) lock,
    /// for the duration of `body`. Serializes only Chewy's own callers;
    /// external writers (the CLIs themselves) are handled by drift attribution.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        inProcessLock.lock()
        defer { inProcessLock.unlock() }

        let directory = lockFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw ChewyError.applicationSupportUnavailable
        }
        defer { close(descriptor) }

        // Retry on EINTR: flock can be interrupted by a signal before the lock is
        // acquired; a single interrupt must not fail the whole swap.
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw ChewyError.keychainFailure(OSStatus(errno))
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    // MARK: Helpers

    private func setPrivatePermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Stable vault id for an account. Prefers the canonical identity
    /// (`accountId` — Claude `accountUuid` / Codex ChatGPT account id) that
    /// capture and migration both persist, so every code path keys the vault the
    /// SAME way. Falls back to organizationUuid then the local id only for
    /// legacy/incomplete profiles.
    public static func accountId(for account: AccountProfile) -> String {
        account.accountId ?? account.organizationUuid ?? account.id.uuidString
    }

    /// SHA256 hex digest of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func claudeAccountUuid(from canonical: Data) -> String? {
        CredentialBlob.claudeIdentity(fromBlob: canonical)?.accountUuid
    }

    static func claudeAccountUuid(fromBlob blob: Data) -> String? {
        claudeAccountUuid(from: blob)
    }

    static func codexAccountId(from data: Data) -> String? {
        CredentialBlob.codexIdentity(fromAuthJSON: data)?.accountId
    }
}
