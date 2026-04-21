import Foundation
import NIOConcurrencyHelpers
import Synchronization

#if os(Linux)
import Glibc
#endif

public struct PthreadBenchCase: Sendable {
    public let threads: Int
    public let locks: Int
    public let ops: Int

    public init(threads: Int, locks: Int, ops: Int) {
        precondition(threads > 0)
        precondition(locks > 0)
        precondition(ops >= 0)
        self.threads = threads
        self.locks = locks
        self.ops = ops
    }

    public var label: String {
        "threads=\(threads) locks=\(locks) ops=\(ops)"
    }
}

public struct PthreadBenchResult: Sendable {
    public let duration: Duration
    public let total: UInt64
}

public struct PthreadBenchXorShift32: Sendable {
    private var state: UInt32

    public init(seed: UInt32) {
        self.state = seed == 0 ? 0xA341_316C : seed
    }

    public mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }
}

public protocol PthreadBenchCounter: AnyObject {
    func increment()
    func load() -> UInt64
}

public final class PthreadBenchPThreadMutexCounter: PthreadBenchCounter {
    private var mutex = pthread_mutex_t()
    private var value: UInt64 = 0
    private let pad0: UInt64 = 0
    private let pad1: UInt64 = 0
    private let pad2: UInt64 = 0
    private let pad3: UInt64 = 0
    private let pad4: UInt64 = 0
    private let pad5: UInt64 = 0
    private let pad6: UInt64 = 0

    public init() {
        let status = pthread_mutex_init(&mutex, nil)
        precondition(status == 0, "pthread_mutex_init failed: \(status)")
        _ = (pad0, pad1, pad2, pad3, pad4, pad5, pad6)
    }

    deinit {
        let status = pthread_mutex_destroy(&mutex)
        precondition(status == 0, "pthread_mutex_destroy failed: \(status)")
    }

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchPThreadMutexCounter()
    }

    public func increment() {
        pthread_mutex_lock(&mutex)
        value &+= 1
        pthread_mutex_unlock(&mutex)
    }

    public func load() -> UInt64 {
        pthread_mutex_lock(&mutex)
        let current = value
        pthread_mutex_unlock(&mutex)
        return current
    }
}

public final class PthreadBenchSyncMutexCounter: PthreadBenchCounter {
    private let mutex = Mutex<UInt64>(0)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchSyncMutexCounter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

public final class PthreadBenchNIOLockCounter: PthreadBenchCounter {
    private let box = NIOLockedValueBox<UInt64>(0)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchNIOLockCounter()
    }

    public func increment() {
        box.withLockedValue { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        box.withLockedValue { $0 }
    }
}

#if os(Linux)
public final class PthreadBenchStdlibPICounter: PthreadBenchCounter {
    private let mutex = SynchronizationMutex<UInt64>(0)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchStdlibPICounter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

public final class PthreadBenchPlainFutexSpin0Counter: PthreadBenchCounter {
    private let mutex = PlainFutexMutex<UInt64>(0, spinTries: 0)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchPlainFutexSpin0Counter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

public final class PthreadBenchPlainFutexSpin14BackoffCounter: PthreadBenchCounter {
    private let mutex = PlainFutexMutex<UInt64>(0, spinTries: 14, useBackoff: true)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchPlainFutexSpin14BackoffCounter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

public final class PthreadBenchPlainFutexSpin40FixedCounter: PthreadBenchCounter {
    private let mutex = PlainFutexMutex<UInt64>(0, spinTries: 40)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchPlainFutexSpin40FixedCounter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

public final class PthreadBenchOptimalCounter: PthreadBenchCounter {
    private let mutex = OptimalMutex<UInt64>(0)

    public init() {}

    public static func make() -> any PthreadBenchCounter {
        PthreadBenchOptimalCounter()
    }

    public func increment() {
        mutex.withLock { $0 &+= 1 }
    }

    public func load() -> UInt64 {
        mutex.withLock { $0 }
    }
}

private final class LinuxPthreadBenchBarrier {
    private var mutex = pthread_mutex_t()
    private var cond = pthread_cond_t()
    private let parties: Int
    private var waiting = 0
    private var generation = 0

    init(parties: Int) {
        self.parties = parties
        precondition(pthread_mutex_init(&mutex, nil) == 0)
        precondition(pthread_cond_init(&cond, nil) == 0)
    }

