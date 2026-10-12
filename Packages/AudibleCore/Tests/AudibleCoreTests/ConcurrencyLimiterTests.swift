import Foundation
import Testing
@testable import AudibleCore

/// Counts how many bodies overlap, so a test can assert the limit was never exceeded.
private actor Peak {
    private var current = 0
    private(set) var highest = 0

    func enter() { current += 1; highest = max(highest, current) }
    func leave() { current -= 1 }
}

private func hammer(_ limiter: ConcurrencyLimiter, tasks: Int, peak: Peak) async {
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<tasks {
            group.addTask {
                try? await limiter.acquire()
                await peak.enter()
                try? await Task.sleep(for: .milliseconds(10))
                await peak.leave()
                await limiter.release()
            }
        }
    }
}

@Test func neverRunsMoreThanTheLimit() async {
    let limiter = ConcurrencyLimiter(limit: 3)
    let peak = Peak()
    await hammer(limiter, tasks: 20, peak: peak)
    #expect(await peak.highest <= 3)
    #expect(await peak.highest > 1, "it should actually run things in parallel")
    #expect(await limiter.state == (0, 0), "every slot is handed back")
}

@Test func oneAtATimeIsSerial() async {
    let limiter = ConcurrencyLimiter(limit: 1)
    let peak = Peak()
    await hammer(limiter, tasks: 6, peak: peak)
    #expect(await peak.highest == 1)
    #expect(await limiter.state == (0, 0))
}

@Test func acquiringUpToTheLimitDoesNotWait() async throws {
    let limiter = ConcurrencyLimiter(limit: 2)
    try await limiter.acquire()
    try await limiter.acquire()
    #expect(await limiter.state == (running: 2, waiting: 0))
    await limiter.release()
    #expect(await limiter.state == (running: 1, waiting: 0))
}

@Test func releasingAdmitsAWaiter() async throws {
    let limiter = ConcurrencyLimiter(limit: 1)
    try await limiter.acquire()
    let admitted = Task { try await limiter.acquire() }
    // Let the waiter queue up before releasing.
    while await limiter.state.waiting == 0 { await Task.yield() }
    #expect(await limiter.state == (running: 1, waiting: 1))
    await limiter.release()
    try await admitted.value
    #expect(await limiter.state == (running: 1, waiting: 0))
}

@Test func raisingTheLimitAdmitsWaitersAtOnce() async throws {
    let limiter = ConcurrencyLimiter(limit: 1)
    try await limiter.acquire()
    let a = Task { try await limiter.acquire() }
    let b = Task { try await limiter.acquire() }
    while await limiter.state.waiting < 2 { await Task.yield() }
    await limiter.setLimit(3)
    try await a.value
    try await b.value
    #expect(await limiter.state == (running: 3, waiting: 0))
}

@Test func loweringTheLimitStopsNewWorkButNotRunningWork() async throws {
    let limiter = ConcurrencyLimiter(limit: 3)
    for _ in 0..<3 { try await limiter.acquire() }
    await limiter.setLimit(1)
    // The three in flight keep going; nothing new is admitted until they drain below the new limit.
    #expect(await limiter.state == (running: 3, waiting: 0))
    let waiter = Task { try await limiter.acquire() }
    while await limiter.state.waiting == 0 { await Task.yield() }
    await limiter.release()
    await limiter.release()
    #expect(await limiter.state.waiting == 1, "still above the new limit of 1")
    await limiter.release()
    try await waiter.value
    #expect(await limiter.state == (running: 1, waiting: 0))
}

@Test func aCancelledWaiterThrowsAndFreesNothing() async throws {
    let limiter = ConcurrencyLimiter(limit: 1)
    try await limiter.acquire()
    let waiter = Task { try await limiter.acquire() }
    while await limiter.state.waiting == 0 { await Task.yield() }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    // The cancelled waiter never held a slot, so the one running job still holds the only one.
    #expect(await limiter.state == (running: 1, waiting: 0))
    await limiter.release()
    #expect(await limiter.state == (running: 0, waiting: 0))
}

@Test func aLimitBelowOneIsTreatedAsOne() async throws {
    let limiter = ConcurrencyLimiter(limit: 0)
    try await limiter.acquire()
    #expect(await limiter.state == (running: 1, waiting: 0))
    await limiter.setLimit(-5)
    await limiter.release()
    let peak = Peak()
    await hammer(limiter, tasks: 4, peak: peak)
    #expect(await peak.highest == 1)
}

@Test func releaseNeverGoesNegative() async {
    let limiter = ConcurrencyLimiter(limit: 2)
    await limiter.release()
    await limiter.release()
    #expect(await limiter.state == (running: 0, waiting: 0))
}

@Test func runHandsTheSlotBackOnSuccessAndOnFailure() async throws {
    struct Boom: Error {}
    let limiter = ConcurrencyLimiter(limit: 1)
    let value = try await limiter.run { 42 }
    #expect(value == 42)
    #expect(await limiter.state == (0, 0))

    await #expect(throws: Boom.self) { try await limiter.run { throw Boom() } }
    #expect(await limiter.state == (0, 0), "a thrown body still frees its slot")

    // The limiter is still usable afterwards.
    #expect(try await limiter.run { "ok" } == "ok")
}

@Test func runNeverOverlapsBeyondTheLimit() async {
    let limiter = ConcurrencyLimiter(limit: 2)
    let peak = Peak()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                try? await limiter.run {
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await peak.leave()
                }
            }
        }
    }
    #expect(await peak.highest <= 2)
    #expect(await limiter.state == (0, 0))
}
