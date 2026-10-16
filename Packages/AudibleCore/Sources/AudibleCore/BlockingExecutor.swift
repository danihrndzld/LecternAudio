import Dispatch

/// Runs tasks that block a thread (AVAssetReader loops, pipe reads until EOF) on GCD instead of the
/// cooperative pool, which has one thread per core: three blocked readers froze every other task on
/// CI's 3-core runner for 30 s. Use with `Task.detached(executorPreference:)` or
/// `withTaskExecutorPreference`; cancellation and `Task.checkCancellation()` work as usual.
final class BlockingExecutor: TaskExecutor {
    static let shared = BlockingExecutor()
    private let queue = DispatchQueue(label: "AudibleCore.blocking", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
