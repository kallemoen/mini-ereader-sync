import Foundation
import GRDB

enum ArticleStatus: String, Codable, CaseIterable {
    case new
    case converting
    case converted
    case synced
    case error
}

struct Article: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    /// Positive IDs come from Instapaper (bookmark_id). Negative IDs are
    /// generated locally for EPUBs the user drops into the cache directory.
    var id: Int64
    var url: String
    var title: String
    var author: String?
    var addedAt: Date
    var status: ArticleStatus
    var epubPath: String?
    var errorMessage: String?
    var syncedAt: Date?
    /// True if the last Instapaper poll's result set did NOT include this
    /// bookmark (archived, deleted, or out of the limit window). Always
    /// false for manual articles.
    var removedFromSource: Bool

    static let databaseTableName = "articles"

    enum Columns {
        static let id = Column("id")
        static let url = Column("url")
        static let title = Column("title")
        static let author = Column("author")
        static let addedAt = Column("added_at")
        static let status = Column("status")
        static let epubPath = Column("epub_path")
        static let errorMessage = Column("error_message")
        static let syncedAt = Column("synced_at")
        static let removedFromSource = Column("removed_from_source")
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, author, status
        case addedAt = "added_at"
        case epubPath = "epub_path"
        case errorMessage = "error_message"
        case syncedAt = "synced_at"
        case removedFromSource = "removed_from_source"
    }

    var hostname: String {
        URL(string: url)?.host ?? url
    }

    var isManual: Bool { id < 0 }
}
