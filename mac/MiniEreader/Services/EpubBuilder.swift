import Foundation
import ZIPFoundation

/// Builds a minimal EPUB 2 file from cleaned article HTML.
/// EPUB 2 is a ZIP with `mimetype` stored uncompressed as the first entry,
/// plus container.xml, content.opf, toc.ncx, and a single XHTML chapter.
enum EpubBuilder {
    struct Metadata {
        let id: Int64
        let title: String
        let author: String?
        let url: String
        let publishedAt: Date
    }

    /// Writes an EPUB to `destination` and returns it.
    static func build(cleanBodyHTML: String,
                      metadata: Metadata,
                      destination: URL) throws -> URL {
        // Remove any existing file so Archive(url: .create) starts fresh.
        try? FileManager.default.removeItem(at: destination)

        let uuid = "urn:mini-ereader:\(metadata.id)"
        let author = metadata.author?.isEmpty == false ? metadata.author! : hostname(from: metadata.url)
        let dateString = ISO8601DateFormatter().string(from: metadata.publishedAt)

        // Plain XHTML, no external DTD. The CrossPoint firmware parses chapter
        // HTML with expat (strict XML) — external DTDs and HTML-only entities
        // both cause it to abort with "indexing" hangs. dc:title in the OPF
        // provides the book title, so the chapter body doesn't need its own.
        let sanitizedBody = sanitizeHTMLEntities(cleanBodyHTML)
        let chapterXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>\(escapeXML(metadata.title))</title>
          <meta http-equiv="Content-Type" content="application/xhtml+xml; charset=utf-8" />
        </head>
        <body>
          \(sanitizedBody)
        </body>
        </html>
        """
        _ = author // reserved for future use

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>\(escapeXML(metadata.title))</dc:title>
            <dc:creator opf:role="aut">\(escapeXML(author))</dc:creator>
            <dc:identifier id="BookId">\(uuid)</dc:identifier>
            <dc:language>en</dc:language>
            <dc:date>\(dateString)</dc:date>
            <dc:source>\(escapeXML(metadata.url))</dc:source>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """

        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(uuid)"/>
            <meta name="dtb:depth" content="1"/>
          </head>
          <docTitle><text>\(escapeXML(metadata.title))</text></docTitle>
          <navMap>
            <navPoint id="navPoint-1" playOrder="1">
              <navLabel><text>\(escapeXML(metadata.title))</text></navLabel>
              <content src="chapter1.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """

        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)

        // mimetype MUST be first and stored uncompressed per EPUB spec.
        try addFile(archive: archive, path: "mimetype",
                    string: "application/epub+zip", method: .none)
        try addFile(archive: archive, path: "META-INF/container.xml", string: containerXML)
        try addFile(archive: archive, path: "OEBPS/content.opf", string: contentOPF)
        try addFile(archive: archive, path: "OEBPS/toc.ncx", string: tocNCX)
        try addFile(archive: archive, path: "OEBPS/chapter1.xhtml", string: chapterXHTML)

        return destination
    }

    private static func addFile(archive: Archive,
                                path: String,
                                string: String,
                                method: CompressionMethod = .deflate) throws {
        let data = Data(string.utf8)
        try archive.addEntry(with: path,
                             type: .file,
                             uncompressedSize: Int64(data.count),
                             compressionMethod: method) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    /// Replace HTML-only named entities with their Unicode characters.
    /// Expat only knows the five built-in XML entities (`lt`, `gt`, `amp`,
    /// `quot`, `apos`). Anything else (`&nbsp;`, `&mdash;`, `&hellip;`, …)
    /// aborts parsing mid-chapter — which is what "indexing" hangs look like.
    private static func sanitizeHTMLEntities(_ s: String) -> String {
        let map: [String: String] = [
            "&nbsp;": "\u{00A0}", "&ndash;": "\u{2013}", "&mdash;": "\u{2014}",
            "&hellip;": "\u{2026}", "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&sbquo;": "\u{201A}",
            "&bdquo;": "\u{201E}", "&trade;": "\u{2122}", "&copy;": "\u{00A9}",
            "&reg;": "\u{00AE}", "&deg;": "\u{00B0}", "&plusmn;": "\u{00B1}",
            "&times;": "\u{00D7}", "&divide;": "\u{00F7}", "&laquo;": "\u{00AB}",
            "&raquo;": "\u{00BB}", "&middot;": "\u{00B7}", "&bull;": "\u{2022}",
            "&iexcl;": "\u{00A1}", "&iquest;": "\u{00BF}", "&para;": "\u{00B6}",
            "&sect;": "\u{00A7}", "&cent;": "\u{00A2}", "&pound;": "\u{00A3}",
            "&euro;": "\u{20AC}", "&yen;": "\u{00A5}"
        ]
        var out = s
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func hostname(from url: String) -> String {
        URL(string: url)?.host ?? "Unknown"
    }
}
