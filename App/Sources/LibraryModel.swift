import AppKit
import AudibleCore
import Observation
import UniformTypeIdentifiers

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
    private(set) var library: OpenAudibleLibrary? { didSet { merge() } }
    /// The list from Audible, saved at ~/Library/Application Support/Earmark/library.json. Empty when signed out.
    private var audibleBooks: [Book] = [] { didSet { merge() } }
    /// Audible's list with local files from the OpenAudible folder, or just the folder when not synced.
    private(set) var books: [Book] = []
    private(set) var isSyncing = false
    private(set) var syncedCount = 0
    var syncError: String?
    private(set) var lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date {
        didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") }
    }
    private(set) var error: String?
    var filter: LibraryFilter = .all
    var search = ""
    var selection: Set<Book.ID> = []
    var isPickingFolder = false
    let conversion = ConversionModel()
    /// Progress (0...1) of running MP3 exports.
    private(set) var exports: [Book.ID: Double] = [:]
    @ObservationIgnored private var exportTasks: [Book.ID: Task<Void, Never>] = [:]

    private static let bookmarkKey = "libraryBookmark"

    init() { restore() }

    private static let store = URL.applicationSupportDirectory.appending(path: "Earmark/library.json")

    private func merge() { books = AudibleLibrary.merge(audible: audibleBooks, local: library?.books ?? []) }

    /// Signed out, the app shows only the OpenAudible folder, as before sign-in existed.
    func useAudible(_ signedIn: Bool) {
        if signedIn {
            if audibleBooks.isEmpty { audibleBooks = AudibleLibrary.load(from: Self.store) }
        } else {
            audibleBooks = []
            lastSync = nil
            try? FileManager.default.removeItem(at: Self.store)
        }
    }

    func sync(_ account: AudibleAccount) {
        guard !isSyncing else { return }
        isSyncing = true
        syncedCount = 0
        Task {
            do {
                let fetched = try await AudibleLibrary.fetch(account: account, send: { try await URLSession.shared.data(for: $0) }) { n in
                    Task { @MainActor in self.syncedCount = n }
                }
                try AudibleLibrary.save(fetched, to: Self.store)
                audibleBooks = fetched
                lastSync = .now
            } catch is CancellationError {
            } catch {
                syncError = error.localizedDescription
            }
            isSyncing = false
        }
    }

    /// Local cover when the folder has one, else Audible's CDN image.
    func artURL(for book: Book) -> URL? { library?.artURL(for: book) ?? book.imageURL }
    func thumbURL(for book: Book) -> URL? { library?.thumbURL(for: book) ?? book.imageURL }

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

    func m4bURL(for book: Book) -> URL? {
        book.files.first { $0.type == .m4b }.flatMap { library?.url(for: $0) }
    }

    /// Asks where to save, then converts the book's M4B to MP3 (64 kbps CBR mono) in the background.
    func exportMP3(_ book: Book, byChapter: Bool) {
        guard let source = m4bURL(for: book), let library, exportTasks[book.id] == nil else { return }
        let name = book.title.replacing(/[\/:]/, with: "-")
        let destination: URL
        if byChapter {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "A folder named “\(name)” with one MP3 per chapter is created here."
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            destination = dir.appendingPathComponent(name)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mp3]
            panel.nameFieldStringValue = name + ".mp3"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        var tag = ID3Tag()
        tag.title = book.title
        tag.album = book.title
        tag.artist = book.author
        tag.composer = book.narratedBy
        tag.genre = book.primaryGenre
        tag.year = book.releaseDate.map { String(Calendar.current.component(.year, from: $0)) } ?? ""
        tag.comment = HTMLText.markdown(book.summary)
        tag.cover = library.artURL(for: book).flatMap { try? Data(contentsOf: $0) }
        var options = MP3Export.Options()
        options.splitChapters = byChapter

        let id = book.id
        exports[id] = 0
        exportTasks[id] = Task {
            do {
                try await MP3Export.run(source: source, destination: destination, tag: tag, options: options) { p in
                    Task { @MainActor in if self.exports[id] != nil { self.exports[id] = p } }
                }
            } catch is CancellationError {
            } catch {
                NSAlert(error: error).runModal()
            }
            exports[id] = nil
            exportTasks[id] = nil
        }
    }

    func cancelExport(_ id: Book.ID) { exportTasks[id]?.cancel() }

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
