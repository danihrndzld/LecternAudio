import AppKit
import AudibleCore
import Observation

@Observable
final class DownloadModel {
    private(set) var jobs: [DownloadJob] = []
    private(set) var progress: Double?
    private(set) var activeID: String?
    var error: String?
    var automaticallyDownload = false {
        didSet {
            if let identity { UserDefaults.standard.set(automaticallyDownload, forKey: "autoDownload.\(identity)") }
        }
    }
    private var identity: String?
    private var root: URL?
    private var task: Task<Void, Never>?
    private weak var session: AudibleSession?
    private weak var library: LibraryModel?
    private var generation = UUID()
    private var queueIsReadable = true

    var pendingCount: Int { jobs.filter { [.queued, .licensing, .downloading, .converting].contains($0.state) }.count }

    func configure(session: AudibleSession, library: LibraryModel, root: URL?) {
        let next = session.account?.storageID
        guard identity != next || self.library == nil else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        activeID = nil
        progress = nil
        identity = next
        self.root = root
        self.session = session
        self.library = library
        jobs = []
        error = nil
        queueIsReadable = true
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
        runNext()
    }

    func enqueue(_ books: [Book]) {
        guard identity != nil, queueIsReadable else { return }
        for book in books where !book.hasAudio && AudibleContent.validASIN(book.asin) && library?.canDownload(book) == true {
            if let index = jobs.firstIndex(where: { $0.id == book.id }) {
                if [.failed, .cancelled, .complete].contains(jobs[index].state) { jobs[index] = DownloadJob(book: book) }
            } else { jobs.append(DownloadJob(book: book)) }
        }
        guard persist() else { return }
        runNext()
    }

    func cancel(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        jobs[index].message = "Cancelled. Downloaded data is kept for retry."
        if activeID == id { task?.cancel() }
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

    private func runNext() {
        guard task == nil, let root, let session, let library,
              let job = jobs.first(where: { $0.state == .queued }) else { return }
        let token = generation
        let converter = AAXConverter()
        activeID = job.id
        progress = nil
        update(job.id, .licensing)
        task = Task {
            defer {
                if generation == token {
                    task = nil
                    activeID = nil
                    progress = nil
                    runNext()
                }
            }
            do {
                let account = try await session.currentAccount()
                guard account.storageID == identity, generation == token else { throw CancellationError() }
                let output = root.appendingPathComponent("books/\(job.book.asin).m4b")
                guard let helper = library.conversion.ffmpegURL else { throw ConversionError.ffmpegUnavailable }
                if FileManager.default.fileExists(atPath: output.path) {
                    try await converter.validate(output, ffmpeg: helper)
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    try library.recordDownload(job.book, output: output, root: root)
                    update(job.id, .complete)
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
                var downloaded: URL?
                for attempt in 0..<3 {
                    do {
                        downloaded = try await ContentDownload.fetch(url: license.url, destination: source, transfer: { request in
                            try await transport.download(for: request)
                        }) { value in
                            Task { @MainActor in
                                if self.generation == token, self.activeID == job.id,
                                   self.jobs.first(where: { $0.id == job.id })?.state == .downloading { self.progress = value }
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
                progress = 0
                let result = try await converter.convert(.init(input: downloaded, output: output, book: book, cover: cover),
                                                         credentials: license.credentials, ffmpeg: helper) { value in
                    Task { @MainActor in
                        if self.generation == token, self.activeID == job.id,
                           self.jobs.first(where: { $0.id == job.id })?.state == .converting { self.progress = value }
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
                Prefs.playCompletionSound()
            } catch {
                guard generation == token else { return }
                if Task.isCancelled || error is CancellationError { update(job.id, .cancelled, message: "Cancelled. Retry to resume.") }
                else {
                    let message = (error as? AudibleError)?.message ?? (error as? ConversionError)?.errorDescription
                        ?? "Download failed. Check your connection and disk space, then retry."
                    update(job.id, .failed, message: message)
                }
            }
        }
    }
}
