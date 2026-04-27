import Foundation
import CryptoKit

/// Minimal OAuth 1.0a HMAC-SHA1 signer for Instapaper.
/// Handles xAuth token minting and signed POST requests.
enum OAuth1 {
    struct Credentials {
        let consumerKey: String
        let consumerSecret: String
        let token: String?
        let tokenSecret: String?
    }

    /// Percent-encoding per RFC 3986 section 5.1 (OAuth 1.0a spec).
    static func rfc3986(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Sign a POST request. `bodyParams` are x-www-form-urlencoded params
    /// included in the signature base string per the OAuth spec.
    static func signedPOSTRequest(url: URL,
                                   bodyParams: [String: String],
                                   creds: Credentials) -> URLRequest {
        var oauthParams: [String: String] = [
            "oauth_consumer_key": creds.consumerKey,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_version": "1.0"
        ]
        if let t = creds.token { oauthParams["oauth_token"] = t }

        // Build signature base string: all oauth_* + body params, sorted, encoded.
        var allParams = oauthParams
        for (k, v) in bodyParams { allParams[k] = v }

        let paramString = allParams
            .map { (rfc3986($0.key), rfc3986($0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let baseString = [
            "POST",
            rfc3986(url.absoluteString),
            rfc3986(paramString)
        ].joined(separator: "&")

        let signingKey = "\(rfc3986(creds.consumerSecret))&\(rfc3986(creds.tokenSecret ?? ""))"
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: key)
        let signature = Data(mac).base64EncodedString()
        oauthParams["oauth_signature"] = signature

        let authHeader = "OAuth " + oauthParams
            .map { "\(rfc3986($0.key))=\"\(rfc3986($0.value))\"" }
            .sorted()
            .joined(separator: ", ")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        if !bodyParams.isEmpty {
            let body = bodyParams
                .map { "\(rfc3986($0.key))=\(rfc3986($0.value))" }
                .sorted()
                .joined(separator: "&")
            req.httpBody = Data(body.utf8)
        }
        return req
    }
}
