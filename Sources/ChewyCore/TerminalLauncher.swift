import Foundation

public struct TerminalLauncher {
    private let paths: ChewyPaths
    private let fileManager: FileManager

    public init(paths: ChewyPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func makeCodexLaunchScript(profile: AccountProfile, workingDirectory: URL? = nil) throws -> URL {
        guard profile.tool == .codex else {
            throw ChewyError.unsupportedTool(profile.tool)
        }

        let script = renderCodexLaunchScript(profile: profile, workingDirectory: workingDirectory)
        return try writeLaunchScript(script, slug: profile.slug)
    }

    public func makeCodexLoginScript(profile: AccountProfile) throws -> URL {
        guard profile.tool == .codex else {
            throw ChewyError.unsupportedTool(profile.tool)
        }

        let script = renderCodexCommandScript(profile: profile, arguments: ["login"])
        return try writeLaunchScript(script, slug: "\(profile.slug)-login")
    }

    public func makeClaudeLaunchScript(profile: AccountProfile, workingDirectory: URL? = nil) throws -> URL {
        guard profile.tool == .claude else {
            throw ChewyError.unsupportedTool(profile.tool)
        }

        let script = try renderClaudeLaunchScript(profile: profile, workingDirectory: workingDirectory)
        return try writeLaunchScript(script, slug: profile.slug)
    }

    public func makeClaudeLoginScript(profile: AccountProfile) throws -> URL {
        guard profile.tool == .claude else {
            throw ChewyError.unsupportedTool(profile.tool)
        }

        let script = renderClaudeOAuthCommandScript(profile: profile, arguments: ["auth", "login"])
        return try writeLaunchScript(script, slug: "\(profile.slug)-login")
    }

    public func renderCodexLaunchScript(profile: AccountProfile, workingDirectory: URL? = nil) -> String {
        renderCodexCommandScript(profile: profile, workingDirectory: workingDirectory)
    }

    public func renderCodexCommandScript(
        profile: AccountProfile,
        workingDirectory: URL? = nil,
        arguments: [String] = []
    ) -> String {
        var lines = [
            "#!/bin/zsh",
            "set -euo pipefail",
            "export CODEX_HOME=\(Self.shellQuote(profile.homePath))"
        ]

        if let workingDirectory {
            lines.append("cd \(Self.shellQuote(workingDirectory.path))")
        }

        let renderedArguments = arguments.map(Self.shellQuote).joined(separator: " ")
        if renderedArguments.isEmpty {
            lines.append("exec /usr/bin/env codex \"$@\"")
        } else {
            lines.append("exec /usr/bin/env codex \(renderedArguments)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func renderClaudeLaunchScript(profile: AccountProfile, workingDirectory: URL? = nil) throws -> String {
        if profile.credentialReference == nil {
            return renderClaudeOAuthCommandScript(profile: profile, workingDirectory: workingDirectory)
        }

        guard let credentialReference = profile.credentialReference, !credentialReference.isEmpty else {
            throw ChewyError.missingCredentialReference(profile.name)
        }
        let environmentVariable = profile.authEnvironmentVariable ?? ClaudeAuthEnvironment.anthropicAPIKey.rawValue

        var lines = [
            "#!/bin/zsh",
            "set -euo pipefail",
            "SECRET=$(/usr/bin/security find-generic-password -s \(Self.shellQuote(KeychainCredentialStore.defaultService)) -a \(Self.shellQuote(credentialReference)) -w 2>/dev/null || true)",
            "if [[ -z \"$SECRET\" ]]; then",
            "  echo 'Chewy could not read the Claude credential from Keychain.'",
            "  echo 'Open Chewy and recreate this profile.'",
            "  read -k 1 -s '?Press any key to close.'",
            "  exit 1",
            "fi",
            "export \(environmentVariable)=\"$SECRET\"",
            "unset SECRET"
        ]

        if let workingDirectory {
            lines.append("cd \(Self.shellQuote(workingDirectory.path))")
        }

        lines.append("exec /usr/bin/env claude \"$@\"")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func renderClaudeOAuthCommandScript(
        profile: AccountProfile,
        workingDirectory: URL? = nil,
        arguments: [String] = []
    ) -> String {
        var lines = [
            "#!/bin/zsh",
            "set -euo pipefail",
            "export CLAUDE_CONFIG_DIR=\(Self.shellQuote(profile.homePath))"
        ]

        if let workingDirectory {
            lines.append("cd \(Self.shellQuote(workingDirectory.path))")
        }

        let renderedArguments = arguments.map(Self.shellQuote).joined(separator: " ")
        if renderedArguments.isEmpty {
            lines.append("exec /usr/bin/env claude \"$@\"")
        } else {
            lines.append("exec /usr/bin/env claude \(renderedArguments)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func writeLaunchScript(_ script: String, slug: String) throws -> URL {
        try fileManager.createDirectory(
            at: paths.launchesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let scriptURL = paths.launchesDirectory
            .appendingPathComponent("launch-\(slug)-\(UUID().uuidString).command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    public static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
