import Foundation

public protocol FcmRegistrationSource: AnyObject, Sendable {
  func setRegistrationHandler(_ handler: @escaping @Sendable (String) -> Void)
  func setApnsToken(_ token: Data)
  func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void)
  func register() async throws
}

public extension FcmRegistrationSource {
  func setRegistrationHandler(_ handler: @escaping @Sendable (String) -> Void) {}
  func setApnsToken(_ token: Data) {}
  func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {}
  func register() async throws {}
}

/// Keeps the server's device row for this phone pointing at its current FID.
public actor FcmRegistration: DeliveryServiceProtocol {
  private let source: FcmRegistrationSource?
  private let apiClient: ApiClient
  private let recordStore: RecordStore
  private let onRefreshError: (@Sendable (Error) -> Void)?

  public var registrationTimeout: TimeInterval = 30

  private var registeredFID: String?
  private var isStarted = false
  private var pendingApnsToken: Data?
  private var inFlight = 0
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var initialFIDWait: InitialFIDWait?
  private var registerCallInFlight = false
  private var queuedFID: String?

  public init(
    source: FcmRegistrationSource? = nil,
    apiClient: ApiClient = .shared,
    recordStore: RecordStore = .shared,
    onRefreshError: (@Sendable (Error) -> Void)? = nil,
    registrationTimeout: TimeInterval = 30
  ) {
    self.source = source
    self.apiClient = apiClient
    self.recordStore = recordStore
    self.onRefreshError = onRefreshError
    self.registrationTimeout = registrationTimeout
  }

  public func start() async throws {
    isStarted = true
    guard let source = source else {
      throw PuxError.firebaseNotConfigured
    }

    if let apnsToken = pendingApnsToken {
      source.setApnsToken(apnsToken)
    }

    let initialWait = InitialFIDWait()
    initialFIDWait = initialWait
    defer {
      initialFIDWait = nil
      initialWait.finish(throwing: CancellationError())
    }

    source.setRegistrationHandler { [weak self] fid in
      Task { await self?.handleRegistrationEvent(fid) }
    }
    source.setErrorHandler { [weak self] error in
      Task { await self?.routeInitialWaitError(error, wait: initialWait) }
    }

    registerCallInFlight = true
    inFlight += 1
    defer {
      registerCallInFlight = false
      finishFlight()
    }

    if let pending = recordStore.pendingRegistration() {
      try await sendFID(pending)
      guard isStarted else { return }
    }

    let fid = try await waitForInitialFID(wait: initialWait) {
      try await source.register()
    }
    guard isStarted else { return }
    try await sendFID(fid)

    while let queued = queuedFID, isStarted {
      queuedFID = nil
      if queued != registeredFID {
        try await sendFID(queued)
      }
    }
  }

  public func stop() async {
    isStarted = false
    queuedFID = nil
    initialFIDWait?.finish(throwing: CancellationError())
    initialFIDWait = nil
    if inFlight > 0 {
      await withCheckedContinuation { stopWaiters.append($0) }
    }
  }

  public func handleApnsToken(_ token: Data) async {
    pendingApnsToken = token
    source?.setApnsToken(token)
  }

  public func handleRefreshError(_ error: Error) async {
    onRefreshError?(error)
  }

  private func routeInitialWaitError(_ error: Error, wait: InitialFIDWait) async {
    if initialFIDWait === wait {
      wait.finish(throwing: error)
    }
    onRefreshError?(error)
  }

  private func failInitialFIDWait(_ error: Error, wait: InitialFIDWait) {
    guard initialFIDWait === wait else { return }
    wait.finish(throwing: error)
  }

  public func handleFIDUpdate(_ fid: String) async {
    await handleRegistrationEvent(fid)
  }

  private func waitForInitialFID(
    wait: InitialFIDWait,
    register: @escaping () async throws -> Void
  ) async throws -> String {
    let registerTask = Task<Void, Never> { [weak self, wait] in
      do {
        try await register()
      } catch is CancellationError {
        await self?.failInitialFIDWait(CancellationError(), wait: wait)
      } catch {
        await self?.failInitialFIDWait(error, wait: wait)
      }
    }
    defer { registerTask.cancel() }

    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            wait.setContinuation(continuation)
          }
        }, onCancel: {
          wait.finish(throwing: CancellationError())
        })
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(self.registrationTimeout * 1_000_000_000))
        wait.finish(throwing: PuxError.fcmRegistrationTimedOut)
        throw PuxError.fcmRegistrationTimedOut
      }

      do {
        while let value = try await group.next() {
          if !value.isEmpty {
            group.cancelAll()
            return value
          }
        }
        throw PuxError.fcmRegistrationTimedOut
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func handleRegistrationEvent(_ fid: String) async {
    guard !fid.isEmpty else { return }

    if let wait = initialFIDWait, wait.complete(fid) {
      return
    }

    guard isStarted else { return }
    if fid == registeredFID || pendingApnsToken == nil { return }

    if registerCallInFlight || inFlight > 0 {
      queuedFID = fid
      return
    }

    do {
      try await sendFID(fid)
      while let queued = queuedFID, isStarted {
        queuedFID = nil
        if queued != registeredFID {
          try await sendFID(queued)
        }
      }
    } catch {
      onRefreshError?(error)
    }
  }

  private func finishFlight() {
    inFlight -= 1
    if inFlight == 0 {
      let waiters = stopWaiters
      stopWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  private func sendFID(_ fid: String) async throws {
    guard isStarted, let recordId = recordStore.recordId() else { return }
    inFlight += 1
    defer { finishFlight() }

    try recordStore.savePendingRegistration(fid)
    let currentDeviceId = recordStore.deviceId()

    let returnedDeviceId = try await apiClient.registerDevice(
      recordId: recordId,
      pushToken: fid,
      platform: "fcm",
      replacesDeviceId: currentDeviceId
    )

    try recordStore.saveDeviceId(returnedDeviceId)
    try recordStore.clearPendingRegistration()
    registeredFID = fid
  }
}

/// Exactly-once bridge between early/late FID, timeout, cancel, and Firebase errors.
private final class InitialFIDWait: @unchecked Sendable {
  private enum Outcome {
    case success(String)
    case failure(Error)
  }

  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var outcome: Outcome?

  func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
    lock.lock()
    defer { lock.unlock() }
    if let outcome = outcome {
      resume(continuation, outcome: outcome)
      return
    }
    self.continuation = continuation
  }

  func complete(_ fid: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard outcome == nil else { return false }
    if let cont = continuation {
      let result = Outcome.success(fid)
      outcome = result
      continuation = nil
      resume(cont, outcome: result)
      return true
    }
    outcome = .success(fid)
    return true
  }

  func finish(throwing error: Error) {
    lock.lock()
    defer { lock.unlock() }
    guard outcome == nil else { return }
    if let cont = continuation {
      let result = Outcome.failure(error)
      outcome = result
      continuation = nil
      resume(cont, outcome: result)
    } else {
      outcome = .failure(error)
    }
  }

  private func resume(_ continuation: CheckedContinuation<String, Error>, outcome: Outcome) {
    switch outcome {
    case .success(let fid):
      continuation.resume(returning: fid)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}
