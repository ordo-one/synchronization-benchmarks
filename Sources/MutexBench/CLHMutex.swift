//===----------------------------------------------------------------------===//
// CLHMutex — CLH queue lock with futex park fallback
//
// Craig / Landin & Hagersten 1993-94. Each waiter spins on its PREDECESSOR's
// node (not its own, as in MCS), so handoff is a single release store to the
// departing owner's node — no `next` pointer, no wait-for-next gap.
//
// Node states: 1 = waiting, 2 = parked on futex, 0 = released.
//
// Node lifecycle (classic CLH recycling): on acquire, the `prev` returned
// from the tail exchange is "released" (state==0) and becomes this thread's
// node for the next acquire. The lock retains every node it has ever
// allocated via `allocatedNodes`; thread-local storage only holds a
// (non-owning) reference to the node this thread is currently carrying.
//
// Compared to MCSMutex:
//   - Node is a single UInt32 state word (no next pointer).
//   - Release is one atomic store (+ conditional futex_wake).
//   - No "unlock spins until successor links" preemption window.
//
// Preemption of a current queue head still stalls its successor — universal
// for spin-queue locks. Mitigated by falling back to futex after `spinTries`.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims
import NIOConcurrencyHelpers
import Synchronization
import Glibc

@usableFromInline
final class CLHNode: @unchecked Sendable {
    // Allocated once; lifetime bound to the lock via `allocatedNodes`.
    // Futex syscalls need a raw UInt32 address, so the state word itself
    // cannot be a `Synchronization.Atomic<UInt32>` (that hides its storage).
    // The rest of the lock is pointer-arithmetic-free.
    @usableFromInline let state: UnsafeMutablePointer<UInt32>

    @usableFromInline
    init() {
        state = .allocate(capacity: 1)
        state.initialize(to: 0)  // released; first acquirer sees empty queue
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }
}

public final class CLHMutex<Value>: @unchecked Sendable {
    // Tail holds `Unmanaged<CLHNode>.toOpaque()` encoded as UInt. ARC-level
    // encoding: nodes are retained by `allocatedNodes`, so `passUnretained`
    // is safe for tail's lifetime.
    @usableFromInline let tail: Synchronization.Atomic<UInt>

    // Retains every node ever created for this lock. Deallocated at deinit.
    @usableFromInline var allocatedNodes: [CLHNode]
    @usableFromInline let nodesLock = NIOLock()

    // Per-thread slot holding the thread's current "mine" node. pthread_key
    // storage is an opaque pointer; we encode/decode via Unmanaged.
    @usableFromInline var tlsKey: pthread_key_t = pthread_key_t()

    @usableFromInline var value: Value

    public let spinTries: Int
    public let pauseBase: UInt32

    public init(_ initialValue: Value, spinTries: Int = 200, pauseBase: UInt32 = 128) {
        self.spinTries = spinTries
        self.pauseBase = pauseBase
        self.value = initialValue

        let dummy = CLHNode()  // state=0, acts as the initial released predecessor
        self.allocatedNodes = [dummy]
        let dummyBits = UInt(bitPattern: Unmanaged.passUnretained(dummy).toOpaque())
        self.tail = Synchronization.Atomic<UInt>(dummyBits)

        pthread_key_create(&tlsKey, nil)
    }

    deinit {
        pthread_key_delete(tlsKey)
        // allocatedNodes released by ARC → CLHNode.deinit frees state words
    }

    @inline(__always) @usableFromInline
    func tlsGet() -> CLHNode? {
        guard let opaque = pthread_getspecific(tlsKey) else { return nil }
        return Unmanaged<CLHNode>.fromOpaque(opaque).takeUnretainedValue()
    }

    @inline(__always) @usableFromInline
    func tlsSet(_ node: CLHNode) {
        pthread_setspecific(tlsKey, Unmanaged.passUnretained(node).toOpaque())
    }

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        let mine: CLHNode
        if let existing = tlsGet() {
            mine = existing
        } else {
            mine = CLHNode()
            nodesLock.withLock { allocatedNodes.append(mine) }
            tlsSet(mine)
        }

        // Mark waiting. Relaxed — the exchange below publishes.
        atomic_store_relaxed_u32(mine.state, 1)

        // Enqueue: prev = xchg(tail, mine). acq_rel pairs with predecessor's
        // eventual release store seen by our spin loop.
        let mineBits = UInt(bitPattern: Unmanaged.passUnretained(mine).toOpaque())
        let prevBits = tail.exchange(mineBits, ordering: .acquiringAndReleasing)
        let prev = Unmanaged<CLHNode>.fromOpaque(
            UnsafeRawPointer(bitPattern: prevBits)!
        ).takeUnretainedValue()

        // Spin on predecessor's state. No wait-for-next exists in CLH.
        var spinsRemaining = spinTries
        let mask = pauseBase &- 1
        let jitter = fast_jitter()
        var acquired = false
        while spinsRemaining > 0 {
            if atomic_load_acquire_u32(prev.state) == 0 {
                acquired = true
                break
            }
            let pauses = pauseBase &+ (jitter & mask)
            for _ in 0..<pauses { spin_loop_hint() }
            spinsRemaining &-= 1
        }
        if !acquired {
            // Mark parked so releaser knows to futex_wake. CAS 1→2; failure
            // means predecessor already released — re-check via loop.
            _ = atomic_cas_acquire_u32(prev.state, 1, 2)
            while atomic_load_acquire_u32(prev.state) != 0 {
                let err = futex_wait(prev.state, 2)
                switch err {
                case 0, 11, 4: break  // woken, EAGAIN, EINTR
                default: fatalError("CLHMutex futex_wait: \(err)")
                }
            }
        }

        // Classic CLH recycling: predecessor's now-released node becomes our
        // next-round node. Bounds the node pool to thread count per lock.
        tlsSet(prev)

        defer {
            // Release. Successor (if any) spins on `mine`. Exchange returns
            // old value — skip futex_wake unless a waiter actually parked.
            let old = atomic_exchange_release_u32(mine.state, 0)
            if old == 2 { _ = futex_wake(mine.state, 1) }
        }
        return try body(&value)
    }
}
#endif
