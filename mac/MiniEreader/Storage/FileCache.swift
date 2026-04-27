import Foundation

/// On-disk cache for generated EPUB files.
enum FileCache {
    static var epubsDir: URL {
        let dir = Library.supportDirectory.appendingPathComponent("epubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func epubURL(for articleID: Int64) -> URL {
        epubsDir.appendingPathComponent("\(articleID).epub")
    }

    static func exists(for articleID: Int64) -> Bool {
        FileManager.default.fileExists(atPath: epubURL(for: articleID).path)
    }
}
