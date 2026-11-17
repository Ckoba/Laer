import Foundation
import Testing
@testable import LaerCore

actor Counter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

actor SleepLog {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

/// Suspends callers until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
}

@Suite struct RefreshCoordinatorTests {
    func makeCoordinator(_ log: SleepLog, policy: RetryPolicy = .init(baseDelay: .seconds(1))) -> RefreshCoordinator {
        RefreshCoordinator(policy: policy, sleep: { await log.record($0) })
    }

    @Test func concurrentRunsShareOneTask() async throws {
        let coordinator = makeCoordinator(SleepLog())
        let calls = Counter()
        let gate = Gate()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await coordinator.run(key: "courses", generation: 1) {
                        _ = await calls.increment()
                        await gate.wait()
                        return 7
                    }
                }
            }
            await waitUntil { await coordinator.waiterCount(key: "courses", generation: 1, type: Int.self) == 5 }
            await gate.open()
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(results == [7, 7, 7, 7, 7])
        #expect(await calls.value == 1)

        // The entry is cleared after completion, so a later run does new work.
        _ = try await coordinator.run(key: "courses", generation: 1) { await calls.increment() }
        #expect(await calls.value == 2)
    }

    @Test func cancelledRunClearsEntry() async throws {
        let coordinator = makeCoordinator(SleepLog())
        let calls = Counter()
        let gate = Gate()
        let waiting = Task {
            try await coordinator.run(key: "k", generation: 1) {
                _ = await calls.increment()
                await gate.wait()
                return 1
            }
        }
        await waitUntil { await coordinator.waiterCount(key: "k", generation: 1, type: Int.self) == 1 }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await coordinator.waiterCount(key: "k", generation: 1, type: Int.self) == 0)
        await gate.open()

        let value = try await coordinator.run(key: "k", generation: 1) { 2 }
        #expect(value == 2)
    }

    @Test func transientErrorsRetryWithinBudget() async throws {
        let log = SleepLog()
        let coordinator = makeCoordinator(log)
        let calls = Counter()
        await #expect(throws: APIError.server(status: 503)) {
            try await coordinator.run(key: "k", generation: 1) { () async throws -> Int in
                _ = await calls.increment()
                throw APIError.server(status: 503)
            }
        }
        #expect(await calls.value == 3)
        #expect(await log.durations == [.seconds(1), .seconds(2)])

        let recovering = Counter()
        let value = try await coordinator.run(key: "k2", generation: 1) { () async throws -> Int in
            if await recovering.increment() < 2 { throw APIError.offline }
            return 5
        }
        #expect(value == 5)
    }

    @Test(arguments: [APIError.signedOut, .forbidden, .notFound, .schema("x")])
    func permanentErrorsDoNotRetry(error: APIError) async throws {
        let log = SleepLog()
        let coordinator = makeCoordinator(log)
        let calls = Counter()
        await #expect(throws: error) {
            try await coordinator.run(key: "k", generation: 1) { () async throws -> Int in
                _ = await calls.increment()
                throw error
            }
        }
        #expect(await calls.value == 1)
        #expect(await log.durations.isEmpty)
    }

    @Test func throttleWaitsRetryAfterOnce() async throws {
        let log = SleepLog()
        let coordinator = makeCoordinator(log)
        let calls = Counter()
        let value = try await coordinator.run(key: "k", generation: 1) { () async throws -> Int in
            if await calls.increment() == 1 { throw APIError.throttled(retryAfter: 30) }
            return 9
        }
        #expect(value == 9)
        #expect(await log.durations == [.seconds(30)])
        #expect(await coordinator.isPaused == false)
    }

    @Test func secondThrottlePausesUntilResume() async throws {
        let log = SleepLog()
        let coordinator = makeCoordinator(log)
        let calls = Counter()
        await #expect(throws: RefreshError.paused) {
            try await coordinator.run(key: "k", generation: 1) { () async throws -> Int in
                _ = await calls.increment()
                throw APIError.throttled(retryAfter: 5)
            }
        }
        #expect(await calls.value == 2)
        #expect(await log.durations == [.seconds(5)])
        #expect(await coordinator.isPaused)

        await #expect(throws: RefreshError.paused) {
            try await coordinator.run(key: "other", generation: 1) { 1 }
        }
        await coordinator.resume()
        #expect(try await coordinator.run(key: "other", generation: 1) { 1 } == 1)
    }

    @Test func excessiveRetryAfterPausesImmediately() async throws {
        let log = SleepLog()
        let coordinator = makeCoordinator(log)
        await #expect(throws: RefreshError.paused) {
            try await coordinator.run(key: "k", generation: 1) { () async throws -> Int in
                throw APIError.throttled(retryAfter: 3600)
            }
        }
        #expect(await log.durations.isEmpty)
    }

    @Test func invalidatedGenerationIsStale() async throws {
        let coordinator = makeCoordinator(SleepLog())
        let gate = Gate()
        let old = Task {
            try await coordinator.run(key: "k", generation: 1) {
                await gate.wait()
                return 1
            }
        }
        await waitUntil { await coordinator.waiterCount(key: "k", generation: 1, type: Int.self) == 1 }
        await coordinator.invalidate(generation: 2)
        await gate.open()
        await #expect(throws: RefreshError.staleGeneration) { try await old.value }

        await #expect(throws: RefreshError.staleGeneration) {
            try await coordinator.run(key: "k", generation: 1) { 1 }
        }
        #expect(try await coordinator.run(key: "k", generation: 2) { 2 } == 2)
    }
}

