import AudibleCore
import Foundation
import Observation

enum LibraryFilter: Hashable {
    case all, downloaded, notConverted, audibleOnly, reading, finished, pdfs
    case genre(String)

    var title: String {
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

    func matches(_ b: Book) -> Bool {
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

@Observable
final class LibraryModel {
    private(set) var library: OpenAudibleLibrary?
    private(set) var error: String?
    var filter: LibraryFilter = .all
    var search = ""
    var selection: Set<Book.ID> = []
    var isPickingFolder = false

    private static let bookmarkKey = "libraryBookmark"

    init() { restore() }

    var books: [Book] { library?.books ?? [] }

    var visibleBooks: [Book] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return books.filter { b in
            filter.matches(b) && (q.isEmpty
                || b.title.localizedStandardContains(q)
                || b.author.localizedStandardContains(q)
                || b.narratedBy.localizedStandardContains(q))
        }
    }

    var genres: [(String, Int)] {
        Dictionary(grouping: books.map(\.primaryGenre).filter { !$0.isEmpty }, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
    }

    var selectedBook: Book? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return books.first { $0.id == id }
    }

    func count(_ f: LibraryFilter) -> Int { books.count(where: f.matches) }

    var totalHours: Int { books.reduce(0) { $0 + $1.seconds } / 3600 }

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            library = try OpenAudibleLibrary(root: url)
            error = nil
            if let data = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            self.error = "\(url.lastPathComponent) is not an OpenAudible library: \(error.localizedDescription)"
        }
    }

    func reload() {
        if let root = library?.root { open(root) }
    }

    private func restore() {
        #if DEBUG
        // Lets agents and screenshots open a library without the folder picker (build with CODE_SIGN_ENTITLEMENTS= to drop the sandbox).
        let env = ProcessInfo.processInfo.environment
        if let path = env["EARMARK_LIBRARY"] {
            open(URL(fileURLWithPath: path))
            if let asin = env["EARMARK_SELECT"] { selection = [asin] }
            return
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            open(url)
        }
    }
}
