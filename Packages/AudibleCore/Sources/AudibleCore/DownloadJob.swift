import Foundation

public struct DownloadJob: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, licensing, downloading, converting, complete, failed, cancelled }
    public var book: Book
    public var state: State
    public var message: String?
    /// The account this job is licensed and written for, as `AudibleAccount.storageID`.
    ///
    /// Optional, so a `queue.json` written before multiple accounts still decodes: the synthesized
    /// decoder uses `decodeIfPresent`, and those jobs belong to the only account that existed. Nil is
    /// omitted on encode, so a single-account queue file keeps its format (issue #47).
    public var accountID: String?
    public var id: String { book.id }

    public init(book: Book, state: State = .queued, message: String? = nil, accountID: String? = nil) {
        self.book = book
        self.state = state
        self.message = message
        self.accountID = accountID
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
