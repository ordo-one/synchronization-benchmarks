import Foundation

// MutexHarness — type-erased lock + "call body under lock with optional hook
// fired inside the locked region". Hook captures acquisition time for latency
// histograms in LongRun/Asymmetric; passed as `{}` when unused.
public final class MutexHarness: @unchecked Sendable {
    @usableFromInline let _runLocked: @Sendable (_ hook: () -> Void, _ body: (inout MapState) -> Void) -> Void
    public let dumpStats: (@Sendable (_ label: String) -> Void)?

    public init(
        runLocked: @escaping @Sendable (_ hook: () -> Void, _ body: (inout MapState) -> Void) -> Void,
        dumpStats: (@Sendable (String) -> Void)? = nil
    ) {
        self._runLocked = runLocked
        self.dumpStats = dumpStats
    }

    @inlinable
    public func runLocked(hook: () -> Void = {}, body: (inout MapState) -> Void) {
        _runLocked(hook, body)
    }
}

public struct MutexVariant: Sendable {
    public let name: String
    public let make: @Sendable (_ capacity: Int) -> MutexHarness

    public init(name: String, make: @escaping @Sendable (Int) -> MutexHarness) {
        self.name = name
        self.make = make
    }
}

// MARK: - Individual variant factories

public extension MutexVariant {
    static func syncMutex(name: String = "Synchronization.Mutex") -> MutexVariant {
        MutexVariant(name: name) { cap in
            let box = SyncMutexBox(capacity: cap)
            return MutexHarness { hook, body in
                box.m.withLock { hook(); body(&$0) }
            }
        }
    }

    static func niolock(name: String = "NIOLockedValueBox") -> MutexVariant {
        MutexVariant(name: name) { cap in
            let box = NIOLockBox(capacity: cap)
            return MutexHarness { hook, body in
                box.box.withLockedValue { hook(); body(&$0) }
            }
        }
    }

    #if os(Linux)
    static func syncMutexCopy(name: String = "Synchronization.Mutex (copy)") -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = SynchronizationMutex(MapState(capacity: cap))
            return MutexHarness { hook, body in
                m.withLock { hook(); body(&$0) }
            }
        }
    }

    static func plainFutex(
        name: String,
        spinTries: Int = 100,
        earlyExitOnWaiters: Bool = false,
        useBackoff: Bool = false,
        backoffCap: UInt32 = 32,
        backoffFloor: UInt32 = 1,
        useJitter: Bool = false,
        useHWJitter: Bool = false,
        separateCacheLine: Bool = false
    ) -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = PlainFutexMutex(
                MapState(capacity: cap),
                spinTries: spinTries,
                earlyExitOnWaiters: earlyExitOnWaiters,
                useBackoff: useBackoff,
                backoffCap: backoffCap,
                separateCacheLine: separateCacheLine,
                backoffFloor: backoffFloor,
                useJitter: useJitter,
                useHWJitter: useHWJitter
            )
            return MutexHarness { hook, body in
                m.withLock { hook(); body(&$0) }
            }
        }
    }

    static func optimal(name: String = "Optimal", instrument: Bool = false) -> MutexVariant {
        MutexVariant(name: name) { cap in
            if instrument {
                let m = OptimalMutexStats(MapState(capacity: cap))
                return MutexHarness(
                    runLocked: { hook, body in m.withLock { hook(); body(&$0) } },
                    dumpStats: { label in m.stats.dump(label: label) }
                )
            }
            let m = OptimalMutex(MapState(capacity: cap))
            return MutexHarness { hook, body in m.withLock { hook(); body(&$0) } }
        }
    }

    #if os(Linux)
    /// Swift port of Amanieu's parking_lot::Mutex (Apache-2.0/MIT).
    /// Bucketed hash-table parker + 2-bit state byte + fair handoff.
    /// See Sources/MutexBench/ParkingLotMutex.swift.
    static func parkingLot(name: String = "parking_lot", instrument: Bool = false) -> MutexVariant {
        MutexVariant(name: name) { cap in
            if instrument {
                let s = MutexStats()
                let m = ParkingLotMutex(MapState(capacity: cap), stats: s)
                return MutexHarness(
                    runLocked: { hook, body in m.withLock { hook(); body(&$0) } },
                    dumpStats: { label in s.dump(label: label) }
                )
            }
            let m = ParkingLotMutex(MapState(capacity: cap))
            return MutexHarness { hook, body in m.withLock { hook(); body(&$0) } }
        }
    }

    /// Knob-less Rust-upstream futex impl (spinTries=100, pausesPerIter=1, no
    /// retries/gates). Parallel to `optimal()`: static constants fold at compile
    /// time. Use for ship-candidate comparison; use `rustMutex(...)` for knob
    /// experimentation.
    static func rustStdMutex(name: String = "RustStdMutex", instrument: Bool = false) -> MutexVariant {
        MutexVariant(name: name) { cap in
            if instrument {
                let s = MutexStats()
                let m = RustStdMutex(MapState(capacity: cap), stats: s)
                return MutexHarness(
                    runLocked: { hook, body in m.withLock { hook(); body(&$0) } },
                    dumpStats: { label in s.dump(label: label) }
                )
            }
            let m = RustStdMutex(MapState(capacity: cap))
            return MutexHarness { hook, body in m.withLock { hook(); body(&$0) } }
        }
    }
    #endif

    static func rustMutex(
        name: String = "RustMutex",
        spinTries: Int = 100,
        pausesPerIter: UInt32 = 1,
        outerRetries: Int = 0,
        retrierLimit: UInt32 = 0,
        spinIfLimited: Bool = false,
        depthThreshold: UInt32 = 0,
        skipSpuriousWake: Bool = false,
        demoteOnEmpty: Bool = false,
        instrument: Bool = false
    ) -> MutexVariant {
        MutexVariant(name: name) { cap in
            if instrument {
                let s = MutexStats()
                let m = RustMutex(
                    MapState(capacity: cap),
                    stats: s,
                    spinTries: spinTries,
                    pausesPerIter: pausesPerIter,
                    outerRetries: outerRetries,
                    retrierLimit: retrierLimit,
                    spinIfLimited: spinIfLimited,
                    depthThreshold: depthThreshold,
                    skipSpuriousWake: skipSpuriousWake,
                    demoteOnEmpty: demoteOnEmpty
                )
                return MutexHarness(
                    runLocked: { hook, body in m.withLock { hook(); body(&$0) } },
                    dumpStats: { label in s.dump(label: label) }
                )
            }
            let m = RustMutex(
                MapState(capacity: cap),
                spinTries: spinTries,
                pausesPerIter: pausesPerIter,
                outerRetries: outerRetries,
                retrierLimit: retrierLimit,
                spinIfLimited: spinIfLimited,
                depthThreshold: depthThreshold,
                skipSpuriousWake: skipSpuriousWake,
                demoteOnEmpty: demoteOnEmpty
            )
            return MutexHarness { hook, body in m.withLock { hook(); body(&$0) } }
        }
    }

    static func depthAdaptive(
        name: String,
        spinTries: Int = 20,
        pauseBase: UInt32 = 64,
        depthThreshold: UInt32 = 4,
        useStarvation: Bool = false,
        starvationThresholdNs: UInt64 = 0,
        postWakeSpinTries: Int = 0,
        postCASLostPause: UInt32 = 0,
        preWaitDoubleCheck: Bool = false,
        kernelSpinTries: Int = 0,
        useJitter: Bool = true,
        instrument: Bool = false
    ) -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = DepthAdaptiveMutex(
                MapState(capacity: cap),
                spinTries: spinTries,
                pauseBase: pauseBase,
                depthThreshold: depthThreshold,
                useJitter: useJitter,
                kernelSpinTries: kernelSpinTries,
                postWakeSpinTries: postWakeSpinTries,
                useStarvation: useStarvation,
                starvationThresholdNs: starvationThresholdNs,
                preWaitDoubleCheck: preWaitDoubleCheck,
                postCASLostPause: postCASLostPause,
                instrument: instrument
            )
            if instrument {
                return MutexHarness(
                    runLocked: { hook, body in m.withLock { hook(); body(&$0) } },
                    dumpStats: { label in if let s = m.stats { s.dump(label: label) } }
                )
            }
            return MutexHarness { hook, body in m.withLock { hook(); body(&$0) } }
        }
    }

    static func pthreadAdaptive(name: String = "pthread_adaptive_np") -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = AdaptiveMutex(MapState(capacity: cap))
            return MutexHarness { hook, body in
                m.withLock { hook(); body(&$0) }
            }
        }
    }

    static func adaptiveSpin(name: String, maxCap: UInt32, pauseBase: UInt32) -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = AdaptiveSpinMutex(MapState(capacity: cap), maxCap: maxCap, pauseBase: pauseBase)
            return MutexHarness { hook, body in
                m.withLock { hook(); body(&$0) }
            }
        }
    }

    static func piNoSpin(name: String = "PI no-spin") -> MutexVariant {
        MutexVariant(name: name) { cap in
            let m = SynchronizationMutex(MapState(capacity: cap), spinTries: 0)
            return MutexHarness { hook, body in
                m.withLock { hook(); body(&$0) }
            }
        }
    }
    #endif
}

