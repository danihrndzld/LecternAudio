import AppKit
import AudibleCore
import Observation

@Observable
final class DownloadModel {
    private(set) var jobs: [DownloadJob] = []
    /// Progress of each job in flight, keyed by job id; absent until the first byte arrives.
    private(set) var progress: [String: Double] = [:]
    var error: String?
    var automaticallyDownload = false {
        didSet {
            if let identity { UserDefaults.standard.set(automaticallyDownload, forKey: "autoDownload.\(identity)") }
        }
    }
    private var identity: String?
    private var root: URL?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    private weak var session: AudibleSession?
    private weak var library: LibraryModel?
    private var generation = UUID()
    private var queueIsReadable = true
    /// Set when the network turned out to be unreachable: the queue holds where it is (issue #31).
    /// Cleared by any enqueue (an explicit action, or the automatic one after a successful sync) and
    /// by a completed job, since both prove the network works again.
    private(set) var waitingForConnection = false

    var pendingCount: Int { jobs.count { $0.state == .queued || DownloadQueue.isRunning($0.state) } }
    /// Tasks in flight, so the window can open the Downloads sheet when work starts. Stored rather
    /// than computed from `jobs`, so ContentView isn't invalidated by every job state change.
    private(set) var activeCount = 0

    func configure(session: AudibleSession, library: LibraryModel, root: URL?) {
        let next = session.account?.storageID
        guard identity != next || self.library == nil else { return }
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        activeCount = 0
        progress = [:]
        identity = next
        self.root = root
        self.session = session
        self.library = library
        jobs = []
        error = nil
        queueIsReadable = true
        waitingForConnection = false
        if let root, FileManager.default.fileExists(atPath: root.appendingPathComponent("queue.json").path) {
            do {
                jobs = try DownloadJob.restore(from: Data(contentsOf: root.appendingPathComponent("queue.json")))
            } catch {
                queueIsReadable = false
                self.error = "The download queue could not be restored. Its file has been left unchanged."
                return
            }
        }
        automaticallyDownload = next.map { UserDefaults.standard.bool(forKey: "autoDownload.\($0)") } ?? false
        advance()
    }

    /// `userInitiated` is false only for the automatic download after a sync, which must not revive a
    /// book the owner cancelled or one that failed; only an explicit action resets those (issue #31).
    func enqueue(_ books: [Book], userInitiated: Bool = true) {
        guard identity != nil, queueIsReadable else { return }
        for book in books where !book.hasAudio && AudibleContent.validASIN(book.asin) && library?.canDownload(book) == true {
            if let index = jobs.firstIndex(where: { $0.id == book.id }) {
                if DownloadQueue.shouldReplace(existing: jobs[index].state, userInitiated: userInitiated) {
                    jobs[index] = DownloadJob(book: book)
                }
            } else { jobs.append(DownloadJob(book: book)) }
        }
        guard persist() else { return }
        // An explicit action, or the automatic enqueue after a successful sync, ends a connection hold.
        waitingForConnection = false
        advance()
    }

    func cancel(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        jobs[index].message = "Cancelled. Downloaded data is kept for retry."
        tasks[id]?.cancel()
        _ = persist()
    }

