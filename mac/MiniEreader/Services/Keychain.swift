import Foundation

/// Secret storage.
///
/// On a paid Apple Developer account the macOS Keychain is the right home for these,
/// but ad-hoc signed dev builds re-prompt every time the code signature changes.
/// For a single-user personal-fork tool we instead store secrets in a 0600-permission
/// JSON file under Application Support. macOS user separation + FileVault protect
/// the same threat model this app actually has.
///
/// The `Keychain` enum name is kept so call-sites don't have to change.
enum Keychain {
    enum Key: String, CaseIterable {
        case instapaperConsumerKey = "instapaper_consumer_key"
        case instapaperConsumerSecret = "instapaper_consumer_secret"
        case instapaperUsername = "instapaper_username"
        case instapaperPassword = "instapaper_password"
        case anthropicAPIKey = "anthropic_api_key"
        case firecrawlAPIKey = "firecrawl_api_key"
    }

    private static var secretsURL: URL {
        Library.supportDirectory.appendingPathComponent("secrets.json")
    }

    private static let queue = DispatchQueue(label: "com.mini-ereader.secrets")
    private static var cache: [String: String] = [:]
    private static var loaded = false

    // MARK: - Public API

    static func get(_ key: Key) -> String? {
        queue.sync {
            loadIfNeeded()
            return cache[key.rawValue]
        }
    }

    static func set(_ value: String, for key: Key) {
        queue.sync {
            loadIfNeeded()
            cache[key.rawValue] = value
            persist()
        }
    }

    static func delete(_ key: Key) {
        queue.sync {
            loadIfNeeded()
            cache.removeValue(forKey: key.rawValue)
            persist()
        }
    }

    // MARK: - Internals

    private static func loadIfNeeded() {
        if loaded { return }
        defer { loaded = true }

        if let data = try? Data(contentsOf: secretsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            cache = obj
        }
        // Intentionally no Keychain migration: reading the legacy Keychain would
        // re-trigger the very prompts we're trying to escape. Users re-enter once
        // in Settings, then secrets.json lives forever.
    }

    private static func persist() {
        do {
            let data = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
            try data.write(to: secretsURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: secretsURL.path
            )
        } catch {
            NSLog("Keychain.persist failed: \(error)")
        }
    }

}

extension Library {
    var oauthToken: (token: String, secret: String)? {
        guard let tok = (try? kvGet("instapaper_oauth_token")) ?? nil,
              let sec = (try? kvGet("instapaper_oauth_secret")) ?? nil
        else { return nil }
        return (tok, sec)
    }
}
