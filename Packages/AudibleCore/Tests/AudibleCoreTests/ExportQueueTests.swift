import Foundation
import Testing
@testable import AudibleCore

private func job(_ book: String, _ state: ExportJob.State = .queued, progress: Double = 0) -> ExportJob {
    var j = ExportJob(bookID: book, title: book, format: .mp3, byChapter: false,
                      source: URL(fileURLWithPath: "/tmp/\(book).m4b"),
                      destination: URL(fileURLWithPath: "/tmp/\(book).mp3"))
    j.state = state
    j.progress = progress
    return j
}

// MARK: - Two at a time (issue #5)

@Test func startsUpToTheLimitInOrder() {
    let jobs = [job("A"), job("B"), job("C"), job("D")]
    let next = ExportQueue.next(jobs)
    #expect(next.count == 2)
    #expect(next == [jobs[0].id, jobs[1].id], "queued jobs start in order")
}

@Test func runningJobsCountTowardTheLimit() {
    #expect(ExportQueue.next([job("A", .running), job("B")]).count == 1)
    #expect(ExportQueue.next([job("A", .running), job("B", .running), job("C")]).isEmpty)
}

@Test func finishedJobsDoNotHoldASlot() {
    let jobs = [job("A", .complete), job("B", .failed), job("C", .cancelled), job("D"), job("E")]
    #expect(ExportQueue.next(jobs).count == 2, "three finished jobs block nothing")
}

@Test func nothingQueuedStartsNothing() {
    #expect(ExportQueue.next([]).isEmpty)
    #expect(ExportQueue.next([job("A", .complete)]).isEmpty)
}

@Test func theLimitIsConfigurableForTesting() {
    let jobs = [job("A"), job("B"), job("C")]
    #expect(ExportQueue.next(jobs, limit: 1).count == 1)
    #expect(ExportQueue.next(jobs, limit: 5).count == 3, "never more than there are queued")
}

// MARK: - Retry

@Test func onlyFailedAndCancelledJobsRetry() {
    #expect(ExportQueue.canRetry(.failed))
    #expect(ExportQueue.canRetry(.cancelled))
    #expect(!ExportQueue.canRetry(.complete), "a finished export has nothing to redo")
    #expect(!ExportQueue.canRetry(.queued))
    #expect(!ExportQueue.canRetry(.running))
}

// MARK: - What the toolbar and the rows read

@Test func countsSplitByState() {
    let counts = ExportQueue.counts([job("A"), job("B"), job("C", .running),
                                     job("D", .complete), job("E", .failed), job("F", .cancelled)])
    #expect(counts.queued == 2)
    #expect(counts.running == 1)
    #expect(counts.finished == 3)
}

@Test func countsOfNothing() {
    let counts = ExportQueue.counts([])
    #expect(counts == (0, 0, 0))
}

@Test func aBookWithAnInFlightExportIsBusy() {
    let jobs = [job("A", .running), job("B"), job("C", .complete)]
    #expect(ExportQueue.isExporting(bookID: "A", in: jobs))
    #expect(ExportQueue.isExporting(bookID: "B", in: jobs), "queued counts as in flight")
    #expect(!ExportQueue.isExporting(bookID: "C", in: jobs), "a finished export does not block a new one")
    #expect(!ExportQueue.isExporting(bookID: "Z", in: jobs))
}

@Test func rowProgressComesFromTheInFlightExport() {
    let jobs = [job("A", .complete, progress: 1), job("A", .running, progress: 0.4)]
    #expect(ExportQueue.progress(bookID: "A", in: jobs) == 0.4, "the running one, not the finished one")
    #expect(ExportQueue.progress(bookID: "Z", in: jobs) == nil)
}

@Test func formatNames() {
    #expect(ExportJob.Format.mp3.name == "MP3")
    #expect(ExportJob.Format.ogg.name == "Ogg Vorbis")
    #expect(ExportJob.Format(rawValue: "ogg") == .ogg)
}
