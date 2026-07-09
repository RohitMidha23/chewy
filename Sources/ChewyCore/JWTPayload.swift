import Foundation

/// Pure, dependency-free helpers for reading claims out of a JWT.
///
/// These helpers never crash on malformed input and never log token contents.
public enum JWTPayload {
    /// Decode the payload (middle) segment of a JWT into a JSON object.
    ///
    /// The middle segment is base64url-encoded. base64url differs from standard
    /// base64: `-` replaces `+`, `_` replaces `/`, and padding may be omitted.
    /// Returns `nil` for any malformed input rather than crashing.
    public static func decode(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        guard let data = base64urlDecode(String(segments[1])) else { return nil }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            return nil
        }

        return json
    }

    /// Return the `"email"` claim if present.
    public static func email(from jwt: String) -> String? {
        decode(jwt)?["email"] as? String
    }

    /// Return the ChatGPT account id nested under the OpenAI auth claim, if present.
    public static func chatgptAccountId(from jwt: String) -> String? {
        guard let payload = decode(jwt) else { return nil }
        guard let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    /// Decode a base64url string (no padding required) into raw bytes.
    private static func base64urlDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }
}
