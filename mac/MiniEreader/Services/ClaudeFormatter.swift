import Foundation

enum ClaudeError: Error, LocalizedError {
    case missingKey
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Anthropic API key not configured."
        case .httpError(let code, let body): return "Claude HTTP \(code): \(body)"
        case .parseError(let msg): return "Claude parse error: \(msg)"
        }
    }
}

/// Sends raw article HTML to Claude and gets back clean body HTML.
enum ClaudeFormatter {
    static let model = "claude-sonnet-4-6"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You format articles for an e-ink reader. Given the markdown of a scraped article, return clean XHTML for the article body.

    Rules:
    - Preserve the full article text verbatim. Do not summarize, paraphrase, or omit content.
    - Convert markdown to valid XHTML using headings (h1–h6), paragraphs, <blockquote>, <ul>/<ol>/<li>, <a href="...">, <img src="..." alt="..."/>, <em>, <strong>, <code>, <pre>.
    - Strip obvious boilerplate: cookie banners, subscribe prompts, "related articles", share buttons, navigation, author bios disconnected from the main article.
    - If the content is a Twitter/X thread with multiple tweets, present them as a continuous narrative: each tweet becomes one or more paragraphs, in order. Do not repeat author/date metadata per tweet. If a tweet contains only a URL or image, include the image or a "[link]" reference.
    - Do not wrap output in <html>, <body>, <head>, or markdown code fences.
    - Self-close void elements: <img .../>, <br/>, <hr/>.
    """

    static func clean(markdown: String, title: String) async throws -> String {
        guard let key = Keychain.get(.anthropicAPIKey) else {
            throw ClaudeError.missingKey
        }

        let userText = "Title: \(title)\n\nMarkdown:\n\(markdown)"
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw ClaudeError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw ClaudeError.parseError("Unexpected response shape")
        }
        return text
    }
}
