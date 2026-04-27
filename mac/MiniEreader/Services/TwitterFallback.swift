import Foundation

/// Firecrawl refuses to scrape x.com, so we route Twitter/X URLs through
/// api.fxtwitter.com. For plain tweets the text lives in `tweet.text`; for
/// long-form X Articles (Premium) the body is a Draft.js structure under
/// `tweet.article.content.blocks`. We handle both.
///
/// Returns ready-to-use XHTML — Claude's formatter strips short content too
/// aggressively, so we skip it and emit HTML directly.
enum TwitterFallback {
    struct Result {
        let html: String
        let title: String
    }

    static func renderIfTwitter(url: String) async throws -> Result? {
        guard let (screenName, tweetID) = parseTwitterURL(url) else { return nil }

        let apiURL = URL(string: "https://api.fxtwitter.com/\(screenName)/status/\(tweetID)")!
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = json["tweet"] as? [String: Any] else {
            return nil
        }

        let author = tweet["author"] as? [String: Any]
        let name = author?["name"] as? String ?? screenName
        let handle = author?["screen_name"] as? String ?? screenName
        let createdAt = tweet["created_at"] as? String ?? ""
        let text = tweet["text"] as? String ?? ""

        // X Article (long-form) — render Draft.js content.
        if let article = tweet["article"] as? [String: Any],
           let content = article["content"] as? [String: Any],
           let blocks = content["blocks"] as? [[String: Any]], !blocks.isEmpty {
            let entityMap = (content["entityMap"] as? [String: Any]) ?? [:]
            let articleTitle = (article["title"] as? String) ?? ""
            let html = renderArticle(title: articleTitle,
                                     author: name, handle: handle, createdAt: createdAt,
                                     blocks: blocks, entityMap: entityMap)
            let title = articleTitle.isEmpty ? deriveTweetTitle(text: text, author: name) : articleTitle
            return Result(html: html, title: title)
        }

        // Plain tweet — one header + paragraphs.
        if !text.isEmpty {
            let html = renderTweet(name: name, handle: handle, createdAt: createdAt,
                                   text: text, tweet: tweet)
            return Result(html: html, title: deriveTweetTitle(text: text, author: name))
        }

        // Nothing we can render.
        return nil
    }

