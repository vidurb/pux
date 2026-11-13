import Foundation

/// Exactly-once async bridge for one-shot callbacks (e.g. Firebase `register()`).
/// Each call owns an attempt object so pre-install cancellation, overlap, and late callbacks stay isolated.
public final class RegisterAsyncBridge: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0

  public init() {}

  public func run(
    _ start: @escaping @Sendable (
      _ generation: UInt64,
      _ complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Void
  ) async throws {
    let attempt = RegisterAttempt(generation: nextGeneration())
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          guard attempt.install(continuation) else { return }
          guard attempt.claimStart() else { return }
          start(attempt.generation) { result in
            attempt.finish(result)
          }
        }
      },
      onCancel: {
        attempt.finish(.failure(CancellationError()))
      }
    )
  }

  private func nextGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    return generation
  }
}

private final class RegisterAttempt: @unchecked Sendable {
  let generation: UInt64
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var outcome: Result<Void, Error>?

  init(generation: UInt64) {
    self.generation = generation
  }

  /// Returns false when the attempt already finished (continuation resumed).
  func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let outcome {
      resume(continuation, outcome)
      return false
    }
    self.continuation = continuation
    return true
  }

  func claimStart() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return outcome == nil
  }

  func finish(_ result: Result<Void, Error>) {
    lock.lock()
    defer { lock.unlock() }
    guard outcome == nil else { return }
    outcome = result
    if let continuation {
      self.continuation = nil
      resume(continuation, result)
    }
  }

  private func resume(_ continuation: CheckedContinuation<Void, Error>, _ result: Result<Void, Error>) {
    switch result {
    case .success:
      continuation.resume()
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}
