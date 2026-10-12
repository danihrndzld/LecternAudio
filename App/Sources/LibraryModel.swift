import AppKit
import AudibleCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class LibraryModel {
    private(set) var library: OpenAudibleLibrary? { didSet { merge() } }
    /// The list from Audible, saved at ~/Library/Application Support/Lectern Audio/library.json. Empty when signed out.
    private var audibleBooks: [Book] = [] { didSet { merge() } }
    /// Audible's list with local files from the OpenAudible folder, or just the folder when not synced.
    private(set) var books: [Book] = [] { didSet { index.books = books } }
    /// Filtered, sorted and counted once per change of books, filter, search or sort, not on every render.
    /// Separate from `books`, `filter`, `search` and `sortOrder` so views that read only those (the search field
    /// binding, the inspector) don't update whenever the derived list changes.
    private var index = LibraryIndex()
    private(set) var isSyncing = false
    private(set) var syncedCount = 0
    var syncError: String?
    /// Saved per account ("lastSync.<storageID>") so launch and account switches never wipe another account's time.
    private(set) var lastSync: Date? {
        didSet { if let accountIdentity { UserDefaults.standard.set(lastSync, forKey: "lastSync.\(accountIdentity)") } }
    }
    private(set) var error: String?
    var filter: LibraryFilter = .all { didSet { index.filter = filter } }
    var search = "" { didSet { index.search = search } }
    var selection: Set<Book.ID> = []
    var isPickingFolder = false
    var sortOrder = BookComparator.defaultOrder { didSet { index.sortOrder = sortOrder } }
    var columnCustomization: TableColumnCustomization<Book> = (UserDefaults.standard.data(forKey: "tableColumns"))
        .flatMap { try? JSONDecoder().decode(TableColumnCustomization<Book>.self, from: $0) } ?? .init() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(columnCustomization), forKey: "tableColumns") }
    }
    var showInspector = true
    var showChapters = false
    /// Bumped by View ▸ Focus Book List; the table takes focus when it changes.
    var focusListRequest = 0
    /// Bumped by Edit ▸ Find (⌘F); `ContentView` moves focus to the search field (issue #6).
    var focusSearchRequest = 0
    /// Books added with File ▸ Import, kept across launches with security-scoped bookmarks.
    var imported: [Book] = [] { didSet { merge() } }
    @ObservationIgnored var importedURLs: [Book.ID: URL] = [:]
    /// Running menu jobs (join, poster, import URL); File ▸ Cancel All Jobs cancels them.
    private(set) var jobCount = 0
    @ObservationIgnored var jobs: [UUID: Task<Void, Never>] = [:] { didSet { jobCount = jobs.count } }
    let conversion = ConversionModel()
    let downloads = DownloadModel()
    private var accountRoot: URL?
    private var downloadedLibrary: OpenAudibleLibrary?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var accountIdentity: String?
    private weak var session: AudibleSession?
    /// The library folder whose security scope is open; stopped when another folder replaces it.
    @ObservationIgnored private var scopedRoot: URL?
    /// Imported files whose security scope is open for this app session.
    @ObservationIgnored var scopedImports: Set<URL> = []
    /// The MP3 and Ogg Vorbis export queue, two encodes at a time.
    let exports = ExportModel()

    private static let bookmarkKey = "libraryBookmark"

    init() {
        Prefs.register()
        // The limiter is created with the default, so apply the stored setting before any job runs.
        Prefs.applyConversionLimit()
        exports.run = { [weak self] job, progress in
            guard let self else { throw CancellationError() }
            try await runExport(job, progress: progress)
        }
        restore()
        restoreImports()
    }

    private var store: URL? { accountRoot?.appendingPathComponent("catalog.json") }

    private func merge() {
        let local = AudibleLibrary.merge(audible: library?.books ?? [], local: downloadedLibrary?.books ?? [])
        books = AudibleLibrary.merge(audible: audibleBooks, local: local) + imported
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
        accountRoot = identity.map { URL.applicationSupportDirectory.appendingPathComponent("Lectern Audio/accounts/\($0)") }
        downloadedLibrary = accountRoot.flatMap { try? OpenAudibleLibrary(root: $0) }
        audibleBooks = store.map { AudibleLibrary.load(from: $0) } ?? []
        // LECTERN_SYNCED_LIBRARY=<library.json> loads a synced Audible list without signing in (perf runs on real data).
        if identity == nil, let path = Harness.env["LECTERN_SYNCED_LIBRARY"] {
            audibleBooks = AudibleLibrary.load(from: URL(fileURLWithPath: path))
        }
        lastSync = identity.flatMap { UserDefaults.standard.object(forKey: "lastSync.\($0)") as? Date }
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
                AppLog.shared.info("Synced \(fetched.count) books from Audible")
                if downloads.automaticallyDownload { downloads.enqueue(books, userInitiated: false) }
            } catch let error where error is CancellationError || Task.isCancelled {
            } catch {
                if syncGeneration == generation { syncError = error.localizedDescription; AppLog.shared.error("Sync failed: \(error.localizedDescription)") }
            }
            if syncGeneration == generation { isSyncing = false; syncTask = nil }
        }
    }

    var isSignedIn: Bool { accountIdentity != nil }

    func canDownload(_ book: Book) -> Bool {
        accountIdentity != nil && audibleBooks.contains { $0.asin == book.asin } && !book.hasAudio
    }

    func convert(_ book: Book) {
        if let session, session.account != nil, audibleBooks.contains(where: { $0.asin == book.asin }) {
            conversion.prepare(book, session: session, library: self)
        } else { conversion.prepare(book) }
    }

    func audioURL(for book: Book) -> URL? {
        if let url = importedURLs[book.id] { return url }
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
        // Output format MP3 or Ogg: keep the M4B (the player needs it) and add a copy beside it.
        if let ext = UserDefaults.standard.string(forKey: Prefs.outputFormat), ["mp3", "ogg"].contains(ext) {
            let copy = output.deletingPathExtension().appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: copy.path) { export(local, ext: ext, source: output, to: copy, byChapter: false) }
        }
    }

    /// Local cover when the folder has one, else Audible's CDN image.
    func artURL(for book: Book) -> URL? { library?.artURL(for: book) ?? book.imageURL }

    var visibleBooks: [Book] { index.visible }
    var genres: [(name: String, count: Int)] { index.genres }

    var selectedBook: Book? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return books.first { $0.id == id }
    }

    func count(_ f: LibraryFilter) -> Int { index.count(f) }

    var totalHours: Int { books.reduce(0) { $0 + $1.seconds } / 3600 }

    func open(_ url: URL) {
        let isOpen = scopedRoot?.standardizedFileURL == url.standardizedFileURL
        let scoped = !isOpen && url.startAccessingSecurityScopedResource()
        do {
            library = try OpenAudibleLibrary(root: url)
            error = nil
            if !isOpen {
                scopedRoot?.stopAccessingSecurityScopedResource()
                scopedRoot = scoped ? url : nil
            }
            if let data = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
                recentLibraries = [data] + recentLibraries.filter { Self.resolve($0)?.standardizedFileURL != url.standardizedFileURL }.prefix(4)
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            self.error = "\(url.lastPathComponent) is not an OpenAudible library: \(error.localizedDescription)"
        }
    }

    func reload() {
        if let root = library?.root { open(root) }
    }

    /// Controls ▸ Refresh Files: rescans the OpenAudible folder, the account's downloads and imported files.
    func refreshFiles() {
        reload()
        if let accountRoot { downloadedLibrary = try? OpenAudibleLibrary(root: accountRoot) }
        imported.removeAll { b in
            guard let url = importedURLs[b.id], FileManager.default.fileExists(atPath: url.path) else {
                if let url = importedURLs.removeValue(forKey: b.id), scopedImports.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
                return true
            }
            return false
        }
        saveImports()
        merge()
        AppLog.shared.info("Refreshed files: \(books.count) books")
    }

    /// Bookmarks of the last five library folders (File ▸ Manage Libraries).
    var recentLibraries: [Data] = UserDefaults.standard.array(forKey: "recentLibraries") as? [Data] ?? [] {
        didSet { UserDefaults.standard.set(recentLibraries, forKey: "recentLibraries") }
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
    }

    var isRunningJobs: Bool {
        isSyncing || conversion.isRunning || downloads.pendingCount > 0 || exports.isBusy || jobCount > 0
    }

    /// Controls ▸ Cancel All Jobs, through each job's own cancel API.
    func cancelAllJobs() {
        syncTask?.cancel()
        conversion.cancel()
        for job in downloads.jobs where [.queued, .licensing, .downloading, .converting].contains(job.state) { downloads.cancel(job.id) }
        exports.cancelAll()
        jobs.values.forEach { $0.cancel() }
        AppLog.shared.info("Cancelled all jobs")
    }

    func m4bURL(for book: Book) -> URL? {
        if let url = importedURLs[book.id] { return book.files.first?.type == .m4b ? url : nil }
        if let owned = downloadedLibrary?.books.first(where: { $0.id == book.id }),
           let file = owned.files.first(where: { $0.type == .m4b }) { return downloadedLibrary?.url(for: file) }
        return book.files.first { $0.type == .m4b }.flatMap { library?.url(for: $0) }
    }

    /// Asks where to save, then converts the book's M4B to MP3 or Ogg Vorbis (`ext` "mp3" or "ogg", options from Settings) in the background.
    func exportAudio(_ book: Book, ext: String, byChapter: Bool) {
        guard let source = m4bURL(for: book), !exports.isExporting(book.id) else { return }
        let name = Book.fileName(book.title, fallback: book.asin.isEmpty ? "Book" : book.asin)
        let destination: URL
        if byChapter {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "A folder named “\(name)” with one \(ext == "ogg" ? "Ogg Vorbis file" : "MP3") per chapter is created here."
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            destination = dir.appendingPathComponent(name)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .audio]
            panel.nameFieldStringValue = name + "." + ext
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        export(book, ext: ext, source: source, to: destination, byChapter: byChapter)
    }

    /// Queues one export. The exporters write `<file>.part` and rename it when done.
    private func export(_ book: Book, ext: String, source: URL, to destination: URL, byChapter: Bool) {
        guard let format = ExportJob.Format(rawValue: ext) else { return }
        exports.enqueue(ExportJob(bookID: book.id, title: book.title, format: format, byChapter: byChapter,
                                  source: source, destination: destination))
    }

    /// Runs one queued export. Called by `ExportModel` when a slot frees up, so the tag and the format
    /// settings are read when the encode actually starts and a retry picks up any change since.
    private func runExport(_ job: ExportJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        let tag = exportTag(for: job)
        var mp3 = Prefs.mp3Options, ogg = Prefs.oggOptions
        mp3.splitChapters = job.byChapter
        ogg.splitChapters = job.byChapter
        switch job.format {
        case .ogg: try await OggExport.run(source: job.source, destination: job.destination, tag: tag, options: ogg, progress: progress)
        case .mp3: try await MP3Export.run(source: job.source, destination: job.destination, tag: tag, options: mp3, progress: progress)
        }
    }

    private func exportTag(for job: ExportJob) -> ID3Tag {
        var tag = ID3Tag()
        // A book dropped from the library between queueing and encoding still exports, with its title.
        guard let book = books.first(where: { $0.id == job.bookID }) else {
            tag.title = job.title
            tag.album = job.title
            return tag
        }
        tag.title = book.title
        tag.album = book.title
        tag.artist = book.author
        tag.composer = book.narratedBy
        tag.genre = book.primaryGenre
        tag.year = book.releaseDate.map { String(Calendar.current.component(.year, from: $0)) } ?? ""
        tag.comment = HTMLText.markdown(book.summary)
        tag.cover = (library?.artURL(for: book) ?? book.imageURL).flatMap { $0.isFileURL ? try? Data(contentsOf: $0) : nil }
        return tag
    }

    func cancelExport(_ id: Book.ID) { exports.cancelExport(for: id) }

    /// Progress of a book's in-flight export, for its row and the inspector.
    func exportProgress(for id: Book.ID) -> Double? { exports.progress(for: id) }

    private func restore() {
        // Lets agents and screenshots open a library without the folder picker (build with CODE_SIGN_ENTITLEMENTS= to drop the sandbox).
        if let path = Harness.env["LECTERN_LIBRARY"] {
            open(URL(fileURLWithPath: path))
            if let asin = Harness.env["LECTERN_SELECT"] { selection = [asin] }
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        if let url = Self.resolve(data) { open(url) }
    }
}
