import Foundation

enum ReaderError: Error, LocalizedError {
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "Reader HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Talks to the CrossPoint firmware's local web server at 192.168.4.1.
///
/// Endpoints (reverse-engineered from crosspoint-reader and the send-to-x4
/// extension, verified against a live device):
///   POST /upload?path=/Folder   multipart `file` field → upload
///   POST /mkdir                 form `name`,`path`     → create folder
///   GET  /api/files?path=/      JSON directory listing
///   GET  /api/status            JSON device status (also a good reachability probe)
///
/// We put everything under `/MiniEreader/` so it's obvious on the reader
/// where these files came from, and so they don't mix with books the user
/// uploaded through other means.
///
/// A dedicated ephemeral URLSession is used because the reader's AP has no
/// internet route and the shared session's connectivity pre-check returns
/// -1009 otherwise.
enum ReaderClient {
    static let baseURL = URL(string: "http://192.168.4.1")!
    static let booksFolder = "Articles"
    static var booksPath: String { "/\(booksFolder)" }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Upload

    static func uploadEPUB(at fileURL: URL, filename: String) async throws {
        await ensureBooksDirectory()

        let fileData = try Data(contentsOf: fileURL)
        let boundary = "----MiniEreaderBoundary\(UUID().uuidString)"
        var components = URLComponents(url: baseURL.appendingPathComponent("upload"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: booksPath)]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/epub+zip\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse
        let responseText = String(data: data, encoding: .utf8) ?? ""
        NSLog("[reader] POST /upload?path=%@ → %d", booksPath, http.statusCode)

        guard http.statusCode == 200 else {
            throw ReaderError.httpError(http.statusCode, responseText)
        }
    }

    /// Create `/MiniEreader/` if it isn't there. mkdir is a no-op when the
    /// folder already exists; logged but errors are non-fatal (upload will
    /// fail on its own if the folder genuinely can't be created).
    static func ensureBooksDirectory() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("mkdir"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("name=\(booksFolder)&path=/".utf8)

        do {
            let (data, response) = try await session.data(for: req)
            let http = response as! HTTPURLResponse
            let text = String(data: data, encoding: .utf8) ?? ""
            NSLog("[reader] POST /mkdir name=%@ → %d %@",
                  booksFolder, http.statusCode, text.prefix(120) as CVarArg)
        } catch {
            NSLog("[reader] /mkdir failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Reachability

    static func ping() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
