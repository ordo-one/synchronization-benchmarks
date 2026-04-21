import XCTest
@testable import MutexBench

final class PthreadBenchSupportTests: XCTestCase {
    func testXorShift32SequenceIsStable() {
        var rng = PthreadBenchXorShift32(seed: 0x1234_5678)
        XCTAssertEqual(rng.next(), 2_274_908_837)
        XCTAssertEqual(rng.next(), 358_294_691)
        XCTAssertEqual(rng.next(), 1_210_119_364)
    }

    func testCaseRunReturnsExpectedTotal() throws {
        #if !os(Linux)
        throw XCTSkip("PthreadBench runtime is Linux-only")
        #endif
        let config = PthreadBenchCase(threads: 4, locks: 3, ops: 1_000)
        let result = runPthreadBenchCase(config, lockFactory: PthreadBenchPThreadMutexCounter.make)

        XCTAssertEqual(result.total, 4_000)
        XCTAssertTrue(result.duration >= .zero)
    }

    func testCaseRunRecordsOneRoundPerRequestedRound() throws {
        #if !os(Linux)
        throw XCTSkip("PthreadBench runtime is Linux-only")
        #endif
        let config = PthreadBenchCase(threads: 2, locks: 1, ops: 50)
        let result = runPthreadBenchCase(config, lockFactory: PthreadBenchPThreadMutexCounter.make)

        XCTAssertTrue(result.duration >= .zero)
        XCTAssertEqual(result.total, 100)
    }
}