    deinit {
        pthread_cond_destroy(&cond)
        pthread_mutex_destroy(&mutex)
    }

    func wait() {
        pthread_mutex_lock(&mutex)
        let currentGeneration = generation
        waiting += 1
        if waiting == parties {
            waiting = 0
            generation += 1
            pthread_cond_broadcast(&cond)
            pthread_mutex_unlock(&mutex)
            return
        }

        while currentGeneration == generation {
            pthread_cond_wait(&cond, &mutex)
        }
        pthread_mutex_unlock(&mutex)
    }
}

private final class LinuxPthreadBenchShared {
    let config: PthreadBenchCase
    let counters: [any PthreadBenchCounter]
    let startBarrier: LinuxPthreadBenchBarrier
    let endBarrier: LinuxPthreadBenchBarrier

    init(config: PthreadBenchCase, counters: [any PthreadBenchCounter]) {
        self.config = config
        self.counters = counters
        self.startBarrier = LinuxPthreadBenchBarrier(parties: config.threads + 1)
        self.endBarrier = LinuxPthreadBenchBarrier(parties: config.threads + 1)
    }
}

private final class LinuxPthreadBenchWorkerBox {
    let shared: LinuxPthreadBenchShared
    let seed: UInt32

    init(shared: LinuxPthreadBenchShared, seed: UInt32) {
        self.shared = shared
        self.seed = seed
    }
}

@_cdecl("mutexBenchLinuxPthreadWorker")
private func mutexBenchLinuxPthreadWorker(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let raw else { return nil }
    let box = Unmanaged<LinuxPthreadBenchWorkerBox>.fromOpaque(raw).takeRetainedValue()
    var rng = PthreadBenchXorShift32(seed: box.seed)
    let lockCount = UInt32(box.shared.config.locks)

    box.shared.startBarrier.wait()
    for _ in 0..<box.shared.config.ops {
        let idx = Int(rng.next() % lockCount)
        box.shared.counters[idx].increment()
    }
    box.shared.endBarrier.wait()
    return nil
}

private func linuxPthreadThreadSeeds(count: Int) -> [UInt32] {
    var seeds: [UInt32] = []
    seeds.reserveCapacity(count)
    var base = PthreadBenchXorShift32(seed: 0x6F4A_955E)
    var state: UInt32 = 0x9BA2_BF27
    for _ in 0..<count {
        state ^= base.next()
        seeds.append(state)
    }
    return seeds
}

public func runPthreadBenchCase(
    _ config: PthreadBenchCase,
    lockFactory: @escaping () -> any PthreadBenchCounter
) -> PthreadBenchResult {
    let counters = (0..<config.locks).map { _ in lockFactory() }
    let shared = LinuxPthreadBenchShared(config: config, counters: counters)
    let seeds = linuxPthreadThreadSeeds(count: config.threads)
    var threads = Array<pthread_t>(repeating: 0, count: config.threads)

    for index in 0..<config.threads {
        let box = LinuxPthreadBenchWorkerBox(shared: shared, seed: seeds[index])
        let raw = Unmanaged.passRetained(box).toOpaque()
        let status = pthread_create(&threads[index], nil, mutexBenchLinuxPthreadWorker, raw)
        precondition(status == 0, "pthread_create failed: \(status)")
    }

    usleep(100_000)
    shared.startBarrier.wait()
    let startNs = DispatchTime.now().uptimeNanoseconds
    shared.endBarrier.wait()
    let endNs = DispatchTime.now().uptimeNanoseconds

    for thread in threads {
        pthread_join(thread, nil)
    }

    let total = counters.reduce(into: UInt64(0)) { partial, counter in
        partial &+= counter.load()
    }
    let expected = UInt64(config.threads * config.ops)
    precondition(total == expected, "expected total \(expected), got \(total)")

    return PthreadBenchResult(
        duration: .nanoseconds(Int64(endNs &- startNs)),
        total: total
    )
}
#else
public func runPthreadBenchCase(
    _ config: PthreadBenchCase,
    lockFactory: @escaping () -> any PthreadBenchCounter
) -> PthreadBenchResult {
    _ = config
    _ = lockFactory
    preconditionFailure("PthreadBench is Linux-only")
}
#endif
