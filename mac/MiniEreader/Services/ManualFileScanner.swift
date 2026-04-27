import Foundation

/// Scans the local EPUB cache directory for files that weren't placed there
/// by this app, and imports them as "manual" articles so they show up in the
/// library and can be synced to the reader alongside Instapaper imports.
///
/// Detection rule: files produced by our conversion pipeline are named
/// `{positive_int}.epub` (the Instapaper bookmark_id). Anything else — e.g.
/// `some-book.epub` dropped in by the user — is treated as manual.
enum ManualFileScanner {
    /// Run a scan. Returns the number of new rows inserted.
    @discardableResult
    static func scan() -> Int {
        let dir = FileCache.epubsDir
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            NSLog("[manual] enumerate failed: %@", error.localizedDescription)
            return 0
        }

        let known: [Article] = (try? Library.shared.all(ordered: false)) ?? []
        let knownPaths = Set(known.compactMap { $0.epubPath })
        let knownInstapaperIDs = Set(known.filter { $0.id > 0 }.map { $0.id })

        var inserted = 0
        for url in files where url.pathExtension.lowercased() == "epub" {
            if knownPaths.contains(url.path) { continue }

            let name = url.deletingPathExtension().lastPathComponent
            // Skip our own convention: <bookmark_id>.epub
            if let id = Int64(name), id > 0, knownInstapaperIDs.contains(id) { continue }
            if let id = Int64(name), id > 0 { continue } // orphaned id-named file; leave alone

            let manualID = stableNegativeID(for: url.path)
            if known.contains(where: { $0.id == manualID }) { continue }

            let addedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date()

            let article = Article(
                id: manualID,
                url: "file://\(url.path)",
                title: name,
                author: nil,
                addedAt: addedAt,
                status: .converted,
                epubPath: url.path,
                errorMessage: nil,
                syncedAt: nil,
                removedFromSource: false
            )
            do {
                try Library.shared.insertManual(article)
                inserted += 1
            } catch {
                NSLog("[manual] insert failed for %@: %@", url.path, error.localizedDescription)
            }
        }
        return inserted
    }

    /// A stable negative id derived from the file path. Using a hash (rather
    /// than e.g. a random id) means re-scanning after a restart doesn't
    /// duplicate rows for the same file. Collisions between 63-bit hash
    /// outputs are negligible for a local cache.
    private static func stableNegativeID(for path: String) -> Int64 {
        var hasher = Hasher()
        hasher.combine("manual-epub:")
        hasher.combine(path)
        let raw = hasher.finalize()
        // Fold to positive Int64 range, then negate. Never return 0.
        let positive = Int64(abs(Int64(bitPattern: UInt64(bitPattern: Int64(raw))) % Int64.max))
        return -max(positive, 1)
    }
}
