import Foundation
import Combine
import SwiftUI

/// Central coordinator: owns the articles list, sync state, background tasks,
/// and the Wi-Fi monitor. Views observe this.
@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?

    @Published var articles: [Article] = []
    @Published var isSyncing: Bool = false
    @Published var lastSyncResult: String?
    @Published var lastPollError: String?
    @Published var needsSettings: Bool = false

    let wifi = WiFiMonitor()

    private var articlesCancellable: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var convertTask: Task<Void, Never>?

    var newCount: Int {
        articles.filter { $0.status == .new || $0.status == .converting || $0.status == .converted }.count
    }

    var readyCount: Int {
        articles.filter { $0.status == .converted }.count
    }

    func start() {
        needsSettings = !hasRequiredSecrets()
        wifi.start()

        articlesCancellable = Library.shared.observeAll()
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] items in
                      self?.articles = items
                  })

        if !needsSettings {
            ManualFileScanner.scan()
            reconcileLibrary()
            schedulePolling()
            scheduleConversion()
        }
    }

    /// Invariant: article status should reflect reality on disk.
    ///   - File exists + never synced → .converted (ready to sync)
    ///   - File exists + synced_at set → leave as .synced
    ///   - File missing                → .new (needs conversion)
    ///
    /// This also clears stale `.error` rows: a transient failure shouldn't
    /// leave an article stuck forever. If the underlying cause is still real,
    /// the next conversion/sync attempt will re-mark it.
    private func reconcileLibrary() {
        guard let all = try? Library.shared.all() else { return }
        for article in all {
            let hasFile = articleFileExists(article)
            let wasSynced = article.syncedAt != nil

            if hasFile {
                if article.status != .synced {
                    let target: ArticleStatus = wasSynced ? .synced : .converted
                    if article.status != target {
                        try? Library.shared.setStatus(article.id, status: target)
                    }
                }
            } else {
                if article.status != .converting && article.status != .new {
                    try? Library.shared.setStatus(article.id, status: .new)
                }
            }
        }
    }

    /// True if the article's EPUB is present on disk. Instapaper articles live
    /// at `epubs/{id}.epub`; manually imported articles keep their original
    /// filename, recorded in `epubPath`.
    private func articleFileExists(_ article: Article) -> Bool {
        if let path = article.epubPath, FileManager.default.fileExists(atPath: path) {
            return true
        }
        return FileCache.exists(for: article.id)
    }

    func onSettingsSaved() {
        needsSettings = false
        schedulePolling()
        scheduleConversion()
        Task { await pollNow() }
    }

    private func hasRequiredSecrets() -> Bool {
        Keychain.get(.instapaperConsumerKey) != nil &&
        Keychain.get(.instapaperConsumerSecret) != nil &&
        Keychain.get(.anthropicAPIKey) != nil &&
        Keychain.get(.firecrawlAPIKey) != nil &&
        (Library.shared.oauthToken != nil ||
         (Keychain.get(.instapaperUsername) != nil && Keychain.get(.instapaperPassword) != nil))
    }

    // MARK: - Polling

    private func schedulePolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                await self?.pollNow()
            }
        }
    }

    func pollNow() async {
        // Reconcile first so stuck error rows clear whenever the user hits
        // Refresh — independent of whether the Instapaper call succeeds.
        ManualFileScanner.scan()
        reconcileLibrary()
        do {
            let bookmarks = try await Instapaper.shared.listBookmarks(limit: 200)
            let articles = bookmarks.compactMap { $0.toArticle() }
            _ = try Library.shared.upsertNew(articles)
            let activeIDs = Set(articles.map { $0.id })
            try Library.shared.markInstapaperRemovals(activeIDs: activeIDs)
            lastPollError = nil
            reconcileLibrary()
        } catch {
            if isOfflineError(error) {
                // Hide the scary offline message while we're on the reader —
                // the next Refresh once back on real Wi-Fi will succeed.
                lastPollError = nil
            } else {
                lastPollError = error.localizedDescription
            }
        }
    }

    // MARK: - Conversion

    private func scheduleConversion() {
        convertTask?.cancel()
        convertTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runConversionBatch()
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    private func runConversionBatch() async {
        // While on the reader's AP there is no internet route, so Firecrawl
        // and Claude calls would fail. Skip the batch and let the loop retry
        // when we're back on a normal network.
        guard !wifi.isConnectedToReader else { return }
        guard let pending = try? Library.shared.pendingConversion(), !pending.isEmpty else { return }
        // Concurrency 2.
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<2 {
                if let first = iterator.next() {
                    group.addTask { [weak self] in await self?.convert(first) }
                }
            }
            while await group.next() != nil {
                if let next = iterator.next() {
                    group.addTask { [weak self] in await self?.convert(next) }
                }
            }
        }
    }

    private func convert(_ article: Article) async {
        try? Library.shared.setStatus(article.id, status: .converting)
        do {
            let cleaned: String
            var derivedTitle: String? = nil
            if let tweet = try await TwitterFallback.renderIfTwitter(url: article.url) {
                // Tweet content is short and clean — running it through Claude
                // tends to drop the body. Use the generated HTML directly.
                cleaned = tweet.html
                derivedTitle = tweet.title
            } else {
                let scraped = try await Firecrawl.scrape(url: article.url)
                cleaned = try await ClaudeFormatter.clean(markdown: scraped.markdown,
                                                          title: article.title)
                derivedTitle = scraped.title
            }

            // Fallback hierarchy: existing title → content-derived → URL-based.
            // Guarantees every EPUB has a non-empty title on the reader.
            let effectiveTitle = firstNonEmpty(article.title, derivedTitle,
                                               titleFromURL(article.url))
            if effectiveTitle != article.title {
                try? Library.shared.updateTitle(id: article.id, title: effectiveTitle)
            }

            let destination = FileCache.epubURL(for: article.id)
            let url = try EpubBuilder.build(
                cleanBodyHTML: cleaned,
                metadata: .init(id: article.id,
                                title: effectiveTitle,
                                author: article.author,
                                url: article.url,
                                publishedAt: article.addedAt),
                destination: destination
            )
            try Library.shared.setStatus(article.id, status: .converted, epubPath: url.path)
        } catch {
            // Transient network failures shouldn't burn the row as .error — the
            // user just needs to be back online. Leave it as .new so the next
            // batch picks it up automatically.
            if isOfflineError(error) {
                try? Library.shared.setStatus(article.id, status: .new)
            } else {
                try? Library.shared.setStatus(article.id, status: .error,
                                              errorMessage: error.localizedDescription)
            }
        }
    }

    /// Returns the first argument that's non-nil and not blank.
    private func firstNonEmpty(_ values: String?...) -> String {
        for v in values {
            if let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return "Untitled"
    }

    /// Last-resort title derived from the article URL. Uses the last
    /// meaningful path segment (or host) so a bookmark like
    /// `https://example.com/2026/04/my-post/` becomes "my post".
    private func titleFromURL(_ url: String) -> String? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        let segments = u.pathComponents
            .filter { $0 != "/" && !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        if let slug = segments.last {
            let pretty = slug
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: ".html", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !pretty.isEmpty { return pretty.capitalized }
        }
        return host
    }

    private func isOfflineError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return ns.code == NSURLErrorNotConnectedToInternet
            || ns.code == NSURLErrorNetworkConnectionLost
            || ns.code == NSURLErrorCannotFindHost
            || ns.code == NSURLErrorCannotConnectToHost
            || ns.code == NSURLErrorTimedOut
    }

    /// Mark a synced row as ready-to-sync again without re-running conversion
    /// (EPUB is already on disk). If the file is missing, fall back to a
    /// full re-convert.
    func resync(_ article: Article) {
        if FileCache.exists(for: article.id) {
            let path = FileCache.epubURL(for: article.id).path
            try? Library.shared.setStatus(article.id, status: .converted, epubPath: path)
        } else {
            try? Library.shared.setStatus(article.id, status: .new)
        }
    }

    /// Force the Firecrawl/Claude pipeline to run again: delete the cached
    /// EPUB and flip status to 'new' so the conversion worker picks it up.
    func reconvert(_ article: Article) {
        let url = FileCache.epubURL(for: article.id)
        try? FileManager.default.removeItem(at: url)
        try? Library.shared.setStatus(article.id, status: .new)
    }

    /// Copy user-provided EPUB files into the cache and register them as
    /// manual articles. Non-epub inputs are ignored. Returns the number of
    /// files successfully imported.
    @discardableResult
    func importManualEPUBs(_ urls: [URL]) -> Int {
        let dir = FileCache.epubsDir
        var imported = 0
        for src in urls where src.pathExtension.lowercased() == "epub" {
            let dest = uniqueDestination(in: dir, for: src.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                imported += 1
            } catch {
                NSLog("[manual] copy failed for %@: %@", src.path, error.localizedDescription)
            }
        }
        if imported > 0 {
            ManualFileScanner.scan()
            reconcileLibrary()
            lastSyncResult = "Imported \(imported) file\(imported == 1 ? "" : "s")"
        }
        return imported
    }

    private func uniqueDestination(in dir: URL, for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    /// Remove the local EPUB and the DB row. Used when an article has been
    /// removed from Instapaper or when the user wants to drop a manual file.
    /// Does NOT delete the file from the reader — sync history stays.
    func deleteLocally(_ article: Article) {
        if let path = article.epubPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(at: FileCache.epubURL(for: article.id))
        }
        try? Library.shared.deleteArticle(article.id)
    }

    // MARK: - Connect + Sync

    /// One-click flow: if we're not on the reader but it's in range, associate
    /// with it, sync, and then rejoin the previous Wi-Fi network.
    func connectAndSync() async {
        guard readyCount > 0 else {
            lastSyncResult = "Nothing to sync."
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        if !wifi.isConnectedToReader {
            lastSyncResult = "Connecting to \(WiFiMonitor.expectedSSID)…"
            do {
                try await wifi.connectToReader()
            } catch {
                lastSyncResult = error.localizedDescription
                return
            }
        }

        await performSync()

        // Best-effort rejoin. Don't surface errors prominently — users can
        // always flip the menu bar Wi-Fi menu themselves.
        if wifi.previousSSID != nil {
            try? await wifi.reconnectToPrevious()
        }
    }

    // MARK: - Sync

    func syncNow() async {
        guard wifi.isConnectedToReader, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await performSync()
    }

    private func performSync() async {
        guard let ready = try? Library.shared.readyToSync(), !ready.isEmpty else {
            lastSyncResult = "Nothing to sync."
            return
        }

        var success = 0
        var failed = 0
        for article in ready {
            guard let path = article.epubPath else { continue }
            let url = URL(fileURLWithPath: path)
            let filename = sanitizedFilename(article.title, id: article.id)
            do {
                try await ReaderClient.uploadEPUB(at: url, filename: filename)
                try Library.shared.setStatus(article.id, status: .synced, syncedAt: Date())
                success += 1
            } catch {
                failed += 1
                if isOfflineError(error) {
                    // Transient: leave the row as .converted so it's ready to
                    // retry next time the reader is reachable.
                    continue
                }
                try? Library.shared.setStatus(article.id, status: .error,
                                              errorMessage: error.localizedDescription)
            }
        }

        if failed == 0 {
            lastSyncResult = "Synced \(success) article\(success == 1 ? "" : "s") ✓"
        } else {
            lastSyncResult = "Synced \(success), \(failed) failed"
        }
    }

    private func sanitizedFilename(_ title: String, id: Int64) -> String {
        let trimmed = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(80)
        return "\(trimmed) [\(id)].epub"
    }
}
