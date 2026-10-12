import AppKit
import AudibleCore
import Observation

/// The MP3 and Ogg Vorbis export queue: at most `ExportQueue.maxConcurrent` encodes at a time, each
/// cancellable and retryable, with the outcome kept in the job instead of thrown at an alert panel.
/// Scheduling rules live in `ExportQueue` in AudibleCore; this type is the plumbing (issue #5).
@Observable
final class ExportModel {
    private(set) var jobs: [ExportJob] = []
    /// Cached so the toolbar button does not filter the list on every render.
    private(set) var counts: (queued: Int, running: Int, finished: Int) = (0, 0, 0)
    /// Runs one job to completion, reporting progress. Supplied by `LibraryModel`, which owns the
    /// sources, tags and format settings.
    @ObservationIgnored var run: ((ExportJob, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    @ObservationIgnored private var tasks: [ExportJob.ID: Task<Void, Never>] = [:]

    /// Whether anything is queued or encoding, for Cancel All Jobs and the window's busy state.
    var isBusy: Bool { counts.queued + counts.running > 0 }

    func enqueue(_ job: ExportJob) {
        // One export per book at a time: a second one would write the same destination.
        guard !ExportQueue.isExporting(bookID: job.bookID, in: jobs) else { return }
        jobs.append(job)
        advance()
    }

    func cancel(_ id: ExportJob.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if ExportQueue.isRunning(jobs[index].state) {
            // The task's own catch records the outcome.
            tasks[id]?.cancel()
        } else if jobs[index].state == .queued {
            jobs[index].state = .cancelled
            jobs[index].message = "Cancelled before it started."
            advance()
        }
    }

    func cancelAll() {
        for job in jobs where job.state == .queued || ExportQueue.isRunning(job.state) { cancel(job.id) }
    }

    func retry(_ id: ExportJob.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ExportQueue.canRetry(jobs[index].state),
              !ExportQueue.isExporting(bookID: jobs[index].bookID, in: jobs) else { return }
        jobs[index].state = .queued
        jobs[index].message = nil
        jobs[index].progress = 0
        advance()
    }

    func clearFinished() {
        jobs.removeAll { ExportQueue.isFinished($0.state) }
        recount()
    }

    /// The progress to show on a book's row or in the inspector, or nil when it has no export in flight.
    func progress(for bookID: String) -> Double? { ExportQueue.progress(bookID: bookID, in: jobs) }

    func isExporting(_ bookID: String) -> Bool { ExportQueue.isExporting(bookID: bookID, in: jobs) }

    /// Cancels the in-flight export for a book, whichever job it is.
    func cancelExport(for bookID: String) {
        guard let job = jobs.first(where: { $0.bookID == bookID && ($0.state == .queued || ExportQueue.isRunning($0.state)) })
        else { return }
        cancel(job.id)
    }

    /// Starts as many queued jobs as the limit allows, then refreshes the cached counts.
    private func advance() {
        guard let run else { recount(); return }
        for id in ExportQueue.next(jobs) {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            jobs[index].state = .running
            jobs[index].progress = 0
            jobs[index].message = nil
            let job = jobs[index]
            tasks[id] = Task { [weak self] in
                do {
                    try await run(job) { value in
                        Task { @MainActor in self?.report(id, progress: value) }
                    }
                    self?.finish(id, .complete, "Saved to \(job.destination.lastPathComponent)")
                    Prefs.playCompletionSound()
                } catch is CancellationError {
                    self?.finish(id, .cancelled, "Cancelled. The partly written file was removed.")
                } catch {
                    self?.finish(id, .failed, error.localizedDescription)
                }
            }
        }
        recount()
    }

    private func report(_ id: ExportJob.ID, progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ExportQueue.isRunning(jobs[index].state) else { return }
        jobs[index].progress = progress
    }

    private func finish(_ id: ExportJob.ID, _ state: ExportJob.State, _ message: String?) {
        tasks[id] = nil
        if let index = jobs.firstIndex(where: { $0.id == id }), ExportQueue.isRunning(jobs[index].state) {
            jobs[index].state = state
            jobs[index].message = message
            if state == .complete { jobs[index].progress = 1 }
        }
        advance()
    }

    private func recount() { counts = ExportQueue.counts(jobs) }

    /// `LECTERN_EXPORTS_PREVIEW=1`: one job in each state so the popover can be snapshotted without
    /// encoding anything. Never starts the queue, and inert without the harness.
    func seedPreview() {
        guard Harness.env["LECTERN_EXPORTS_PREVIEW"] == "1", jobs.isEmpty else { return }
        func preview(_ title: String, _ format: ExportJob.Format, byChapter: Bool = false,
                     _ state: ExportJob.State, _ progress: Double = 0, _ message: String? = nil) -> ExportJob {
            var job = ExportJob(bookID: title, title: title, format: format, byChapter: byChapter,
                                source: URL(fileURLWithPath: "/tmp/\(title).m4b"),
                                destination: URL(fileURLWithPath: "/tmp/\(title).\(format.rawValue)"))
            job.state = state
            job.progress = progress
            job.message = message
            return job
        }
        jobs = [
            preview("Sapiens & Friends", .mp3, .running, 0.42),
            preview("The Second Book", .ogg, byChapter: true, .running, 0.08),
            preview("Something Queued", .mp3, .queued),
            preview("A Finished Export", .ogg, .complete, 1, "Saved to A Finished Export.ogg"),
            preview("One That Failed", .mp3, .failed, 0, "There was not enough disk space to finish the export."),
        ]
        recount()
    }
}
