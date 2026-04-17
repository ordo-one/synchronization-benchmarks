import Foundation

// Time-based workload helpers, inspired by:
//   - abseil: https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc
//     uses delay_inside_ns / delay_outside_ns parameters (calibrated spin).
//   - folly: https://github.com/facebook/folly/blob/main/folly/synchronization/test/SmallLocksBenchmark.cpp
//     uses `SpinFor(std::chrono::microseconds)`.
//
// Calibrated spin. Measures xorshift ops/ns once at module load, then uses count-based
// spin so the hot path has no clock reads. Precision ≈ 30 ns; sub-50 ns targets
// will be noisy but this matches abseil's BM_Contended smallest delay (50 ns).

public let opsPerNs: Double = {
    let iterations = 10_000_000
    var x: UInt64 = 0xDEAD_BEEF_CAFE_F00D
    // Warm up to avoid measuring first-call overhead.
    for _ in 0..<100_000 {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
    }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
    }
    let end = DispatchTime.now().uptimeNanoseconds
    _blackHole(x)
    let ns = end - start
    return ns > 0 ? Double(iterations) / Double(ns) : 1.0
}()

/// Burn `ns` nanoseconds in userspace, no clock reads in the hot loop.
@inline(__always)
public func burnNs(_ ns: Int) {
    if ns <= 0 { return }
    let ops = max(1, Int(Double(ns) * opsPerNs))
    var x: UInt64 = 0xDEAD_BEEF
    for _ in 0..<ops {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
    }
    _blackHole(x)
}
