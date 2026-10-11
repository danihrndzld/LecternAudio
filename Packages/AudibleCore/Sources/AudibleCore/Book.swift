import Foundation

public struct Chapter: Codable, Hashable, Sendable {
    public var title: String
    public var startMs: Int
    public var lengthMs: Int

    public var start: TimeInterval { Double(startMs) / 1000 }

    public init(title: String, startMs: Int, lengthMs: Int) {
        self.title = title
        self.startMs = startMs
        self.lengthMs = lengthMs
    }

    enum CodingKeys: String, CodingKey {
        case title
        case startMs = "start_offset_ms"
        case lengthMs = "length_ms"
    }
}

public enum FileType: String, Codable, Sendable {
    case art = "ART", m4b = "M4B", mp3 = "MP3", aax = "AAX", aaxc = "AAXC", pdf = "PDF"
}

public struct BookFile: Codable, Hashable, Sendable {
    public var path: String
    public var type: FileType?

    public init(path: String, type: FileType) {
        self.path = path
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        // Unknown types (future OpenAudible versions) decode as nil rather than failing the whole library.
        type = (try? c.decode(String.self, forKey: .type)).flatMap { FileType(rawValue: $0.uppercased()) }
    }

    enum CodingKeys: String, CodingKey { case path, type }
}

public enum ReadStatus: String, Sendable, CaseIterable {
    case unread = "Unread", reading = "Reading", finished = "Finished", wantToRead = "Want_To_Read"
}

/// One audiobook. Field names follow OpenAudible's `books.json`; most values there are strings.
public struct Book: Identifiable, Hashable, Sendable {
    public var id: String { asin.isEmpty ? key : asin }
    public var asin: String
    public var key: String
    public var title: String
    public var author: String
    public var narratedBy: String
    public var publisher: String
    public var genre: String
    public var summary: String
    public var seconds: Int
    public var rating: Double?
    public var ratingCount: Int?
    public var releaseDate: Date?
    public var purchaseDate: Date?
    public var region: String
    public var readStatus: ReadStatus?
    public var imageURL: URL?
    public var chapters: [Chapter]
    public var files: [BookFile]

    public var hasAudio: Bool { files.contains { [.m4b, .mp3].contains($0.type) } }
    public var hasEncrypted: Bool { files.contains { [.aax, .aaxc].contains($0.type) } }
    public var hasPDF: Bool { files.contains { $0.type == .pdf } }
    /// Top-level genre ("Business & Careers:Career Success" → "Business & Careers").
    public var primaryGenre: String { genre.split(separator: ":").first.map(String.init) ?? "" }
}

extension Book: Codable {
    enum CodingKeys: String, CodingKey {
        case asin, key, title, author, publisher, genre, summary, description, seconds, region, chapters, files
        case narratedBy = "narrated_by", rating = "rating_average", ratingCount = "rating_count"
        case releaseDate = "release_date", purchaseDate = "purchase_date", readStatus = "read_status", imageURL = "image_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        asin = s(.asin)
        key = s(.key)
        title = HTMLText.markdown(s(.title))
        author = HTMLText.markdown(s(.author))
        narratedBy = s(.narratedBy)
        publisher = s(.publisher)
        genre = s(.genre)
        summary = s(.summary).isEmpty ? s(.description) : s(.summary)
        seconds = (try? c.decode(Int.self, forKey: .seconds)) ?? Int(s(.seconds)) ?? 0
        rating = Double(s(.rating))
        ratingCount = Int(s(.ratingCount))
        releaseDate = Book.day.date(from: s(.releaseDate))
        purchaseDate = Book.day.date(from: s(.purchaseDate))
        region = s(.region)
        readStatus = ReadStatus(rawValue: s(.readStatus))
        imageURL = URL(string: s(.imageURL))
        chapters = (try? c.decode([Chapter].self, forKey: .chapters)) ?? []
        files = (try? c.decode([BookFile].self, forKey: .files)) ?? []
    }

    /// Writes the same books.json shape the decoder reads (Earmark's library.json).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(asin, forKey: .asin)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encode(narratedBy, forKey: .narratedBy)
        try c.encode(publisher, forKey: .publisher)
        try c.encode(genre, forKey: .genre)
        try c.encode(summary, forKey: .summary)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(region, forKey: .region)
        try c.encodeIfPresent(rating.map { String($0) }, forKey: .rating)
        try c.encodeIfPresent(ratingCount.map { String($0) }, forKey: .ratingCount)
        try c.encodeIfPresent(releaseDate.map(Book.day.string(from:)), forKey: .releaseDate)
        try c.encodeIfPresent(purchaseDate.map(Book.day.string(from:)), forKey: .purchaseDate)
        try c.encodeIfPresent(readStatus?.rawValue, forKey: .readStatus)
        try c.encodeIfPresent(imageURL?.absoluteString, forKey: .imageURL)
        try c.encode(chapters, forKey: .chapters)
        try c.encode(files, forKey: .files)
    }

    nonisolated(unsafe) static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current  // calendar dates: midnight local so they display as written
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension Book {
    /// A book made from a local audio file (File ▸ Import), not from Audible or books.json.
    public init(key: String, title: String, author: String, narratedBy: String = "", genre: String = "", seconds: Int,
                imageURL: URL? = nil, chapters: [Chapter] = [], files: [BookFile]) {
        self.init(asin: "", key: key, title: title, author: author, narratedBy: narratedBy, publisher: "", genre: genre,
                  summary: "", seconds: seconds, rating: nil, ratingCount: nil, releaseDate: nil, purchaseDate: nil,
                  region: "", readStatus: nil, imageURL: imageURL, chapters: chapters, files: files)
    }
}
