import CryptoKit
import Foundation

/// Errors thrown by ``CredentialMath`` operations.
public enum CredentialMathError: Error {
    case malformed
    case missingClaudeAiOauth
}

/// Pure, dependency-free credential math: deterministic hashing and JSON merging.
///
/// These helpers never print or log token values.
public enum CredentialMath {
    /// First 8 lowercase hex characters of SHA256 over the UTF-8 bytes of `homePath`.
    public static func keychainSuffix(forHome homePath: String) -> String {
        let digest = SHA256.hash(data: Data(homePath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    /// Merge a per-profile credential blob into the current canonical blob.
    ///
    /// The result is a copy of `currentCanonical` with its `"claudeAiOauth"` key
    /// replaced by the value from `profileBlob`. `"mcpOAuth"` (and every other
    /// key) is preserved from `currentCanonical`. Serialized with sorted keys.
    ///
    /// Throws ``CredentialMathError/malformed`` if either input is not a JSON
    /// object, or ``CredentialMathError/missingClaudeAiOauth`` if `profileBlob`
    /// lacks a `"claudeAiOauth"` key.
    public static func mergedCanonicalBlob(profileBlob: Data, currentCanonical: Data) throws -> Data {
        guard
            let profileObject = try? JSONSerialization.jsonObject(with: profileBlob),
            let profile = profileObject as? [String: Any],
            let canonicalObject = try? JSONSerialization.jsonObject(with: currentCanonical),
            var canonical = canonicalObject as? [String: Any]
        else {
            throw CredentialMathError.malformed
        }

        guard let claudeAiOauth = profile["claudeAiOauth"] else {
            throw CredentialMathError.missingClaudeAiOauth
        }

        canonical["claudeAiOauth"] = claudeAiOauth

        return try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
    }
}