    private func update(_ id: String, _ state: DownloadJob.State, message: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].message = message
        _ = persist()
    }

    @discardableResult private func persist() -> Bool {
        guard let root else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("queue.json"), options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "Could not save the download queue. Check available disk space and permissions."
            return false
        }
    }

    /// Deletes the encrypted sources for `asin`. They are re-downloadable, useless without a fresh
    /// license, and each is about the size of the finished book, so keeping them cost roughly twice the
    /// disk of the library (issue #31). Only called once the converted M4B has been recorded, so a
    /// failed or cancelled job keeps its partial download for Retry.
    private func removeSources(for asin: String, in root: URL) {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("sources")
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in DownloadQueue.sources(for: asin, in: names) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Starts as many queued jobs as Settings allows, counting those already in flight (issue #18).
    /// Also called when the limit changes in Settings, so a raised limit applies at once.
    func advance() {
        guard let root, let session, let library, !waitingForConnection else { return }
        for id in DownloadQueue.next(jobs, live: Set(tasks.keys), limit: Prefs.downloadConcurrency) {
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            start(job, root: root, session: session, library: library)
        }
    }

    private func start(_ job: DownloadJob, root: URL, session: AudibleSession, library: LibraryModel) {
        let token = generation
        let converter = AAXConverter()
        progress[job.id] = nil
        update(job.id, .licensing)
        tasks[job.id] = Task {
            defer {
                if generation == token {
                    tasks[job.id] = nil
                    activeCount = tasks.count
                    progress[job.id] = nil
                    advance()
                }
            }
            do {
                let account = try await session.currentAccount()
                guard account.storageID == identity, generation == token else { throw CancellationError() }
                let output = root.appendingPathComponent("books/\(job.book.asin).m4b")
                guard let helper = library.conversion.ffmpegURL else { throw ConversionError.ffmpegUnavailable }
                if FileManager.default.fileExists(atPath: output.path) {
                    try await Prefs.conversions.run { try await converter.validate(output, ffmpeg: helper) }
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    try library.recordDownload(job.book, output: output, root: root)
                    update(job.id, .complete)
                    waitingForConnection = false
                    removeSources(for: job.book.asin, in: root)
                    return
                }
                let (data, response) = try await AudibleHTTP.data(for: AudibleContent.licenseRequest(asin: job.book.asin, account: account))
                try AudibleContent.checkResponse(response)
                let license = try AudibleContent.license(from: data, asin: job.book.asin, account: account)
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let source = root.appendingPathComponent("sources").appendingPathComponent(try ContentDownload.sourceName(asin: job.book.asin, credentials: license.credentials))
                update(job.id, .downloading)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                let transport = URLSession(configuration: configuration, delegate: DownloadRedirects(), delegateQueue: nil)
                defer { transport.invalidateAndCancel() }
                let accelerator = Prefs.aria2Accelerator
                var downloaded: URL?
                for attempt in 0..<3 {
                    do {
                        downloaded = try await ContentDownload.fetch(url: license.url, destination: source, transfer: { request in
                            try await transport.download(for: request)
                        }, accelerator: accelerator) { value in
                            Task { @MainActor in
                                if self.generation == token,
                                   self.jobs.first(where: { $0.id == job.id })?.state == .downloading { self.progress[job.id] = value }
                            }
                        }
                        break
                    } catch {
                        try Task.checkCancellation()
                        if attempt == 2 { throw error }
                        try await Task.sleep(for: .seconds(attempt + 1))
                    }
                }
                guard let downloaded, generation == token else { throw CancellationError() }
                var book = job.book
                if !license.chapters.isEmpty { book.chapters = license.chapters }
                var cover: URL?
                if let imageURL = book.imageURL, AudibleContent.validDownloadURL(imageURL) {
                    var request = URLRequest(url: imageURL)
                    request.timeoutInterval = 30
                    request.httpShouldHandleCookies = false
                    if let (temporary, response) = try? await transport.download(for: request) {
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if (response as? HTTPURLResponse)?.statusCode == 200,
                           ["image/jpeg", "image/png"].contains(response.mimeType ?? ""), size > 0, size < 20 * 1024 * 1024 {
                            let art = root.appendingPathComponent("art")
                            try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
                            let target = art.appendingPathComponent("\(book.asin).\(response.mimeType == "image/png" ? "png" : "jpg")")
                            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: temporary, to: target) }
                            cover = target
                        }
                    }
                }
                try Task.checkCancellation()
                update(job.id, .converting)
                progress[job.id] = 0
                // Conversions are processor-bound and shared with manual conversions, so they go
                // through one limiter rather than running once per download slot (issue #18).
                // Immutable copies: the limiter's body is @Sendable and cannot capture the vars above.
                let converting = book, artwork = cover
                let result = try await Prefs.conversions.run {
                    try await converter.convert(.init(input: downloaded, output: output, book: converting, cover: artwork),
                                                credentials: license.credentials, ffmpeg: helper) { value in
                        Task { @MainActor in
                            if self.generation == token,
                               self.jobs.first(where: { $0.id == job.id })?.state == .converting { self.progress[job.id] = value }
                        }
                    }
                }
                do {
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    try library.recordDownload(book, output: result, root: root)
                } catch {
                    try? FileManager.default.removeItem(at: result)
                    throw error
                }
                update(job.id, .complete)
                waitingForConnection = false
                removeSources(for: job.book.asin, in: root)
                Prefs.playCompletionSound()
            } catch {
                // `cancel` has already recorded `.cancelled` and Retry has already queued a fresh job;
                // whichever landed while this task unwound keeps its state (issue #31).
                guard generation == token, let current = jobs.first(where: { $0.id == job.id })?.state,
                      DownloadQueue.isRunning(current) else { return }
                if Task.isCancelled || error is CancellationError {
                    update(job.id, .cancelled, message: "Cancelled. Retry to resume.")
                } else if DownloadQueue.isOffline(error) {
                    waitingForConnection = true
                    update(job.id, .queued, message: "Waiting for a connection. Retry once you are back online.")
                } else {
                    let message = (error as? AudibleError)?.message ?? (error as? ConversionError)?.errorDescription
                        ?? "Download failed. Check your connection and disk space, then retry."
                    update(job.id, .failed, message: message)
                }
            }
        }
        activeCount = tasks.count
    }
}
