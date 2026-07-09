import ChewyCore
import Foundation

enum ProfileAuthState: Equatable {
    case token
    case signedIn(String?)
    case needsLogin
    case unknown

    var label: String {
        switch self {
        case .token:
            return "Token"
        case .signedIn(let detail):
            return detail ?? "Ready"
        case .needsLogin:
            return "Needs login"
        case .unknown:
            return "Unknown"
        }
    }

    var isReady: Bool {
        switch self {
        case .token, .signedIn:
            return true
        case .needsLogin, .unknown:
            return false
        }
    }
}

struct ProfileDisplayState {
    /// `hasVaultCredential` is the source of truth for "signed in": after the v2
    /// vault migration a profile's staging home (and its `.claude.json`) may be
    /// gone while the credential lives on in the Keychain vault. The on-disk
    /// checks below remain only as a fallback for genuinely pending logins that
    /// haven't been captured into the vault yet.
    static func authState(for profile: AccountProfile, hasVaultCredential: Bool) -> ProfileAuthState {
        if profile.credentialReference != nil {
            return .token
        }
        if hasVaultCredential {
            return .signedIn(profile.emailAddress)
        }

        switch profile.tool {
        case .codex:
            let authURL = profile.homeURL.appendingPathComponent("auth.json", isDirectory: false)
            return FileManager.default.fileExists(atPath: authURL.path) ? .signedIn(nil) : .needsLogin
        case .claude:
            let configURL = profile.homeURL.appendingPathComponent(".claude.json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                return .needsLogin
            }
            return .signedIn(readClaudeAccountLabel(from: configURL))
        }
    }

    private static func readClaudeAccountLabel(from url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else {
            return nil
        }

        if let email = oauth["emailAddress"] as? String, !email.isEmpty {
            return email
        }
        if let org = oauth["organizationName"] as? String, !org.isEmpty {
            return org
        }
        return nil
    }
}
