import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ContentDownload {
    public typealias Transfer = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    public static func sourceName(asin: String, credentials: ContentCredentials) throws -> String {
        guard AudibleContent.validASIN(asin) else { throw AudibleError("Invalid Audible book identifier.") }
        let fingerprint = SHA256.hash(data: Data(credentials.arguments.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(asin)-\(fingerprint).\(credentials.fileExtension)"
    }

    public static func fetch(url: URL, destination: URL, transfer: Transfer,
                             progress: @Sendable (Double?) -> Void = { _ in }) async throws -> URL {
        guard AudibleContent.validDownloadURL(url), destination.isFileURL else {
            throw AudibleError("Invalid audiobook download location.")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { return destination }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        let initial = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var offset = initial
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("bytes=\(offset)-\(offset + 4 * 1024 * 1024 - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.httpShouldHandleCookies = false
            let (temporary, response) = try await transfer(request)
            defer { try? manager.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  AudibleContent.validDownloadURL(finalURL) else {
                throw AudibleError("Invalid audiobook download response.")
            }
            if http.statusCode == 416, offset > 0, http.value(forHTTPHeaderField: "Content-Range") == "bytes */\(offset)" { break }
            guard [200, 206].contains(http.statusCode) else {
                throw AudibleError("The audiobook download expired or failed. Retry to request a fresh license.")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw AudibleError("Audible returned an empty download.") }
            if http.statusCode == 200 {
                if manager.fileExists(atPath: partial.path) { try manager.removeItem(at: partial) }
                try manager.moveItem(at: temporary, to: partial)
                break
            }
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = parseRange(range), parsed.start == offset,
                  parsed.end - parsed.start + 1 == size else {
                throw AudibleError("Audible returned an inconsistent download range. Retry the download.")
            }
            if !manager.fileExists(atPath: partial.path) {
                guard manager.createFile(atPath: partial.path, contents: nil) else { throw AudibleError("Could not create the download file.") }
            }
            let output = try FileHandle(forWritingTo: partial)
            let input = try FileHandle(forReadingFrom: temporary)
            defer { try? output.close(); try? input.close() }
            do {
                try output.seekToEnd()
                while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: bytes)
                }
                try output.synchronize()
            } catch {
                try? output.truncate(atOffset: UInt64(offset))
                throw error
            }
            offset += size
            progress(Double(offset) / Double(parsed.total))
            if offset == parsed.total { break }
        }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: partial)
        defer { try? input.close() }
        let header = try input.read(upToCount: 12) ?? Data()
        guard header.count == 12, String(decoding: header[4..<8], as: UTF8.self) == "ftyp" else {
            try? manager.removeItem(at: partial)
            throw AudibleError("The download is not an audiobook. Retry or sign in again.")
        }
        try manager.moveItem(at: partial, to: destination)
        progress(1)
        return destination
    }

    static func parseRange(_ value: String) -> (start: Int, end: Int, total: Int)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int(pieces[1]), total > 0 else { return nil }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
}