@Suite struct SessionRecoveryTests {
    @Test func concurrentFailuresShareOneRenewAndReplayOnce() async throws {
        let renewals = Counter()
        let renewGate = Gate()
        let signedIn = Counter()
        let recovery = SessionRecovery(renew: {
            _ = await renewals.increment()
            await renewGate.wait()
            _ = await signedIn.increment()
        })
        let attempts = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await recovery.withRecovery { () async throws -> Int in
                        _ = await attempts.increment()
                        if await signedIn.value == 0 { throw APIError.signedOut }
                        return index
                    }
                }
            }
            await waitUntil {
                let tried = await attempts.value
                let renewed = await renewals.value
                return tried == 4 && renewed == 1
            }
            await renewGate.open()
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(results.sorted() == [0, 1, 2, 3])
        #expect(await renewals.value == 1)
        #expect(await attempts.value == 8)
    }

    @Test func secondSignedOutIsRethrown() async throws {
        let renewals = Counter()
        let recovery = SessionRecovery(renew: { _ = await renewals.increment() })
        let attempts = Counter()
        await #expect(throws: APIError.signedOut) {
            try await recovery.withRecovery { () async throws -> Int in
                _ = await attempts.increment()
                throw APIError.signedOut
            }
        }
        #expect(await renewals.value == 1)
        #expect(await attempts.value == 2)
    }

    @Test func otherErrorsDoNotRenew() async throws {
        let renewals = Counter()
        let recovery = SessionRecovery(renew: { _ = await renewals.increment() })
        await #expect(throws: APIError.forbidden) {
            try await recovery.withRecovery { () async throws -> Int in throw APIError.forbidden }
        }
        #expect(await renewals.value == 0)
    }
}

@Suite struct ProactiveRenewalTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func renewsOnceForConcurrentCallersWhenExpired() async throws {
        let counter = Counter()
        let recovery = SessionRecovery {
            counter.increment()
            try await Task.sleep(for: .milliseconds(20))
        }
        async let first: Void = recovery.renewIfNeeded { true }
        async let second: Void = recovery.renewIfNeeded { true }
        _ = try await (first, second)
        #expect(counter.count == 1)
    }

    @Test func doesNothingWhenStillValid() async throws {
        let counter = Counter()
        let recovery = SessionRecovery { counter.increment() }
        try await recovery.renewIfNeeded { false }
        #expect(counter.count == 0)
    }
}
