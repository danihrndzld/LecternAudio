import Foundation

/// Lets at most `limit` tasks run at once, admitting the rest in the order they arrived.
///
/// The download queue converts inside each job, so a shared limiter is the only way to bound
/// conversions independently of how many downloads run: without it the conversion limit could only
/// ever be as coarse as the download limit (issue #18).
public actor ConcurrencyLimiter {
    private var limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Changing the limit admits more waiters at once; lowering it never interrupts work already
    /// running, it only stops new work starting until enough has finished.
    public func setLimit(_ value: Int) {
        limit = max(1, value)
        admit()
    }

    /// For tests: how many are running and how many are queued behind the limit.
    public var state: (running: Int, waiting: Int) { (running, waiting.count) }

    public func acquire() async throws {
        guard running >= limit else {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Runs `body` once a slot is free, handing the slot back however it ends. The actor is reentrant,
    /// so waiting here never blocks another task from acquiring or releasing.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    public func release() {
        running = max(0, running - 1)
        admit()
    }

    /// Fails a waiter whose task was cancelled before it ever started. One already admitted is not
    /// in the queue any more, so this does nothing and its own body sees the cancellation.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func admit() {
        while running < limit, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running += 1
            next.continuation.resume()
        }
    }
}
