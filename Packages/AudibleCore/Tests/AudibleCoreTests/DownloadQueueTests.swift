import Foundation
import Testing
@testable import AudibleCore

private func job(_ asin: String = "B0000001", state: DownloadJob.State) -> DownloadJob {
    DownloadJob(book: Book(key: asin, title: "T", author: "A", seconds: 60, files: []), state: state)
}

// MARK: - A late outcome never overwrites a cancel or a retry (issue #31)

@Test func onlyRunningJobsAcceptTheirTaskOutcome() {
    for state in [DownloadJob.State.licensing, .downloading, .converting] {
        #expect(DownloadQueue.isRunning(state), "\(state) is the runner's own job")
    }
    // Retry has already queued a fresh job, or cancel/another outcome has already finished it.
    for state in [DownloadJob.State.queued, .complete, .failed, .cancelled] {
        #expect(!DownloadQueue.isRunning(state), "\(state) must not be overwritten by an unwinding task")
    }
}

// MARK: - Automatic downloads never revive a cancelled or failed book (issue #31)

@Test func onlyUserActionsResetAFinishedJob() {
    for state in [DownloadJob.State.failed, .cancelled, .complete] {
        #expect(DownloadQueue.shouldReplace(existing: state, userInitiated: true))
        #expect(!DownloadQueue.shouldReplace(existing: state, userInitiated: false),
                "an auto sync must not re-queue a \(state) book")
    }
}

@Test func unfinishedJobsAreNeverReplaced() {
    for state in [DownloadJob.State.queued, .licensing, .downloading, .converting] {
        #expect(!DownloadQueue.shouldReplace(existing: state, userInitiated: true))
        #expect(!DownloadQueue.shouldReplace(existing: state, userInitiated: false))
    }
}

// MARK: - Offline launch holds the queue instead of failing it (issue #31)

@Test func connectionFailuresAreOffline() {
    #expect(DownloadQueue.isOffline(ConnectionFailure()))
    for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed] {
        #expect(DownloadQueue.isOffline(URLError(code)), "\(code) is a connection failure")
    }
}

@Test func audibleRejectionsAndCancellationAreNotOffline() {
    // A rejection by Audible is final: the job must fail so the owner sees the reason.
    #expect(!DownloadQueue.isOffline(AudibleError("The audiobook download expired or failed.")))
    #expect(!DownloadQueue.isOffline(CancellationError()))
    #expect(!DownloadQueue.isOffline(URLError(.badServerResponse)))
    #expect(!DownloadQueue.isOffline(URLError(.unsupportedURL)))
}

@Test func connectionFailureKeepsTheExistingWording() {
    // Replaces a private app enum with the same message, so the UI is unchanged.
    #expect(ConnectionFailure().errorDescription == "Could not reach Audible. Check your connection and retry.")
}

// MARK: - Encrypted sources are collected after a successful download (issue #31)

@Test func sourcesMatchTheASINAndNothingElse() {
    let names = ["B0000001-abc123.aaxc", "B0000001-def456.aax", "B0000002-abc123.aaxc",
                 "B0000001.m4b", "B0000001-abc123.aaxc.partial", "B0000001-abc123.aria2part",
                 "catalog.json", "B0000001-abc123.AAXC"]
    let found = DownloadQueue.sources(for: "B0000001", in: names)
    // Both of this book's attempts, including a stale one from a cancelled run, and neither the
    // finished M4B nor another book's source nor an in-flight partial.
    #expect(Set(found) == ["B0000001-abc123.aaxc", "B0000001-def456.aax", "B0000001-abc123.AAXC"])
}

@Test func sourcesRejectsInvalidASINs() {
    // Never build a delete list from an unvalidated identifier.
    #expect(DownloadQueue.sources(for: "../../etc", in: ["../../etc-ab.aaxc"]).isEmpty)
    #expect(DownloadQueue.sources(for: "", in: ["-ab.aaxc"]).isEmpty)
}

@Test func sourcesIgnoresAPrefixThatOnlySharesAStem() {
    // "B0000001" must not collect "B00000010-…": the separator is part of the prefix.
    #expect(DownloadQueue.sources(for: "B0000001", in: ["B00000010-abc.aaxc"]).isEmpty)
}

// MARK: - Several downloads at a time (issue #18)

@Test func startsUpToTheDownloadLimitInOrder() {
    let jobs = [job("B01", state: .queued), job("B02", state: .queued), job("B03", state: .queued)]
    #expect(DownloadQueue.next(jobs, limit: 2).count == 2)
    #expect(DownloadQueue.next(jobs, limit: 2) == [jobs[0].id, jobs[1].id])
    #expect(DownloadQueue.next(jobs, limit: 1).count == 1)
}

@Test func runningDownloadsCountTowardTheLimit() {
    let jobs = [job("B01", state: .downloading), job("B02", state: .licensing), job("B03", state: .queued)]
    #expect(DownloadQueue.next(jobs, limit: 2).isEmpty, "two are already in flight")
    #expect(DownloadQueue.next(jobs, limit: 3).count == 1)
}

@Test func finishedDownloadsDoNotHoldASlot() {
    let jobs = [job("B01", state: .complete), job("B02", state: .failed), job("B03", state: .cancelled),
                job("B04", state: .queued)]
    #expect(DownloadQueue.next(jobs, limit: 1).count == 1)
}

@Test func theDownloadLimitIsClamped() {
    let jobs = (1...12).map { job(String(format: "B%03d", $0), state: .queued) }
    #expect(DownloadQueue.next(jobs, limit: 0).count == 1, "below the range behaves as one")
    #expect(DownloadQueue.next(jobs, limit: -3).count == 1)
    #expect(DownloadQueue.next(jobs, limit: 99).count == DownloadQueue.concurrencyRange.upperBound,
            "above the range is capped, never unbounded")
}

@Test func aJobWithALiveTaskKeepsItsSlotAndIsNotStartedTwice() {
    // Cancel then Retry: the job is queued again while its old task is still unwinding.
    let jobs = [job("B01", state: .queued), job("B02", state: .queued)]
    #expect(DownloadQueue.next(jobs, live: [jobs[0].id], limit: 1).isEmpty, "the unwinding task holds the only slot")
    #expect(DownloadQueue.next(jobs, live: [jobs[0].id], limit: 2) == [jobs[1].id], "never a second task for B01")
    // A cancelled job whose task is unwinding still counts.
    let cancelled = [job("B01", state: .cancelled), job("B02", state: .queued)]
    #expect(DownloadQueue.next(cancelled, live: [cancelled[0].id], limit: 1).isEmpty)
}

@Test func nothingQueuedStartsNoDownloads() {
    #expect(DownloadQueue.next([], limit: 3).isEmpty)
    #expect(DownloadQueue.next([job("B01", state: .complete)], limit: 3).isEmpty)
}
