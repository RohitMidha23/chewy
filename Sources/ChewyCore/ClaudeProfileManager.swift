import Foundation

public enum ClaudeAuthEnvironment: String, Codable, CaseIterable, Sendable {
    case anthropicAPIKey = "ANTHROPIC_API_KEY"
    case anthropicAuthToken = "ANTHROPIC_AUTH_TOKEN"
    case claudeCodeOAuthToken = "CLAUDE_CODE_OAUTH_TOKEN"

    public var displayName: String {
        switch self {
        case .anthropicAPIKey:
            return "Anthropic API Key"
        case .anthropicAuthToken:
            return "Anthropic Auth Token"
        case .claudeCodeOAuthToken:
            return "Claude Code OAuth Token"
        }
    }
}

public final class ClaudeProfileManager {
    private let paths: ChewyPaths
    private let credentialStore: CredentialStore

    public init(paths: ChewyPaths, credentialStore: CredentialStore = KeychainCredentialStore()) {
        self.paths = paths
        self.credentialStore = credentialStore
    }

    public func createOAuthConfigHome(slug: String) throws -> URL {
        let url = profileHomeURL(slug: slug)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public func profileHomeURL(slug: String) -> URL {
        paths.profilesDirectory
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }
}
