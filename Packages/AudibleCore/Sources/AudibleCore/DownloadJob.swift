import Foundation

public struct DownloadJob: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, licensing, downloading, converting, complete, failed, cancelled }
    public var book: Book
    public var state: State
    public var message: String?
    public var id: String { book.id }

    public init(book: Book, state: State = .queued, message: String? = nil) {
        self.book = book
        self.state = state
        self.message = message
    }

    public static func restore(from data: Data) throws -> [Self] {
        var seen = Set<String>()
        return try JSONDecoder().decode([Self].self, from: data).compactMap { job in
            guard AudibleContent.validASIN(job.book.asin), seen.insert(job.id).inserted else { return nil }
            var restored = job
            if [.licensing, .downloading, .converting].contains(restored.state) { restored.state = .queued }
            return restored
        }
    }
}