    /// First sentence or first ~70 chars of the tweet, prefixed with author
    /// so it's recognizable in a menu bar list.
    private static func deriveTweetTitle(text: String, author: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "Tweet by \(author)" }
        let sentence = cleaned.split(whereSeparator: { ".!?\n".contains($0) })
            .first.map(String.init) ?? cleaned
        let snippet = sentence.count > 70 ? String(sentence.prefix(70)) + "…" : sentence
        return snippet
    }

    // MARK: - Plain tweet renderer

    private static func renderTweet(name: String, handle: String, createdAt: String,
                                    text: String, tweet: [String: Any]) -> String {
        var html = "<p><strong>\(escape(name))</strong> (@\(escape(handle)))"
        if !createdAt.isEmpty { html += " · <em>\(escape(createdAt))</em>" }
        html += "</p>\n"

        if let replyTo = tweet["replying_to_status"] as? [String: Any],
           let replyText = replyTo["text"] as? String {
            let replyAuthor = (replyTo["author"] as? [String: Any])?["screen_name"] as? String ?? "?"
            html += "<blockquote><p><em>In reply to @\(escape(replyAuthor)):</em> \(escape(replyText))</p></blockquote>\n"
        }

        for para in splitParagraphs(text) {
            html += "<p>\(lineBroken(para))</p>\n"
        }

        if let media = tweet["media"] as? [String: Any],
           let photos = media["photos"] as? [[String: Any]] {
            for photo in photos {
                if let u = photo["url"] as? String {
                    html += "<p><img src=\"\(escape(u))\" alt=\"\"/></p>\n"
                }
            }
        }
        return html
    }

    // MARK: - X Article (Draft.js) renderer

    private static func renderArticle(title: String,
                                      author: String, handle: String, createdAt: String,
                                      blocks: [[String: Any]],
                                      entityMap: [String: Any]) -> String {
        var html = ""
        if !title.isEmpty {
            html += "<h1>\(escape(title))</h1>\n"
        }
        html += "<p><strong>\(escape(author))</strong> (@\(escape(handle)))"
        if !createdAt.isEmpty { html += " · <em>\(escape(createdAt))</em>" }
        html += "</p>\n<hr/>\n"

        // List grouping: Draft.js emits one block per list item; we collapse
        // consecutive list-item blocks into a single <ul>/<ol>.
        var currentList: String? = nil

        func closeList() {
            if let list = currentList {
                html += "</\(list)>\n"
                currentList = nil
            }
        }

        for block in blocks {
            let type = block["type"] as? String ?? "unstyled"
            let rendered = renderInline(block: block, entityMap: entityMap)

            let listTag: String? = {
                switch type {
                case "unordered-list-item": return "ul"
                case "ordered-list-item":   return "ol"
                default:                    return nil
                }
            }()

            if listTag != currentList {
                closeList()
                if let listTag { html += "<\(listTag)>\n"; currentList = listTag }
            }

            switch type {
            case "header-one":   html += "<h1>\(rendered)</h1>\n"
            case "header-two":   html += "<h2>\(rendered)</h2>\n"
            case "header-three": html += "<h3>\(rendered)</h3>\n"
            case "header-four":  html += "<h4>\(rendered)</h4>\n"
            case "blockquote":   html += "<blockquote><p>\(rendered)</p></blockquote>\n"
            case "code-block":   html += "<pre><code>\(rendered)</code></pre>\n"
            case "unordered-list-item", "ordered-list-item":
                html += "<li>\(rendered)</li>\n"
            default:
                // Skip empty unstyled blocks, render the rest as paragraphs.
                let trimmed = rendered.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    html += "<p>\(rendered)</p>\n"
                }
            }
        }
        closeList()
        return html
    }

    /// Apply inline styles + entity ranges to a Draft.js block's text.
    /// Produces safe XHTML: text is escaped, tags are opened/closed at each
    /// style boundary, and link hrefs are resolved upfront so we never emit
    /// unmatched `<a>` / `</a>` tags (which cause strict XML parsers like
    /// expat — used by the CrossPoint firmware — to abort).
    private static func renderInline(block: [String: Any], entityMap: [String: Any]) -> String {
        let text = block["text"] as? String ?? ""
        let inlineStyles = (block["inlineStyleRanges"] as? [[String: Any]]) ?? []
        let entities = (block["entityRanges"] as? [[String: Any]]) ?? []
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }

        // href is nil when the character isn't part of a link OR when the
        // entity couldn't be resolved. Either way, no <a> gets emitted.
        struct Slot: Equatable {
            var bold = false, italic = false, underline = false, code = false
            var href: String? = nil
        }
        var slots = [Slot](repeating: Slot(), count: chars.count)

        for style in inlineStyles {
            guard let offset = style["offset"] as? Int,
                  let length = style["length"] as? Int,
                  let which = style["style"] as? String else { continue }
            let end = min(offset + length, chars.count)
            guard offset >= 0, offset < end else { continue }
            for i in offset..<end {
                switch which.uppercased() {
                case "BOLD":      slots[i].bold = true
                case "ITALIC":    slots[i].italic = true
                case "UNDERLINE": slots[i].underline = true
                case "CODE":      slots[i].code = true
                default: break
                }
            }
        }

        for ent in entities {
            guard let offset = ent["offset"] as? Int,
                  let length = ent["length"] as? Int,
                  let key = ent["key"] as? Int else { continue }
            let end = min(offset + length, chars.count)
            guard offset >= 0, offset < end else { continue }
            // Only write href for entities we can actually render as links.
            guard let href = linkHref(for: key, in: entityMap),
                  !href.isEmpty else { continue }
            for i in offset..<end { slots[i].href = href }
        }

        // Emit with tag transitions at each boundary.
        var out = ""
        var open = Slot()

        func closeOld(_ old: Slot, _ new: Slot) {
            // Close in reverse order of opening: link first, then inline styles.
            if old.href != new.href, old.href != nil { out += "</a>" }
            if old.code && !new.code { out += "</code>" }
            if old.underline && !new.underline { out += "</u>" }
            if old.italic && !new.italic { out += "</em>" }
            if old.bold && !new.bold { out += "</strong>" }
        }

        func openNew(_ old: Slot, _ new: Slot) {
            if !old.bold && new.bold { out += "<strong>" }
            if !old.italic && new.italic { out += "<em>" }
            if !old.underline && new.underline { out += "<u>" }
            if !old.code && new.code { out += "<code>" }
            if old.href != new.href, let href = new.href {
                out += "<a href=\"\(escape(href))\">"
            }
        }

        for (i, ch) in chars.enumerated() {
            let new = slots[i]
            if new != open {
                closeOld(open, new)
                openNew(open, new)
                open = new
            }
            out += escape(String(ch))
        }
        // Close any still-open tags at end-of-block.
        closeOld(open, Slot())
        return out
    }

    private static func linkHref(for key: Int, in entityMap: [String: Any]) -> String? {
        guard let ent = entityMap[String(key)] as? [String: Any],
              let type = ent["type"] as? String,
              let data = ent["data"] as? [String: Any] else { return nil }
        switch type.uppercased() {
        case "LINK":
            return data["url"] as? String ?? data["href"] as? String
        case "MENTION":
            if let screen = data["screen_name"] as? String {
                return "https://x.com/\(screen)"
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func splitParagraphs(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func lineBroken(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .map(escape)
            .joined(separator: "<br/>")
    }

    private static func parseTwitterURL(_ url: String) -> (screenName: String, tweetID: String)? {
        guard let u = URL(string: url),
              let host = u.host?.lowercased() else { return nil }
        let isTwitter = host == "x.com" || host.hasSuffix(".x.com")
                     || host == "twitter.com" || host.hasSuffix(".twitter.com")
        guard isTwitter else { return nil }

        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 3,
              parts[1].lowercased() == "status",
              !parts[0].isEmpty else { return nil }
        return (screenName: parts[0], tweetID: parts[2])
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}
