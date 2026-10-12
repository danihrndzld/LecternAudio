import Foundation

/// One MP3 or Ogg Vorbis export. Not persisted: every job has a destination the owner picked in a
/// save panel, which there is no way to re-ask for on the next launch.
public struct ExportJob: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable, Equatable { case queued, running, complete, failed, cancelled }
    public enum Format: String, Sendable, Equatable {
        case mp3, ogg

        public var name: String {
            switch self {
            case .mp3: "MP3"
            case .ogg: "Ogg Vorbis"
            }
        }
    }

    public let id: UUID
    public let bookID: String
    public let title: String
    public let format: Format
    public let byChapter: Bool
    public let source: URL
    public let destination: URL
    public var state: State = .queued
    public var message: String?
    public var progress = 0.0

    public init(id: UUID = UUID(), bookID: String, title: String, format: Format, byChapter: Bool,
                source: URL, destination: URL) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.format = format
        self.byChapter = byChapter
        self.source = source
        self.destination = destination
    }
}

/// The rules the export queue runs on. The queue itself is `ExportModel` in the app target, which has
/// no test target, so the scheduling decisions live here and are covered by offline tests (issue #5).
public enum ExportQueue {
    /// Exports are CPU-bound (LAME and libvorbis encode on a background thread), so more than a
    /// couple at once only makes each slower and the UI less responsive.
    public static let maxConcurrent = 2

    public static func isRunning(_ state: ExportJob.State) -> Bool { state == .running }

    public static func isFinished(_ state: ExportJob.State) -> Bool {
        [.complete, .failed, .cancelled].contains(state)
    }

    /// The jobs to start now: queued jobs in order, up to the concurrency limit, counting those
    /// already running. Empty when the limit is already reached.
    public static func next(_ jobs: [ExportJob], limit: Int = maxConcurrent) -> [ExportJob.ID] {
        let running = jobs.count { isRunning($0.state) }
        guard running < limit else { return [] }
        return jobs.filter { $0.state == .queued }.prefix(limit - running).map(\.id)
    }

    /// Whether a job may be retried: only one that has finished and did not succeed.
    public static func canRetry(_ state: ExportJob.State) -> Bool { [.failed, .cancelled].contains(state) }

    /// Counts for the toolbar's activity button, so views read a cached value rather than filtering.
    public static func counts(_ jobs: [ExportJob]) -> (queued: Int, running: Int, finished: Int) {
        var queued = 0, running = 0, finished = 0
        for job in jobs {
            switch job.state {
            case .queued: queued += 1
            case .running: running += 1
            case .complete, .failed, .cancelled: finished += 1
            }
        }
        return (queued, running, finished)
    }

    /// Whether a book already has an export in flight, so a second one is not started for it.
    public static func isExporting(bookID: String, in jobs: [ExportJob]) -> Bool {
        jobs.contains { $0.bookID == bookID && ($0.state == .queued || isRunning($0.state)) }
    }

    /// The progress to show on a book's row: its in-flight export, if any.
    public static func progress(bookID: String, in jobs: [ExportJob]) -> Double? {
        jobs.first { $0.bookID == bookID && ($0.state == .queued || isRunning($0.state)) }?.progress
    }
}
