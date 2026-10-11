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
    let downloads = DownloadModel()
    private var accountRoot: URL?
    private var downloadedLibrary: OpenAudibleLibrary?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var accountIdentity: String?
    private weak var session: AudibleSession?
    /// Progress (0...1) of running MP3 exports.
    private(set) var exports: [Book.ID: Double] = [:]
    @ObservationIgnored private var exportTasks: [Book.ID: Task<Void, Never>] = [:]

    private static let bookmarkKey = "libraryBookmark"

    init() {
        Prefs.register()
        restore()
    }

    private var store: URL? { accountRoot?.appendingPathComponent("catalog.json") }

    private func merge() {
        let local = AudibleLibrary.merge(audible: library?.books ?? [], local: downloadedLibrary?.books ?? [])
        books = AudibleLibrary.merge(audible: audibleBooks, local: local)
    }

    /// Signed out, the app shows only the OpenAudible folder, as before sign-in existed.
    func useAudible(_ session: AudibleSession) {
        self.session = session
        let identity = session.account?.storageID
        guard identity != accountIdentity || accountRoot == nil else { return }
        syncTask?.cancel()
        syncGeneration = UUID()
        syncTask = nil
        isSyncing = false
        accountIdentity = identity
        accountRoot = identity.map { URL.applicationSupportDirectory.appendingPathComponent("Earmark/accounts/\($0)") }
        downloadedLibrary = accountRoot.flatMap { try? OpenAudibleLibrary(root: $0) }
        audibleBooks = store.map { AudibleLibrary.load(from: $0) } ?? []
        lastSync = nil
        downloads.configure(session: session, library: self, root: accountRoot)
        if identity == nil { conversion.cancel() }
        merge()
    }

    func sync(_ account: AudibleAccount) {
        guard !isSyncing, account.storageID == accountIdentity, let store else { return }
        isSyncing = true
        syncedCount = 0
        let generation = UUID()
        syncGeneration = generation
        syncTask = Task {
            do {
                let fetched = try await AudibleLibrary.fetch(account: account, send: { try await AudibleHTTP.data(for: $0) }) { n in
                    Task { @MainActor in if self.syncGeneration == generation { self.syncedCount = n } }
                }
                try Task.checkCancellation()
                guard accountIdentity == account.storageID, syncGeneration == generation else { return }
                try AudibleLibrary.save(fetched, to: store)
                audibleBooks = fetched
                lastSync = .now
                if downloads.automaticallyDownload { downloads.enqueue(books) }
            } catch is CancellationError {
            } catch {
                if syncGeneration == generation { syncError = error.localizedDescription }
            }
            if syncGeneration == generation { isSyncing = false; syncTask = nil }
        }
    }

    func canDownload(_ book: Book) -> Bool {
        accountIdentity != nil && audibleBooks.contains { $0.asin == book.asin } && !book.hasAudio
    }

    func convert(_ book: Book) {
        if let session, session.account != nil, audibleBooks.contains(where: { $0.asin == book.asin }) {
            conversion.prepare(book, session: session, library: self)
        } else { conversion.prepare(book) }
    }

    func audioURL(for book: Book) -> URL? {
        if let owned = downloadedLibrary?.books.first(where: { $0.id == book.id }),
           let url = downloadedLibrary?.audioURL(for: owned) { return url }
        return library?.audioURL(for: book)
    }

    func recordDownload(_ book: Book, output: URL, root: URL) throws {
        guard root == accountRoot else { throw CancellationError() }
        guard AudibleContent.validASIN(book.asin), output.standardizedFileURL == root.appendingPathComponent("books/\(book.asin).m4b").standardizedFileURL,
              FileManager.default.isReadableFile(atPath: output.path) else { throw ConversionError.invalidOutput }
        let index = root.appendingPathComponent("books.json")
        var saved = FileManager.default.fileExists(atPath: index.path)
            ? try JSONDecoder().decode([Book].self, from: Data(contentsOf: index)) : []
        var local = book
        local.files = [BookFile(path: output.lastPathComponent, type: .m4b)]
        for suffix in ["jpg", "png"] {
            let art = root.appendingPathComponent("art/\(book.asin).\(suffix)")
            if FileManager.default.fileExists(atPath: art.path) { local.imageURL = art; break }
        }
        saved.removeAll { $0.id == book.id }
        saved.append(local)
        try AudibleLibrary.save(saved, to: root.appendingPathComponent("books.json"))
        downloadedLibrary = try OpenAudibleLibrary(root: root)
        merge()
        // Output format MP3: keep the M4B (the player needs it) and add an MP3 copy beside it.
        let mp3 = output.deletingPathExtension().appendingPathExtension("mp3")
        if UserDefaults.standard.string(forKey: Prefs.outputFormat) == "mp3", !FileManager.default.fileExists(atPath: mp3.path) {
            export(local, source: output, to: mp3.appendingPathExtension("part"), byChapter: false)
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
        if let owned = downloadedLibrary?.books.first(where: { $0.id == book.id }),
           let file = owned.files.first(where: { $0.type == .m4b }) { return downloadedLibrary?.url(for: file) }
        return book.files.first { $0.type == .m4b }.flatMap { library?.url(for: $0) }
    }

    /// Asks where to save, then converts the book's M4B to MP3 (bitrate and VBR from Settings) in the background.
    func exportMP3(_ book: Book, byChapter: Bool) {
        guard let source = m4bURL(for: book), exportTasks[book.id] == nil else { return }
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
        export(book, source: source, to: destination, byChapter: byChapter)
    }

    /// A destination ending in `.part` is renamed without it once the export succeeds.
    private func export(_ book: Book, source: URL, to destination: URL, byChapter: Bool) {
        guard exportTasks[book.id] == nil else { return }
        var tag = ID3Tag()
        tag.title = book.title
        tag.album = book.title
        tag.artist = book.author
        tag.composer = book.narratedBy
        tag.genre = book.primaryGenre
        tag.year = book.releaseDate.map { String(Calendar.current.component(.year, from: $0)) } ?? ""
        tag.comment = HTMLText.markdown(book.summary)
        tag.cover = (library?.artURL(for: book) ?? book.imageURL).flatMap { $0.isFileURL ? try? Data(contentsOf: $0) : nil }
        var options = Prefs.mp3Options
        options.splitChapters = byChapter

        let id = book.id
        exports[id] = 0
        exportTasks[id] = Task {
            do {
                try await MP3Export.run(source: source, destination: destination, tag: tag, options: options) { p in
                    Task { @MainActor in if self.exports[id] != nil { self.exports[id] = p } }
                }
                if destination.pathExtension == "part" {
                    try FileManager.default.moveItem(at: destination, to: destination.deletingPathExtension())
                }
                Prefs.playCompletionSound()
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
