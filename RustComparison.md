# Rust Comparison

`comparison/rust/` — same workload in Rust, comparing `std::sync::Mutex` (pthread_mutex wrapper) and `parking_lot::Mutex` (ParkingLot pattern). Validates cross-language workload equivalence: Rust `std` ≈ Swift NIOLock within 5–10%.

```bash
cd comparison/rust && cargo run --release
```
