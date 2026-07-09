import ChewyCore
import Foundation

/// base64url-encode raw bytes (no padding), matching the JWT encoding.
private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func checkJWTPayload() throws {
    let payload: [String: Any] = [
        "email": "a@b.com",
        "https://api.openai.com/auth": ["chatgpt_account_id": "acc1"]
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let token = "h." + base64urlEncode(payloadData) + ".sig"

    try check(JWTPayload.email(from: token) == "a@b.com", "JWT email claim should decode")
    try check(JWTPayload.chatgptAccountId(from: token) == "acc1", "JWT chatgpt_account_id should decode")
    try check(JWTPayload.decode("garbage") == nil, "garbage JWT should decode to nil")
}

func checkCredentialMath() throws {
    try check(CredentialMath.keychainSuffix(forHome: "/tmp/x") == "2e56aa36", "keychain suffix should be deterministic")
    try check(CredentialMath.keychainSuffix(forHome: "/tmp/x").count == 8, "keychain suffix should be 8 chars")

    let profile = Data(#"{"claudeAiOauth":{"access":"NEW"}}"#.utf8)
    let canonical = Data(#"{"claudeAiOauth":{"access":"OLD"},"mcpOAuth":{"posthog":1},"unknownTop":42}"#.utf8)

    let merged = try CredentialMath.mergedCanonicalBlob(profileBlob: profile, currentCanonical: canonical)
    let mergedString = String(decoding: merged, as: UTF8.self)
    let mergedObject = try JSONSerialization.jsonObject(with: merged) as? [String: Any]

    let mergedOauth = mergedObject?["claudeAiOauth"] as? [String: Any]
    try check(mergedOauth?["access"] as? String == "NEW", "merge should take claudeAiOauth from profile")

    let mergedMcp = mergedObject?["mcpOAuth"] as? [String: Any]
    try check((mergedMcp?["posthog"] as? Int) == 1, "merge should preserve mcpOAuth from canonical")

    try check((mergedObject?["unknownTop"] as? Int) == 42, "merge should preserve unknown canonical keys")
    try check(!mergedString.contains("OLD"), "merge result must not contain the old token value")

    // Canonical without mcpOAuth: no crash, result has no mcpOAuth.
    let canonicalNoMcp = Data(#"{"claudeAiOauth":{"access":"OLD"}}"#.utf8)
    let mergedNoMcp = try CredentialMath.mergedCanonicalBlob(profileBlob: profile, currentCanonical: canonicalNoMcp)
    let mergedNoMcpObject = try JSONSerialization.jsonObject(with: mergedNoMcp) as? [String: Any]
    try check(mergedNoMcpObject?["mcpOAuth"] == nil, "merge should not invent mcpOAuth")

    // Profile without claudeAiOauth should throw.
    let profileMissing = Data(#"{"other":1}"#.utf8)
    var threw = false
    do {
        _ = try CredentialMath.mergedCanonicalBlob(profileBlob: profileMissing, currentCanonical: canonical)
    } catch {
        threw = true
    }
    try check(threw, "merge should throw when profile lacks claudeAiOauth")
}
