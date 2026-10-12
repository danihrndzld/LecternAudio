import Foundation

/// A sidebar entry: which books the library list shows.
public enum LibraryFilter: Hashable, Sendable {
    case all, downloaded, notConverted, audibleOnly, reading, finished, pdfs
    case genre(String)

    public static let fixed: [LibraryFilter] = [.all, .downloaded, .notConverted, .audibleOnly, .reading, .finished, .pdfs]

    public var title: String {
        switch self {
        case .all: "All Books"
        case .downloaded: "Downloaded"
        case .notConverted: "Not Converted"
        case .audibleOnly: "In Audible Only"
        case .reading: "Listening"
        case .finished: "Finished"
        case .pdfs: "With PDF"
        case .genre(let g): g
        }
    }

    public func matches(_ b: Book) -> Bool {
        switch self {
        case .all: true
        case .downloaded: b.hasAudio
        case .notConverted: b.hasEncrypted && !b.hasAudio
        case .audibleOnly: !b.hasEncrypted && !b.hasAudio
        case .reading: b.readStatus == .reading
        case .finished: b.readStatus == .finished
        case .pdfs: b.hasPDF
        case .genre(let g): b.primaryGenre == g
        }
    }
}

/// The library list's derived data, recomputed only when one of its inputs changes. Views read it on every render
/// (table, window subtitle, sidebar badges, menus), so filtering and sorting there re-ran several times per update.
public struct LibraryIndex: Sendable {
    public var books: [Book] = [] { didSet { recount(); refresh() } }
    public var filter: LibraryFilter = .all { didSet { if filter != oldValue { refresh() } } }
    public var search = "" { didSet { if search != oldValue { refresh() } } }
    public var sortOrder = BookComparator.defaultOrder { didSet { if sortOrder != oldValue { refresh() } } }
    /// `books` matching `filter` and `search`, in `sortOrder`.
    public private(set) var visible: [Book] = []
    /// Top-level genres A–Z with their book counts.
    public private(set) var genres: [(name: String, count: Int)] = []
    private var counts: [LibraryFilter: Int] = [:]

    public init() {}

    public func count(_ filter: LibraryFilter) -> Int { counts[filter] ?? 0 }

    private mutating func recount() {
        var counts = Dictionary(uniqueKeysWithValues: LibraryFilter.fixed.map { ($0, 0) })
        for b in books {
            for f in LibraryFilter.fixed where f.matches(b) { counts[f, default: 0] += 1 }
            if !b.primaryGenre.isEmpty { counts[.genre(b.primaryGenre), default: 0] += 1 }
        }
        self.counts = counts
        genres = counts.compactMap { f, n in if case .genre(let g) = f { (g, n) } else { nil } }.sorted { $0.name < $1.name }
    }

    private mutating func refresh() {
        let q = search.trimmingCharacters(in: .whitespaces)
        visible = books.filter { b in
            filter.matches(b) && (q.isEmpty
                || b.title.localizedStandardContains(q)
                || b.author.localizedStandardContains(q)
                || b.narratedBy.localizedStandardContains(q))
        }.sorted(using: sortOrder)
    }
}
