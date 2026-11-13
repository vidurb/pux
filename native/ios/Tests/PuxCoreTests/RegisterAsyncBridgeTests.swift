import XCTest
@testable import PuxCore

final class RegisterAsyncBridgeTests: XCTestCase {
    func testSequentialSuccessfulAttempts() async throws {
        let bridge = RegisterAsyncBridge()
        try await bridge.run { _, complete in complete(.success(())) }
        do {
            try await bridge.run { _, complete in complete(.failure(PuxError.firebaseNotConfigured)) }
            XCTFail("Expected failure")
        } catch let error as PuxError {
            XCTAssertEqual(error, .firebaseNotConfigured)
        }
        try await bridge.run { gen, complete in
            XCTAssertEqual(gen, 3)
            complete(.success(()))
        }
    }

    func testPreCancelledCallerDoesNotInvokeStart() async throws {
        let bridge = RegisterAsyncBridge()
        let sdkStarts = LockedCounter()
        let gate = RunEntryGate()
        let task = Task {
            await gate.awaitGate()
            try await bridge.run { _, _ in
                sdkStarts.increment()
            }
        }
        await gate.waitUntilWaiting()
        task.cancel()
        await gate.open()
        _ = await task.result
        XCTAssertEqual(sdkStarts.value, 0)
    }

    func testCancellationBeforeContinuationInstallBuffered() async throws {
        let bridge = RegisterAsyncBridge()
        let arrived = LockedFlag()
        let task = Task {
            try await bridge.run { _, complete in
                arrived.value = true
                complete(.success(()))
            }
        }
        task.cancel()
        for _ in 0..<200 {
            if arrived.value { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        switch await task.result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            break
        }
    }

    func testOverlappingAttemptsIsolateLateCallbacks() async throws {
        let bridge = RegisterAsyncBridge()
        let box = CompletionBox()
        let first = Task {
            try await bridge.run { gen, complete in
                box.store(gen: gen, complete: complete)
            }
        }
        for _ in 0..<100 where !box.hasComplete() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await bridge.run { _, complete in complete(.success(())) }
        XCTAssertTrue(box.complete(gen: 1, result: .success(())))
        switch await first.result {
        case .success: break
        default: XCTFail("First attempt should complete independently")
        }
    }
}

/// Ensures cancellation is requested before `bridge.run` is entered.
private actor RunEntryGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var isWaiting = false

    func awaitGate() async {
        guard !opened else { return }
        isWaiting = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiter = cont
        }
        isWaiting = false
    }

    func waitUntilWaiting() async {
        for _ in 0..<500 where !isWaiting {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(isWaiting)
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    var value = false
    init() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?
    private var complete: ((Result<Void, Error>) -> Void)?

    func store(gen: UInt64, complete: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        generation = gen
        self.complete = complete
        lock.unlock()
    }

    func hasComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete != nil
    }

    func complete(gen: UInt64, result: Result<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == gen, let handler = complete else { return false }
        handler(result)
        return true
    }
}
