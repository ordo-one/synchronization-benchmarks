import NIOConcurrencyHelpers
import Synchronization

public struct MapState: Sendable {
    public var storage: [Int: UInt64]
    public var total: UInt64 = 0
    public var rng: UInt64 = 0xDEAD_BEEF_CAFE_F00D

    public init(capacity: Int) {
        storage = Dictionary(minimumCapacity: capacity)
        for i in 0..<capacity {
            storage[i] = 0
        }
    }

    @inlinable
    public mutating func update(iterations: Int) {
        for _ in 0..<iterations {
            let key = Int(total) % storage.count
            storage[key, default: 0] &+= 1
            total &+= 1
        }
    }

    /// Random-key variant: xorshift over the whole `storage.count` range.
    /// Defeats the HW prefetcher so capacity maps directly to cache level.
    @inlinable
    public mutating func updateRandom(iterations: Int) {
        var r = rng
        let count = storage.count
        for _ in 0..<iterations {
            r ^= r &<< 13
            r ^= r &>> 7
            r ^= r &<< 17
            let key = Int(r & 0x7FFF_FFFF_FFFF_FFFF) % count
            storage[key, default: 0] &+= 1
        }
        rng = r
        total &+= UInt64(iterations)
    }
}

public final class SyncMutexBox: @unchecked Sendable {
    public let m: Mutex<MapState>
    public init(capacity: Int) { m = Mutex(MapState(capacity: capacity)) }
    @inlinable public func work(_ n: Int) { m.withLock { $0.update(iterations: n) } }
}

public final class NIOLockBox: @unchecked Sendable {
    public let box: NIOLockedValueBox<MapState>
    public init(capacity: Int) { box = NIOLockedValueBox(MapState(capacity: capacity)) }
    @inlinable public func work(_ n: Int) { box.withLockedValue { $0.update(iterations: n) } }
}

@inline(never)
public func doUnlockedWork(_ iterations: Int) {
    var x: UInt64 = 0xDEAD_BEEF
    for _ in 0..<iterations {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
    }
    _blackHole(x)
}

@inline(never) @_optimize(none)
public func _blackHole(_ x: UInt64) {}

public let defaultMapCapacity = 64
public let defaultTotalAcquires = 50_000



/// Configuration for a single benchmark point.
public struct BenchConfig: Sendable {
    public let tasks: Int
    public let work: Int
    public let pause: Int

    public init(tasks: Int, work: Int, pause: Int = 0) {
        self.tasks = tasks
        self.work = work
        self.pause = pause
    }

    public var label: String { "tasks=\(tasks) work=\(work) pause=\(pause)" }
    public var acquiresPerTask: Int { defaultTotalAcquires / tasks }
}

/// Runs the workload: tasks × acquires × (locked work + unlocked pause).
public func runWorkload(
    tasks: Int,
    acquiresPerTask: Int,
    body: @Sendable @escaping () -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<tasks {
            group.addTask {
                for _ in 0..<acquiresPerTask { body() }
            }
        }
    }
}
