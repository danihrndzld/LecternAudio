import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Audible could not be reached at all, as opposed to a request Audible answered with a rejection.
/// The download queue keeps its jobs queued when it sees one instead of failing them, so a launch
/// with no connection doesn't empty the queue into the failed state (issue #31).
public struct ConnectionFailure: LocalizedError, Sendable, Equatable {
    public init() {}
    public var errorDescription: String? { "Could not reach Audible. Check your connection and retry." }
}

/// The rules the download queue runs on. The queue itself is `DownloadModel` in the app target,
/// which has no test target, so every rule that can be stated as a function lives here instead and
/// is covered by offline tests.
public enum DownloadQueue {
    /// Extensions of the encrypted sources the queue writes into `sources/`, from `ContentCredentials`.
    static let sourceExtensions: Set<String> = ["aax", "aaxc"]

    /// A job the runner has taken up. Two rules depend on it:
    ///
    /// - A finished task may only write its outcome onto a job that is still in one of these states.
    ///   `cancel` records `.cancelled` at once and Retry queues a fresh job, both while the old task
    ///   is still unwinding; whichever lands first must win, or Retry is reverted to `.cancelled`.
    /// - The queue only counts these, plus `.queued`, as pending work.
    public static func isRunning(_ state: DownloadJob.State) -> Bool {
        [.licensing, .downloading, .converting].contains(state)
    }

    /// Whether `enqueue` may replace an existing job for the same book with a fresh `.queued` one.
    ///
    /// Retry and the other explicit actions reset a job that has finished one way or another.
    /// Automatic downloads after a sync must not: re-queueing a book the owner cancelled, or one
    /// that failed, on every sync defeats both (`docs/aax-conversion.md`).
    public static func shouldReplace(existing: DownloadJob.State, userInitiated: Bool) -> Bool {
        guard userInitiated else { return false }
        return [.failed, .cancelled, .complete].contains(existing)
    }

    /// Whether the network was unreachable, rather than Audible refusing the request. Retrying later
    /// is the only cure, so the queue holds its position instead of failing every job in turn.
    ///
    /// `AudibleHTTP` reports these as `ConnectionFailure`; the download transport throws `URLError`
    /// directly. Cancellation is never offline.
    public static func isOffline(_ error: Error) -> Bool {
        if error is ConnectionFailure { return true }
        guard let error = error as? URLError else { return false }
        return [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
                .dataNotAllowed, .callIsActive].contains(error.code)
    }

    /// The encrypted sources among `names` that belong to `asin`.
    ///
    /// The queue deletes them once a book has been converted and recorded. They are re-downloadable,
    /// useless without a fresh license, and each is about the size of the finished book, so keeping
    /// them costs roughly twice the disk of the library (issue #31). Matching is by the
    /// `<asin>-<fingerprint>.<ext>` layout `ContentDownload.sourceName` writes, so a cancelled
    /// attempt whose license has since changed is collected too.
    public static func sources(for asin: String, in names: [String]) -> [String] {
        guard AudibleContent.validASIN(asin) else { return [] }
        return names.filter { name in
            guard name.hasPrefix("\(asin)-") else { return false }
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            return sourceExtensions.contains(ext)
        }
    }
}