// MARK: - Standard variant presets

public enum StandardVariants {
    /// The 7-variant cross-bench default: Sync.Mutex, NIO, PlainFutex spin=100/14-backoff/40-fixed,
    /// Optimal, pthread_adaptive_np. Used by ContentionRatio/HoldTime/CacheLevels/BackgroundLoad/NanosecondContention.
    /// Respects BenchEnv.copy/slow gates. Does NOT include RustMutex by default (targets that want it
    /// append manually); see `defaultsWithRust` for the common variant that does.
    public static func defaults(
        copy: Bool = BenchEnv.copy,
        slow: Bool = BenchEnv.slow
    ) -> [MutexVariant] {
        var v: [MutexVariant] = [
            .syncMutex(),
            .niolock(),
        ]
        #if os(Linux)
        if copy { v.append(.syncMutexCopy()) }
        v.append(.plainFutex(name: "PlainFutexMutex (spin=100)", spinTries: 100))
        v.append(.plainFutex(name: "plain spin=14 backoff", spinTries: 14, useBackoff: true))
        v.append(.plainFutex(name: "plain spin=40 fixed", spinTries: 40))
        v.append(.optimal())
        if slow { v.append(.pthreadAdaptive()) }
        #endif
        return v
    }

    /// defaults + RustMutex (knobbed) + RustStdMutex (knob-less ship form).
    /// Used by Bursty/LongRun/NanosecondContention/ContentionRatio after the
    /// 2026-04-19 Rust addition; RustStdMutex added 2026-04-20 to measure
    /// branch-cost delta vs the parameterized RustMutex.
    public static func defaultsWithRust(
        copy: Bool = BenchEnv.copy,
        slow: Bool = BenchEnv.slow
    ) -> [MutexVariant] {
        var v = defaults(copy: copy, slow: slow)
        #if os(Linux)
        // Insert Rust pair after Optimal (before pthread_adaptive_np if present).
        let insertAt = v.firstIndex { $0.name == "pthread_adaptive_np" } ?? v.endIndex
        v.insert(contentsOf: [.rustMutex(), .rustStdMutex()], at: insertAt)
        #endif
        return v
    }
}
