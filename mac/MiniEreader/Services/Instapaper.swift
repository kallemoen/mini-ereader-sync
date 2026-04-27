import Foundation

enum InstapaperError: Error, LocalizedError {
    case missingCredentials
    case httpError(Int, String)
    case apiError(code: Int, message: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Instapaper credentials not configured."
        case .httpError(let code, let body): return "Instapaper HTTP \(code): \(body)"
        case .apiError(let code, let message): return "Instapaper: \(message) (\(code))"
        case .parseError(let msg): return "Instapaper parse error: \(msg)"
        }
    }
}

/// Instapaper returns `[{"type":"error","error_code":N,"message":"..."}]` on API errors.
/// Surface a clean message instead of dumping the raw JSON into the UI.
private func decodeInstapaperError(from data: Data) -> InstapaperError? {
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let first = array.first,
          (first["type"] as? String) == "error",
          let code = first["error_code"] as? Int,
          let message = first["message"] as? String else {
        return nil
    }
    return .apiError(code: code, message: message)
}

struct InstapaperBookmark: Decodable {
    let type: String?
    let bookmark_id: Int64?
    let title: String?
    let url: String?
    let description: String?
    let time: Double?
}

final class Instapaper {
    static let shared = Instapaper()

    private let baseURL = URL(string: "https://www.instapaper.com/api/1")!

    private func creds() throws -> OAuth1.Credentials {
        guard let ck = Keychain.get(.instapaperConsumerKey),
              let cs = Keychain.get(.instapaperConsumerSecret) else {
            throw InstapaperError.missingCredentials
        }
        let token = Library.shared.oauthToken
        return OAuth1.Credentials(
            consumerKey: ck,
            consumerSecret: cs,
            token: token?.token,
            tokenSecret: token?.secret
        )
    }

    /// Mint an access token via xAuth using the stored username+password,
    /// persist it in the kv table, and delete the password from the Keychain.
    func mintTokenIfNeeded() async throws {
        if Library.shared.oauthToken != nil { return }
        guard let username = Keychain.get(.instapaperUsername),
              let password = Keychain.get(.instapaperPassword) else {
            throw InstapaperError.missingCredentials
        }
        let url = baseURL.appendingPathComponent("oauth/access_token")
        let body = [
            "x_auth_username": username,
            "x_auth_password": password,
            "x_auth_mode": "client_auth"
        ]
        let req = OAuth1.signedPOSTRequest(url: url, bodyParams: body, creds: try creds())
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw InstapaperError.httpError(http.statusCode, bodyString)
        }
        // Response is form-encoded: oauth_token=...&oauth_token_secret=...
        let pairs = bodyString.split(separator: "&").reduce(into: [String: String]()) { acc, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                acc[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        guard let token = pairs["oauth_token"], let secret = pairs["oauth_token_secret"] else {
            throw InstapaperError.parseError("Missing oauth_token/secret in response")
        }
        try Library.shared.kvSet("instapaper_oauth_token", token)
        try Library.shared.kvSet("instapaper_oauth_secret", secret)
        Keychain.delete(.instapaperPassword) // no longer needed
    }

    func listBookmarks(limit: Int = 50) async throws -> [InstapaperBookmark] {
        try await mintTokenIfNeeded()
        let url = baseURL.appendingPathComponent("bookmarks/list")
        let req = OAuth1.signedPOSTRequest(
            url: url,
            bodyParams: ["limit": String(limit)],
            creds: try creds()
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            if let apiErr = decodeInstapaperError(from: data) { throw apiErr }
            throw InstapaperError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode([InstapaperBookmark].self, from: data)
        return decoded.filter { $0.type == "bookmark" && $0.bookmark_id != nil }
    }

    /// Returns the text-view HTML for a bookmark.
    func getText(bookmarkID: Int64) async throws -> String {
        try await mintTokenIfNeeded()
        let url = baseURL.appendingPathComponent("bookmarks/get_text")
        let req = OAuth1.signedPOSTRequest(
            url: url,
            bodyParams: ["bookmark_id": String(bookmarkID)],
            creds: try creds()
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            if let apiErr = decodeInstapaperError(from: data) { throw apiErr }
            throw InstapaperError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension InstapaperBookmark {
    func toArticle() -> Article? {
        guard let id = bookmark_id, let url = url, let title = title else { return nil }
        let addedAt = time.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Article(
            id: id,
            url: url,
            title: title,
            author: nil,
            addedAt: addedAt,
            status: .new,
            epubPath: nil,
            errorMessage: nil,
            syncedAt: nil,
            removedFromSource: false
        )
    }
}
