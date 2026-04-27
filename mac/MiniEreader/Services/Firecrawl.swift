import Foundation

enum FirecrawlError: Error, LocalizedError {
    case missingKey
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Firecrawl API key not configured."
        case .httpError(let code, let body): return "Firecrawl HTTP \(code): \(body.prefix(200))"
        case .parseError(let msg): return "Firecrawl parse error: \(msg)"
        }
    }
}

/// Fetches a URL via Firecrawl's /v1/scrape and returns clean markdown.
/// Handles JS-rendered pages (Twitter threads, Substacks behind paywalls, etc.).
enum Firecrawl {
    static let endpoint = URL(string: "https://api.firecrawl.dev/v1/scrape")!

    struct Result {
        let markdown: String
        let title: String?
    }

    static func scrape(url: String) async throws -> Result {
        guard let key = Keychain.get(.firecrawlAPIKey) else {
            throw FirecrawlError.missingKey
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let payload: [String: Any] = [
            "url": url,
            "formats": ["markdown"],
            "onlyMainContent": true,
            "waitFor": 2000
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw FirecrawlError.httpError(http.statusCode,
                                           String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirecrawlError.parseError("Response is not a JSON object")
        }
        if let success = json["success"] as? Bool, success == false {
            let msg = (json["error"] as? String) ?? "unknown error"
            throw FirecrawlError.parseError(msg)
        }
        guard let payload = json["data"] as? [String: Any],
              let markdown = payload["markdown"] as? String,
              !markdown.isEmpty else {
            throw FirecrawlError.parseError("No markdown in response")
        }
        let meta = payload["metadata"] as? [String: Any]
        let title = (meta?["title"] as? String)
            ?? (meta?["ogTitle"] as? String)
            ?? (meta?["twitterTitle"] as? String)
        return Result(markdown: markdown,
                      title: title?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
