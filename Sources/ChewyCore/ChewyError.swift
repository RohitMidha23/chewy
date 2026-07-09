import Foundation

public enum ChewyError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case unsupportedTool(AccountTool)
    case invalidProfileName
    case profileAlreadyExists(String)
    case missingCodexHome(URL)
    case noImportableCodexFiles(URL)
    case invalidCodexHome(URL)
    case missingExecutable(String)
    case emptySecret
    case missingCredentialReference(String)
    case keychainFailure(OSStatus)
    case ambiguousClaudeBackend(String)
    case vaultUndecodable
    case vaultSchemaTooNew(Int)
    case credentialNeedsReconnect(String)
    case canonicalWriteCorrupted

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not locate the user's Application Support directory."
        case .unsupportedTool(let tool):
            return "\(tool.rawValue) is not supported by this operation yet."
        case .invalidProfileName:
            return "Profile name cannot be empty."
        case .profileAlreadyExists(let slug):
            return "A profile with slug '\(slug)' already exists."
        case .missingCodexHome(let url):
            return "Codex home does not exist at \(url.path)."
        case .noImportableCodexFiles(let url):
            return "No importable Codex auth/config files were found in \(url.path)."
        case .invalidCodexHome(let url):
            return "Codex profile home is invalid at \(url.path)."
        case .missingExecutable(let name):
            return "Could not find executable '\(name)'."
        case .emptySecret:
            return "Credential cannot be empty."
        case .missingCredentialReference(let profile):
            return "Profile '\(profile)' does not have a credential reference."
        case .keychainFailure(let status):
            return "Keychain operation failed with status \(status)."
        case .ambiguousClaudeBackend(let state):
            return "Claude credential backend is ambiguous (\(state)); resolve it before swapping. No write was performed."
        case .vaultUndecodable:
            return "The stored account vault could not be decoded. Nothing was overwritten."
        case .vaultSchemaTooNew(let version):
            return "The stored account vault uses a newer format (schema \(version)). Update Chewy to use it. Nothing was overwritten."
        case .credentialNeedsReconnect(let profile):
            return "The saved sign-in for '\(profile)' is incomplete — reconnect the account. No switch was performed."
        case .canonicalWriteCorrupted:
            return "The credential write did not verify and was rolled back. No account was switched."
        }
    }
}
