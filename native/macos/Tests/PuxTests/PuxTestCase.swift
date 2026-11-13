import XCTest

/// Default per-test timeout so hung tests fail fast instead of stalling CI.
class PuxTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        applyDefaultExecutionTimeAllowance()
    }

    override func setUp() async throws {
        try await super.setUp()
        applyDefaultExecutionTimeAllowance()
    }

    func applyDefaultExecutionTimeAllowance() {
        if executionTimeAllowance == 0 {
            executionTimeAllowance = 60
        }
    }
}
