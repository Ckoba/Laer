import Foundation

public struct RetryPolicy: Sendable {
    /// Retries after `.server` and `.offline`, on top of the first attempt.
    public var maxTransientRetries: Int
    /// First transient backoff, doubled on each retry. Also the wait for a throttle without Retry-After.
    public var baseDelay: Duration
    /// A longer Retry-After pauses the coordinator instead of waiting.
    public var maxRetryAfter: Duration

    public init(maxTransientRetries: Int = 2, baseDelay: Duration = .seconds(1), maxRetryAfter: Duration = .seconds(120)) {
        self.maxTransientRetries = maxTransientRetries
        self.baseDelay = baseDelay
        self.maxRetryAfter = maxRetryAfter
    }
}

public enum RefreshError: Error, Equatable, Sendable {
    /// The result belongs to a generation that has since been invalidated, for example after an account switch.
    case staleGeneration
    /// The site throttled repeatedly. Nothing runs until `resume()`.
    case paused
}

/// Coalesces identical refreshes, retries transient failures within a budget and backs off on throttling.
public actor RefreshCoordinator {
    private struct Key: Hashable {
        var key: String
        var generation: Int
        var type: ObjectIdentifier
    }

    private struct Flight {
        var id: UUID
        var task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<any Sendable, any Error>]
    }

    private let policy: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private var flights: [Key: Flight] = [:]
    private var minimumGeneration = Int.min
    public private(set) var isPaused = false

    public init(
        policy: RetryPolicy = .init(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    /// Runs `work`, or joins an identical run already in flight for the same key and generation.
    public func run<T: Sendable>(
        key: String, generation: Int, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if isPaused { throw RefreshError.paused }
        if generation < minimumGeneration { throw RefreshError.staleGeneration }
        let flightKey = Key(key: key, generation: generation, type: ObjectIdentifier(T.self))
        let waiterID = UUID()

        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(flightKey, waiterID: waiterID, continuation: continuation, work: work)
            }
        } onCancel: {
            Task { await self.cancelWaiter(flightKey, waiterID: waiterID) }
        }

        if generation < minimumGeneration { throw RefreshError.staleGeneration }
        guard let result = value as? T else { throw RefreshError.staleGeneration }
        return result
    }

    /// Marks every generation below `generation` as stale and cancels their in-flight work.
    public func invalidate(generation: Int) {
        guard generation > minimumGeneration else { return }
        minimumGeneration = generation
        for (key, flight) in flights where key.generation < generation {
            flights[key] = nil
            flight.task.cancel()
            for continuation in flight.waiters.values {
                continuation.resume(throwing: RefreshError.staleGeneration)
            }
        }
    }

    public func resume() {
        isPaused = false
    }

    func waiterCount(key: String, generation: Int, type: Any.Type) -> Int {
        flights[Key(key: key, generation: generation, type: ObjectIdentifier(type))]?.waiters.count ?? 0
    }

    // MARK: - Flights

    private func join<T: Sendable>(
        _ key: Key, waiterID: UUID,
        continuation: CheckedContinuation<any Sendable, any Error>,
        work: @escaping @Sendable () async throws -> T
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if flights[key] != nil {
            flights[key]?.waiters[waiterID] = continuation
            return
        }
        let id = UUID()
        let task = Task {
            let result: Result<any Sendable, any Error>
            do {
                result = .success(try await self.perform { try await work() })
            } catch {
                result = .failure(error)
            }
            self.finish(key, id: id, result: result)
        }
        flights[key] = Flight(id: id, task: task, waiters: [waiterID: continuation])
    }

    private func finish(_ key: Key, id: UUID, result: Result<any Sendable, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(_ key: Key, waiterID: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if let flight = flights[key], flight.waiters.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        }
    }

    // MARK: - Retry

    private func perform(_ work: @Sendable () async throws -> any Sendable) async throws -> any Sendable {
        var transientRetries = 0
        var throttledOnce = false
        while true {
            if isPaused { throw RefreshError.paused }
            do {
                return try await work()
            } catch let error as APIError {
                switch error {
                case .server, .offline:
                    guard transientRetries < policy.maxTransientRetries else { throw error }
                    let delay = policy.baseDelay * (1 << transientRetries)
                    transientRetries += 1
                    try await sleep(delay)
                case .throttled(let retryAfter):
                    let wait = retryAfter.map { Duration.seconds($0) } ?? policy.baseDelay
                    if throttledOnce || wait > policy.maxRetryAfter {
                        isPaused = true
                        throw RefreshError.paused
                    }
                    throttledOnce = true
                    try await sleep(wait)
                default:
                    throw error
                }
            }
        }
    }
}

/// Renews an expired session once for all concurrent callers, then replays each call once.
public actor SessionRecovery {
    private let renew: @Sendable () async throws -> Void
    private var renewal: Task<Void, any Error>?
    private var epoch = 0

    public init(renew: @escaping @Sendable () async throws -> Void) {
        self.renew = renew
    }

    public func withRecovery<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let startEpoch = epoch
        do {
            return try await work()
        } catch APIError.signedOut {
            try await renewOnce(after: startEpoch)
            return try await work()
        }
    }

    /// Renews ahead of a request, sparing the failed round trip when expiry is already known.
    public func renewIfNeeded(_ isExpired: @Sendable () async -> Bool) async throws {
        let startEpoch = epoch
        if await isExpired() { try await renewOnce(after: startEpoch) }
    }

    private func renewOnce(after startEpoch: Int) async throws {
        // A renewal that completed after this call started already covers it.
        if epoch > startEpoch { return }
        let task: Task<Void, any Error>
        if let renewal {
            task = renewal
        } else {
            let renew = self.renew
            task = Task { try await renew() }
            renewal = task
        }
        do {
            try await task.value
        } catch {
            if renewal == task { renewal = nil }
            throw error
        }
        if renewal == task {
            renewal = nil
            epoch += 1
        }
    }
}
