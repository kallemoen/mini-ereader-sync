import Foundation
import Combine
import GRDB

/// On-disk SQLite library. Single source of truth for article state.
final class Library {
    static let shared = Library()

    private let dbQueue: DatabaseQueue

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MiniEreader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let path = Self.supportDirectory.appendingPathComponent("library.sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        self.dbQueue = try! DatabaseQueue(path: path, configuration: config)
        try! migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "articles") { t in
                t.column("id", .integer).primaryKey()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("added_at", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "new")
                t.column("epub_path", .text)
                t.column("error_message", .text)
                t.column("synced_at", .datetime)
            }
            try db.create(index: "idx_articles_status", on: "articles", columns: ["status", "added_at"])

            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2_removed_flag") { db in
            try db.alter(table: "articles") { t in
                t.add(column: "removed_from_source", .boolean).notNull().defaults(to: false)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Articles

    func upsertNew(_ articles: [Article]) throws -> Int {
        try dbQueue.write { db in
            var inserted = 0
            for article in articles {
                if try Article.filter(key: article.id).fetchOne(db) == nil {
                    try article.insert(db)
                    inserted += 1
                }
            }
            return inserted
        }
    }

    func all(ordered: Bool = true) throws -> [Article] {
        try dbQueue.read { db in
            var request = Article.all()
            if ordered {
                request = request.order(Article.Columns.addedAt.desc)
            }
            return try request.fetchAll(db)
        }
    }

    func observeAll() -> DatabasePublishers.Value<[Article]> {
        let observation = ValueObservation.tracking { db in
            try Article.order(Article.Columns.addedAt.desc).fetchAll(db)
        }
        return observation.publisher(in: dbQueue)
    }

    func pendingConversion() throws -> [Article] {
        try dbQueue.read { db in
            try Article.filter(Article.Columns.status == ArticleStatus.new.rawValue)
                .filter(Article.Columns.id > 0)
                .order(Article.Columns.addedAt.asc)
                .fetchAll(db)
        }
    }

    func readyToSync() throws -> [Article] {
        try dbQueue.read { db in
            try Article.filter(Article.Columns.status == ArticleStatus.converted.rawValue)
                .order(Article.Columns.addedAt.asc)
                .fetchAll(db)
        }
    }

    func updateTitle(id: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE articles SET title = ? WHERE id = ?",
                           arguments: [title, id])
        }
    }

    /// Insert a manually-added article (user dropped an EPUB into the cache).
    /// Marked with the same row shape as Instapaper articles so the rest of
    /// the pipeline doesn't need special-casing.
    func insertManual(_ article: Article) throws {
        try dbQueue.write { db in
            try article.insert(db)
        }
    }

    func deleteArticle(_ id: Int64) throws {
        try dbQueue.write { db in
            _ = try Article.filter(key: id).deleteAll(db)
        }
    }

    /// Reconcile which Instapaper-sourced rows are still in the user's inbox.
    /// Rows whose id is in `activeIDs` are un-flagged; everything else with a
    /// positive id gets flagged as removed-from-source.
    func markInstapaperRemovals(activeIDs: Set<Int64>) throws {
        try dbQueue.write { db in
            let stored = try Int64.fetchAll(db, sql: "SELECT id FROM articles WHERE id > 0")
            for id in stored {
                let isActive = activeIDs.contains(id)
                try db.execute(
                    sql: "UPDATE articles SET removed_from_source = ? WHERE id = ?",
                    arguments: [isActive ? 0 : 1, id]
                )
            }
        }
    }

    func setStatus(_ id: Int64, status: ArticleStatus, epubPath: String? = nil,
                   errorMessage: String? = nil, syncedAt: Date? = nil) throws {
        try dbQueue.write { db in
            if var article = try Article.filter(key: id).fetchOne(db) {
                article.status = status
                if let epubPath { article.epubPath = epubPath }
                article.errorMessage = errorMessage
                if let syncedAt { article.syncedAt = syncedAt }
                try article.update(db)
            }
        }
    }

    // MARK: - KV

    func kvGet(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    func kvSet(_ key: String, _ value: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)",
                           arguments: [key, value])
        }
    }

    func kvDelete(_ key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
        }
    }
}
