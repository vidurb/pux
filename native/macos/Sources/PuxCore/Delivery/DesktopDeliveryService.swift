import AppKit
import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// A task group cannot enforce a deadline on a child that ignores cancellation:
// it waits for every child before returning. Resolve this continuation once instead.
private final class PresentationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: Bool, beforeResume: () -> Void = {}) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation = continuation else { return false }
        beforeResume()
        continuation.resume(returning: result)
        return true
    }
}

private final class NotificationAccessRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NotificationAccess?, Never>?
    init(_ continuation: CheckedContinuation<NotificationAccess?, Never>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: NotificationAccess?) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: result)
        return true
    }
}

/// One underlying `check()` per active probe; callers register continuations with individual deadlines (no shared Task.value).
private actor BoundedPermissionAccessGate {
    private struct ActiveProbe {
        let token: UInt
        let session: Int
        let generation: UInt
        var result: NotificationAccess?
        var waiters: [UInt: CheckedContinuation<NotificationAccess?, Never>] = [:]
        var waiterDeadlines: [UInt: Task<Void, Never>] = [:]
        var checkTask: Task<Void, Never>?
    }

    private var active: ActiveProbe?
    private var nextProbeToken: UInt = 0
    private var nextWaiterId: UInt = 0
    private var lastServiceEpoch: UInt = 0

    func check(
        permissions: NotificationPermissionsProtocol,
        timeout: TimeInterval,
        session: Int,
        serviceEpoch: UInt
    ) async -> NotificationAccess? {
        if serviceEpoch < lastServiceEpoch { return nil }
        if serviceEpoch != lastServiceEpoch {
            lastServiceEpoch = serviceEpoch
            tearDownActiveProbe(clearWithResult: false)
        }

        if let active, active.session == session {
            if let result = active.result {
                return result
            }
            return await registerWaiter(timeout: timeout)
        }

        if active != nil {
            tearDownActiveProbe(clearWithResult: false)
        }

        let token = nextProbeToken
        nextProbeToken += 1
        let generation = serviceEpoch
        var probe = ActiveProbe(token: token, session: session, generation: generation)
        probe.checkTask = Task {
            let access = await permissions.check()
            await self.finishProbe(access, token: token, generation: generation)
        }
        active = probe
        return await registerWaiter(timeout: timeout)
    }

    private func registerWaiter(timeout: TimeInterval) async -> NotificationAccess? {
        guard var probe = active else { return nil }
        if let result = probe.result {
            active = probe
            return result
        }

        let waiterId = nextWaiterId
        nextWaiterId += 1
        let generation = probe.generation

        return await withCheckedContinuation { continuation in
            probe.waiters[waiterId] = continuation
            probe.waiterDeadlines[waiterId] = Task {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self.waiterTimedOut(waiterId: waiterId, generation: generation)
            }
            active = probe
        }
    }

    private func waiterTimedOut(waiterId: UInt, generation: UInt) {
        guard var probe = active, probe.generation == generation else { return }
        guard let continuation = probe.waiters.removeValue(forKey: waiterId) else { return }
        probe.waiterDeadlines.removeValue(forKey: waiterId)?.cancel()
        active = probe
        continuation.resume(returning: nil)
    }

    private func tearDownActiveProbe(clearWithResult: Bool) {
        guard let probe = active else { return }
        let resume: NotificationAccess? = clearWithResult ? probe.result : nil
        probe.checkTask?.cancel()
        for deadline in probe.waiterDeadlines.values { deadline.cancel() }
        let waiters = probe.waiters
        active = nil
        for continuation in waiters.values {
            continuation.resume(returning: resume)
        }
    }

    func pendingWaiterCountForTesting() -> Int {
        active?.waiters.count ?? 0
    }

    func abandonIncompleteProbeForRetry() {
        guard let probe = active, probe.result == nil else { return }
        tearDownActiveProbe(clearWithResult: false)
    }

    func hasIncompleteProbe(for session: Int) -> Bool {
        guard let probe = active, probe.session == session else { return false }
        return probe.result == nil
    }

    private var onProbeFinishedWithNoWaiters: (@Sendable (Int) -> Void)?

    func setOnProbeFinishedWithNoWaiters(_ handler: (@Sendable (Int) -> Void)?) {
        onProbeFinishedWithNoWaiters = handler
    }

    private func finishProbe(_ result: NotificationAccess, token: UInt, generation: UInt) {
        guard generation == lastServiceEpoch else { return }
        guard var probe = active, probe.token == token, probe.generation == generation else { return }
        probe.result = result
        let waiters = probe.waiters
        let session = probe.session
        for deadline in probe.waiterDeadlines.values { deadline.cancel() }
        probe.waiters = [:]
        probe.waiterDeadlines = [:]
        active = nil
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
        if waiters.isEmpty {
            onProbeFinishedWithNoWaiters?(session)
        }
    }
}

@MainActor
public protocol DesktopDeliveryServiceDelegate: AnyObject {
    func deliveryService(_ service: DesktopDeliveryService, didUpdateStatus status: DeliveryStatus)
    func deliveryService(_ service: DesktopDeliveryService, didUpdateHeldDeliveries held: [HeldDelivery])
}

private struct DeliveryWorkKey: Hashable {
    let session: Int
    let deliveryId: String
}

public final class DesktopDeliveryService: @unchecked Sendable {
    public static let holdFor: TimeInterval = 15 * 60
    public static let holdRecheckInterval: TimeInterval = 30
    public static let reregistrationInterval: TimeInterval = 12 * 3600
    public static let pingInterval: TimeInterval = 30
    public static let showTimeout: TimeInterval = 3.0
    public static let permissionCheckTimeout: TimeInterval = 30
    public static let pongTimeout: TimeInterval = 45
    public static let webSocketSendTimeout: TimeInterval = 10
    /// Autonomous acknowledgement retries: exponential backoff from `ackRetryInitialDelay`
    /// up to `ackRetryMaxDelay`, at most `ackRetryMaxAttempts` rounds per series (about six
    /// minutes, inside the server's ten-minute delivery retention). A later poll, reconnect,
    /// restart or fresh failure starts a new series, so exhaustion is never permanent.
    public static let ackRetryInitialDelay: TimeInterval = 2
    public static let ackRetryMaxDelay: TimeInterval = 60
    public static let ackRetryMaxAttempts = 10

    private let recordStore: RecordStore
    private let apiClient: ApiClient
    private let crypto: SodiumCrypto
    private let notificationPresenter: NotificationPresenter
    private let notificationPermissions: NotificationPermissionsProtocol
    private let holdInterval: TimeInterval
    private let presentationTimeout: TimeInterval

    public weak var delegate: DesktopDeliveryServiceDelegate?

    private let lock = NSLock()
#if DEBUG
    private var lockOwnerThread: mach_port_t?
#endif
    private var _status: DeliveryStatus = DeliveryStatus(state: .idle)
    private var _holding: [String: HeldDelivery] = [:]
    private var _finished: Set<String> = []
    private var _pendingAcks: Set<String> = []
    private var _stopped: Bool = true
    private var _attempt: Int = 0
    private var _session: Int = 0
    private var flushActiveSession: Int?
    private var flushActiveEpoch: UInt = 0
    private var flushCoalescedPending: [Int: UInt] = [:]
    private var flushCoalescedHandled: [Int: UInt] = [:]
    private var flushDeferredSessions: Set<Int> = []
    private var _isReconnecting: Bool = false
    private var _presenting: [String: UUID] = [:]
    private var _processing: [String: UUID] = [:]
    private var _undecryptable: Set<String> = []

    private var lastPongAt: Date?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?

    private var registrations = 0
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedRegistrationIds: [String: String] = [:]
    private var holdGeneration = 0
    private var holdTimer: Task<Void, Never>?
    private var holdFollowUpTask: Task<Void, Never>?
    private var holdPollTask: Task<Void, Never>?
    private var holdFollowUpScheduleToken: UInt = 0
    private var holdPollScheduleToken: UInt = 0
    private var ackRetryTask: Task<Void, Never>?
    private var ackRetryScheduleToken: UInt = 0
    private var permissionSessionEpoch: UInt = 0
    private let permissionAccessGate = BoundedPermissionAccessGate()
    private var reregisterTask: Task<Void, Never>?
    private var webSocketTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var deliveryWorkTailsByKey: [DeliveryWorkKey: Task<Void, Never>] = [:]
    private var activeWebSocket: WebSocketConnection?
    var reconnectBackoffOverrideForTesting: TimeInterval?
    var permissionCheckTimeoutForTesting: TimeInterval?
    var holdForForTesting: TimeInterval?
    var holdIntervalForTesting: TimeInterval?
    var ackRetryDelayForTesting: TimeInterval?
    var ackRetryMaxAttemptsForTesting: Int?

    @discardableResult
    private func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
#if DEBUG
        let thread = pthread_mach_thread_np(pthread_self())
        precondition(lockOwnerThread != thread, "DesktopDeliveryService lock re-entrancy")
        lockOwnerThread = thread
        defer { lockOwnerThread = nil }
#endif
        return try block()
    }

    private func setStatus(state: DeliveryState, message: String? = nil) {
        withLock { _status = _status.replacing(state: state, message: message) }
    }

    /// Waits for a pong after sending ping. Non-pong frames are returned for processing after the handshake;
    /// they are not handled here so slow delivery work cannot extend the handshake deadline.
    static func performWebSocketHandshake(
        ws: WebSocketConnection,
        timeout: TimeInterval,
        isPong: (String) -> Bool
    ) async -> WebSocketHandshakeOutcome {
        var deferred: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        let sendBudget = deadline.timeIntervalSinceNow
        guard sendBudget > 0 else {
            return .failed(deferred: deferred, reason: .pongTimeout)
        }
        do {
            try await ws.sendPing(timeout: sendBudget)
        } catch let error as ApiError where error == ApiError.networkError("WebSocket send timeout") {
            return .failed(deferred: deferred, reason: .sendTimeout)
        } catch {
            return .failed(deferred: deferred, reason: .transport(error.localizedDescription))
        }

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let message: String
            do {
                message = try await ws.receiveMessage(timeout: remaining)
            } catch let error as ApiError where error == ApiError.networkError("WebSocket receive timeout") {
                break
            } catch {
                return .failed(deferred: deferred, reason: .transport(error.localizedDescription))
            }
            if isPong(message) { return .completed(deferred: deferred) }
            deferred.append(message)
        }
        return .failed(deferred: deferred, reason: .pongTimeout)
    }

    static func sendKeepAlivePing(
        ws: WebSocketConnection,
        timeout: TimeInterval = webSocketSendTimeout
    ) async throws {
        try await ws.sendPing(timeout: timeout)
    }

    public var status: DeliveryStatus {
        withLock { _status }
    }

    public var heldDeliveries: [HeldDelivery] {
        withLock { Array(_holding.values) }
    }

    public init(
        recordStore: RecordStore,
        apiClient: ApiClient,
        crypto: SodiumCrypto = .shared,
        notificationPresenter: NotificationPresenter = NotificationService.shared,
        notificationPermissions: NotificationPermissionsProtocol = NotificationPermissions.shared,
        holdInterval: TimeInterval = DesktopDeliveryService.holdRecheckInterval,
        presentationTimeout: TimeInterval = DesktopDeliveryService.showTimeout
    ) {
        self.recordStore = recordStore
        self.apiClient = apiClient
        self.crypto = crypto
        self.notificationPresenter = notificationPresenter
        self.notificationPermissions = notificationPermissions
        self.holdInterval = holdInterval
        self.presentationTimeout = presentationTimeout

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.reconnectAfterConnectivityRestored() }
        }
        monitor.start(queue: DispatchQueue(label: "xyz.vidur.pux.network"))
        self.pathMonitor = monitor

        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.reconnectAfterConnectivityRestored() }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.permissionAccessGate.setOnProbeFinishedWithNoWaiters { [weak self] session in
                Task { await self?.scheduleFlushAfterLateProbe(session: session) }
            }
        }
    }

    private func reconnectAfterConnectivityRestored() async {
        let stopped = withLock { _stopped }
        let session = withLock { _session }
        guard let recordId = try? recordStore.recordId(), !recordId.isEmpty, !stopped else { return }
        let state = withLock { _status.state }
        guard state == .ready || state == .retrying else { return }
        scheduleReconnect(recordId: recordId, error: nil, session: session)
    }

    public func startForTesting(session: Int = 1) {
        withLock {
            if _stopped {
                permissionSessionEpoch += 1
            }
            if _stopped || _session != session {
                _processing.removeAll()
            }
            _stopped = false
            _session = session
        }
        ensureHoldTimerRunning()
        scheduleAckRetry()
    }

    public func start() async {
        withLock { _stopped = true; _processing.removeAll() }
        stopTasks()

        let session = withLock { () -> Int in
            permissionSessionEpoch += 1
            _stopped = false
            _session += 1
            pruneDeliveryWorkTailMap(forSessionAtLeast: _session)
            _isReconnecting = false
            _status = _status.replacing(state: .connecting, message: nil)
            return _session
        }

        notifyStatusChange()

        // Restart hold timer immediately so existing held codes continue to be periodically
        // expired and flushed even during offline retry or outages.
        ensureHoldTimerRunning()

        guard let recordId = try? recordStore.recordId(), !recordId.isEmpty else {
            withLock { _status = _status.replacing(state: .idle, message: nil) }
            notifyStatusChange()
            return
        }

        // Acknowledgements that failed before a stop or restart must not wait for a
        // socket or registration that may never succeed; retry them in this session now.
        scheduleAckRetry()

        // 1. Initial Device Registration: The server creates pending deliveries only
        // when a registered device exists. A newly imported or restarted desktop must register
        // promptly; transient failures retry with short backoff rather than waiting 12 hours.
        var registered = false
        var regAttempt = 0
        while !registered && !Task.isCancelled && isCurrentSession(session) {
            do {
                let deviceToken = try recordStore.desktopDeviceId()
                let replaces = try recordStore.deviceId()
                guard beginRegistration(session) else { return }
                let newId: String?
                do {
                    newId = try await apiClient.registerDevice(recordId: recordId, pushToken: deviceToken, platform: "desktop", replacesDeviceId: replaces)
                } catch {
                    endRegistration(recordId: recordId, id: nil)
                    throw error
                }
                endRegistration(recordId: recordId, id: newId)
                guard !Task.isCancelled, isCurrentSession(session) else { return }
                try withLock {
                    guard !_stopped && _session == session else { return }
                    try recordStore.saveDeviceId(newId)
                }
                registered = true
            } catch let error as ApiError {
                guard !Task.isCancelled, isCurrentSession(session) else { return }
                if error == .recordNotFound || error == .tooManyDevices {
                    reportError(error, session: session)
                    return
                }
                regAttempt += 1
                let backoffSec = min(15.0, Double(regAttempt * 2))
                withLock {
                    _status = _status.replacing(state: .retrying, message: "Registering device: \(error.localizedDescription)")
                }
                notifyStatusChange()
                do { try await Task.sleep(nanoseconds: UInt64(backoffSec * 1_000_000_000)) } catch { return }
            } catch {
                guard !Task.isCancelled, isCurrentSession(session) else { return }
                regAttempt += 1
                let backoffSec = min(15.0, Double(regAttempt * 2))
                withLock {
                    _status = _status.replacing(state: .retrying, message: "Registering device...")
                }
                notifyStatusChange()
                do { try await Task.sleep(nanoseconds: UInt64(backoffSec * 1_000_000_000)) } catch { return }
            }
        }

        guard isCurrentSession(session) else { return }

        // 2. Connect WebSocket; poll offline deliveries without blocking socket setup.
        connectWebSocket(recordId: recordId, session: session)

        scheduleBackgroundPoll(recordId: recordId, session: session)

        // 5. Start periodic 12-hour re-registration
        startReregistration(recordId: recordId, session: session)
    }

    private func stopTasks() {
        pingTask?.cancel()
        pingTask = nil

        reregisterTask?.cancel()
        reregisterTask = nil

        reconnectTask?.cancel()
        reconnectTask = nil

        webSocketTask?.cancel()
        webSocketTask = nil

        withLock {
            _isReconnecting = false
            activeWebSocket?.disconnect()
            activeWebSocket = nil
        }
    }

    /// Stops background connection tasks. Preserves in-memory held deliveries.
    public func stop() {
        withLock {
            permissionSessionEpoch += 1
            _stopped = true
            _session += 1
            _processing.removeAll()
            pruneDeliveryWorkTailMap(forSessionAtLeast: _session)
            holdFollowUpScheduleToken += 1
            holdPollScheduleToken += 1
            ackRetryScheduleToken += 1
        }
        stopTasks()

        withLock {
            _attempt = 0
            _isReconnecting = false
            _status = _status.replacing(state: .idle, message: nil)
        }

        withLock {
            holdGeneration += 1
            holdTimer?.cancel()
            holdTimer = nil
            holdFollowUpTask?.cancel()
            holdFollowUpTask = nil
            holdPollTask?.cancel()
            holdPollTask = nil
            ackRetryTask?.cancel()
            ackRetryTask = nil
        }

        notifyStatusChange()
    }

    /// Explicitly resets and clears all held and delivery tracking state (on relay logout or deletion).
    public func clear() {
        stop()
        (notificationPresenter as? NotificationService)?.codes.clear()

        withLock {
            _holding.removeAll()
            _finished.removeAll()
            _pendingAcks.removeAll()
            _presenting.removeAll()
            _undecryptable.removeAll()
            _status = DeliveryStatus(state: .idle)
        }

        notifyHeldChange()
        notifyStatusChange()
    }

    private func isCurrentSession(_ session: Int) -> Bool {
        withLock { !_stopped && _session == session }
    }

    private func beginRegistration(_ session: Int) -> Bool {
        withLock {
            guard !_stopped && _session == session else { return false }
            registrations += 1
            return true
        }
    }

    private func endRegistration(recordId: String, id: String?) {
        let waiters = withLock { () -> [CheckedContinuation<Void, Never>] in
            if let id = id { completedRegistrationIds[recordId] = id }
            registrations -= 1
            guard registrations == 0 else { return [] }
            let result = registrationWaiters
            registrationWaiters.removeAll()
            return result
        }
        waiters.forEach { $0.resume() }
    }

    /// Stop new registrations and wait for any server request to finish before deletion.
    public func stopAndWaitForRegistration(recordId: String) async -> String? {
        stop()
        await withCheckedContinuation { continuation in
            let ready = withLock { () -> Bool in
                if registrations == 0 { return true }
                registrationWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return withLock { completedRegistrationIds.removeValue(forKey: recordId) }
    }

    // MARK: - Re-registration

    private func startReregistration(recordId: String, session: Int) {
        reregisterTask?.cancel()
        reregisterTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.reregistrationInterval * 1_000_000_000))
                } catch {
                    break
                }
                guard let self = self, !Task.isCancelled, self.isCurrentSession(session) else { break }

                do {
                    let deviceToken = try self.recordStore.desktopDeviceId()
                    let replaces = try self.recordStore.deviceId()
                    guard self.beginRegistration(session) else { break }
                    let newId: String?
                    do {
                        newId = try await self.apiClient.registerDevice(recordId: recordId, pushToken: deviceToken, platform: "desktop", replacesDeviceId: replaces)
                    } catch {
                        self.endRegistration(recordId: recordId, id: nil)
                        throw error
                    }
                    self.endRegistration(recordId: recordId, id: newId)
                    guard !Task.isCancelled, self.isCurrentSession(session) else { break }
                    try self.withLock {
                        guard !self._stopped && self._session == session else { return }
                        try self.recordStore.saveDeviceId(newId)
                    }
                } catch let error as ApiError {
                    guard !Task.isCancelled, self.isCurrentSession(session) else { break }
                    if error == .recordNotFound || error == .tooManyDevices {
                        self.reportError(error, session: session)
                        break
                    }
                } catch {
                    // Ignore transient error; next tick will retry
                }
            }
        }
    }

    // MARK: - Polling

    public func pollPending(recordId: String, session: Int) async throws {
        guard isCurrentSession(session) else { return }

        // Retry any previously failed acknowledgements
        await flushPendingAcks(recordId: recordId, session: session)

        // Capture candidate IDs from holding BEFORE initiating the network request,
        // so that any WebSocket delivery arriving and held while this poll is in flight
        // is NOT treated as absent and discarded during cleanup.
        let candidateIds = withLock { Set(_holding.keys) }

        let deliveries = try await apiClient.pollPending(recordId: recordId)
        guard isCurrentSession(session) else { return }

        let serverIds = Set(deliveries.map(\.deliveryId))

        // Flutter contract: Only when the returned page has fewer than ApiClient.pendingPageSize (50)
        // do we infer that all pending deliveries were returned. A full page (50) means newer deliveries
        // may exist on the server, so absence from serverIds does not prove deletion.
        if deliveries.count < ApiClient.pendingPageSize {
            let removed: [String] = withLock {
                let missing = candidateIds.subtracting(serverIds)
                for id in missing {
                    _holding.removeValue(forKey: id)
                    _finished.insert(id)
                }
                return Array(missing)
            }
            if !removed.isEmpty {
                notifyHeldChange()
            }
        }

        for delivery in deliveries {
            guard isCurrentSession(session) else { break }

            let (alreadyFinished, alreadyHeld) = withLock {
                (_finished.contains(delivery.deliveryId), _holding[delivery.deliveryId] != nil)
            }

            if alreadyFinished {
                // Already presented to the user; retry server acknowledgement if still pending
                let needsAck = withLock { _pendingAcks.contains(delivery.deliveryId) }
                if needsAck {
                    do {
                        try await apiClient.ackDelivery(recordId: recordId, deliveryId: delivery.deliveryId)
                        withLock { _pendingAcks.remove(delivery.deliveryId) }
                    } catch {
                        scheduleAckRetry()
                    }
                }
                continue
            }

            if alreadyHeld {
                continue
            }

            await handleEnvelope(
                deliveryId: delivery.deliveryId,
                envelope: delivery.envelope,
                session: session
            )
        }
    }

    // MARK: - WebSocket

    private func connectWebSocket(recordId: String, session: Int) {
        guard let wsUrl = apiClient.deliveryWebSocketUrl() else {
            reportError(ApiError.networkError("Invalid WebSocket URL"), session: session)
            return
        }

        webSocketTask?.cancel()
        webSocketTask = Task { [weak self] in
            guard let self = self, self.isCurrentSession(session) else { return }

            let ws = NativeWebSocketConnection(url: wsUrl, headers: ["x-pux-token": recordId])
            let installed = self.withLock { () -> Bool in
                guard !self._stopped, self._session == session else { return false }
                self.activeWebSocket = ws
                return true
            }
            guard installed else { return }
            ws.connect()

            lastPongAt = nil

            // Handshake verification: JSON ping until pong (matches Flutter and the server).
            let handshake = await Self.performWebSocketHandshake(
                ws: ws,
                timeout: Self.pongTimeout,
                isPong: { [weak self] message in
                    self?.consumePongIfPresent(message) ?? false
                }
            )

            switch handshake {
            case .failed(let deferred, let reason):
                self.scheduleDeferredHandshakeMessages(deferred, recordId: recordId, session: session)
                guard self.isCurrentSession(session) else { return }
                let error: Error
                switch reason {
                case .pongTimeout:
                    error = ApiError.networkError("WebSocket pong timeout")
                case .sendTimeout:
                    error = ApiError.networkError("WebSocket send timeout")
                case .transport(let message):
                    error = ApiError.networkError(message)
                }
                self.scheduleReconnect(recordId: recordId, error: error, session: session)
                return
            case .completed(let deferred):
                guard self.isCurrentSession(session) else { return }

                self.withLock {
                    self._status = self._status.replacing(state: .ready, message: nil)
                    self._attempt = 0
                    self._isReconnecting = false
                }
                self.notifyStatusChange()

                // Supervision before delivery work: keep-alive and receive are not blocked by handlers.
                self.startPingTimer(ws: ws, recordId: recordId, session: session)
                self.scheduleDeferredHandshakeMessages(deferred, recordId: recordId, session: session)

                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.pollPending(recordId: recordId, session: session)
                    } catch {
                        // Post-connect poll error is non-fatal; connection is already established
                    }
                }

                while self.isCurrentSession(session) {
                    do {
                        let msg = try await ws.receiveMessage()
                        self.routeWebSocketFrame(msg, recordId: recordId, session: session)
                    } catch {
                        guard self.isCurrentSession(session) else { break }
                        self.scheduleReconnect(recordId: recordId, error: error, session: session)
                        break
                    }
                }
                return
            }
        }
    }

    func startPingTimer(
        ws: WebSocketConnection,
        recordId: String,
        session: Int,
        interval: TimeInterval = pingInterval
    ) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard let self = self, !Task.isCancelled, self.isCurrentSession(session) else { break }
                if let last = self.lastPongAt,
                   Date().timeIntervalSince(last) > Self.pongTimeout {
                    self.scheduleReconnect(recordId: recordId, error: ApiError.networkError("WebSocket pong timeout"), session: session)
                    break
                }
                do {
                    try await Self.sendKeepAlivePing(ws: ws)
                } catch {
                    guard !Task.isCancelled, self.isCurrentSession(session) else { break }
                    self.scheduleReconnect(recordId: recordId, error: error, session: session)
                    break
                }
            }
        }
    }

    func processDeferredHandshakeMessages(
        _ messages: [String],
        recordId: String,
        session: Int
    ) {
        scheduleDeferredHandshakeMessages(messages, recordId: recordId, session: session)
    }

    func scheduleDeferredHandshakeMessages(
        _ messages: [String],
        recordId: String,
        session: Int
    ) {
        for message in messages {
            scheduleWebSocketDeliveryMessage(message, recordId: recordId, session: session)
        }
    }

    func routeWebSocketFrame(_ message: String, recordId: String, session: Int) {
        if consumePongIfPresent(message) { return }
        scheduleWebSocketDeliveryMessage(message, recordId: recordId, session: session)
    }

    func scheduleWebSocketDeliveryMessage(_ message: String, recordId: String, session: Int) {
        guard let deliveryId = Self.deliveryId(fromWebSocketMessage: message) else { return }
        enqueueDeliveryWork(deliveryId: deliveryId, session: session) { [weak self] in
            await self?.handleWebSocketDeliveryMessage(message, recordId: recordId, session: session)
        }
    }

    static func deliveryId(fromWebSocketMessage message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["type"] as? String == "envelope",
              let deliveryId = dict["delivery_id"] as? String else {
            return nil
        }
        return deliveryId
    }

    private func enqueueDeliveryWork(
        deliveryId: String,
        session: Int,
        work: @escaping @Sendable () async -> Void
    ) {
        let key = DeliveryWorkKey(session: session, deliveryId: deliveryId)
        let alreadyProcessing = withLock { _processing[deliveryId] != nil }
        if alreadyProcessing {
            Task { await work() }
            return
        }
        withLock {
            let prior = deliveryWorkTailsByKey[key]
            let task = Task { [weak self] in
                await prior?.value
                guard let self else { return }
                await work()
            }
            deliveryWorkTailsByKey[key] = task
        }
    }

    private var effectivePermissionCheckTimeout: TimeInterval {
        permissionCheckTimeoutForTesting ?? Self.permissionCheckTimeout
    }

    private var effectiveHoldFor: TimeInterval {
        holdForForTesting ?? Self.holdFor
    }

    @discardableResult
    private func purgeExpiredHeld(now: Date = Date()) -> [String] {
        withLock { () -> [String] in
            var expired: [String] = []
            for (id, delivery) in _holding where delivery.expiresAt < now {
                expired.append(id)
            }
            for id in expired {
                _holding.removeValue(forKey: id)
                _finished.insert(id)
            }
            return expired
        }
    }

    private func heldDeliveryIfUnexpired(_ deliveryId: String, now: Date = Date()) -> HeldDelivery? {
        withLock { () -> HeldDelivery? in
            guard let held = _holding[deliveryId] else { return nil }
            if held.expiresAt < now {
                _holding.removeValue(forKey: deliveryId)
                _finished.insert(deliveryId)
                return nil
            }
            return held
        }
    }

    private func permissionCheckContext(forExplicitSession session: Int?) -> (session: Int, epoch: UInt)? {
        withLock { () -> (Int, UInt)? in
            guard !_stopped else { return nil }
            let current = _session
            if let session, session != current { return nil }
            return (current, permissionSessionEpoch)
        }
    }

    private func checkNotificationAccess(session: Int? = nil) async -> NotificationAccess? {
        guard let context = permissionCheckContext(forExplicitSession: session) else { return nil }
        return await permissionAccessGate.check(
            permissions: notificationPermissions,
            timeout: effectivePermissionCheckTimeout,
            session: context.session,
            serviceEpoch: context.epoch
        )
    }

    private var effectiveHoldInterval: TimeInterval {
        holdIntervalForTesting ?? holdInterval
    }

    private func pruneDeliveryWorkTailMap(forSessionAtLeast session: Int) {
        deliveryWorkTailsByKey = deliveryWorkTailsByKey.filter { $0.key.session >= session }
    }

    func drainDeliveryWorkForTesting(session: Int? = nil) async {
        let tails = withLock { () -> [Task<Void, Never>] in
            if let session {
                return deliveryWorkTailsByKey.compactMap { $0.key.session == session ? $0.value : nil }
            }
            return Array(deliveryWorkTailsByKey.values)
        }
        for tail in tails {
            await tail.value
        }
    }

    func lastPongAtForTesting() -> Date? {
        lastPongAt
    }

    func lastPongAtForTestingSeed() {
        lastPongAt = Date()
    }

    func hasActiveWebSocketForTesting() -> Bool {
        withLock { activeWebSocket != nil }
    }

    private func handleWebSocketDeliveryMessage(_ message: String, recordId: String, session: Int) async {
        guard isCurrentSession(session) else { return }
        guard let data = message.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        guard dict["type"] as? String == "envelope",
              let deliveryId = dict["delivery_id"] as? String,
              let envelope = dict["envelope"] as? [String: Any] else {
            return
        }
        await handleEnvelope(deliveryId: deliveryId, envelope: envelope, session: session)
    }

    private func consumePongIfPresent(_ message: String) -> Bool {
        guard let data = message.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["type"] as? String == "pong" else { return false }
        lastPongAt = Date()
        return true
    }

    public func scheduleReconnect(recordId: String, error: Error?, session: Int) {
        let attempt = withLock { () -> Int in
            guard !_stopped && _session == session else { return 0 }
            if _isReconnecting {
                return 0 // Reconnect already in progress for this session
            }
            _isReconnecting = true
            _attempt += 1
            _status = _status.replacing(state: .retrying, message: error?.localizedDescription)
            return _attempt
        }
        guard attempt > 0 else { return }

        notifyStatusChange()

        pingTask?.cancel()
        pingTask = nil

        withLock {
            activeWebSocket?.disconnect()
            activeWebSocket = nil
        }

        let jitter = Double.random(in: 0 ..< 1.0)
        let backoffSeconds = reconnectBackoffOverrideForTesting
            ?? min(30.0, pow(2.0, Double(min(attempt, 6))) + jitter)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            } catch {
                return // Task cancelled
            }
            guard let self = self, !Task.isCancelled, self.isCurrentSession(session) else { return }

            self.withLock { self._isReconnecting = false }

            guard !Task.isCancelled, self.isCurrentSession(session) else { return }
            self.connectWebSocket(recordId: recordId, session: session)

            self.scheduleBackgroundPoll(recordId: recordId, session: session)
        }
    }

    private func scheduleBackgroundPoll(recordId: String, session: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.pollPending(recordId: recordId, session: session)
            } catch let error as ApiError where error == .recordNotFound {
                self.reportError(error, session: session)
            } catch {}
        }
    }

    func scheduleBackgroundPollForTesting(recordId: String, session: Int) {
        scheduleBackgroundPoll(recordId: recordId, session: session)
    }

    // MARK: - Handling Envelopes

    public func handleEnvelope(deliveryId: String, envelope: [String: Any], session: Int) async {
        let token = UUID()
        let reserved = withLock { () -> Bool in
            guard !_stopped, _session == session, !Task.isCancelled,
                  !_finished.contains(deliveryId), _holding[deliveryId] == nil,
                  _processing[deliveryId] == nil else { return false }
            _processing[deliveryId] = token
            return true
        }
        guard reserved else { return }

        if withLock({ _undecryptable.contains(deliveryId) }) {
            withLock {
                if _processing[deliveryId] == token { _processing.removeValue(forKey: deliveryId) }
            }
            return
        }

        defer {
            // A stopped session can have been replaced while this task was
            // suspended. Never release a newer handler's reservation.
            withLock {
                if _processing[deliveryId] == token { _processing.removeValue(forKey: deliveryId) }
            }
        }

        guard let notification = await decryptEnvelope(envelope) else {
            let updated = withLock { () -> Bool in
                guard !_stopped, _session == session, !Task.isCancelled,
                      _processing[deliveryId] == token else { return false }
                guard !_undecryptable.contains(deliveryId) else { return false }
                _undecryptable.insert(deliveryId)
                let currentUndecryptable = _status.undecryptable + 1
                _status = _status.replacing(undecryptable: currentUndecryptable)
                return true
            }
            if updated { notifyStatusChange() }
            return
        }

        guard let access = await checkNotificationAccess(session: session) else {
            guard isCurrentSession(session) else { return }
            guard holdDelivery(deliveryId: deliveryId, notification: notification, session: session, token: token) else { return }
            return
        }
        guard isCurrentSession(session) else { return }

        // Record the item before presentation so a timed-out or late completion
        // always has a held item to reconcile against.
        guard holdDelivery(deliveryId: deliveryId, notification: notification, session: session, token: token) else { return }
        guard !access.hidesCodes else { return }
        let shown = await tryShow(notification, deliveryId: deliveryId, session: session)
        guard isCurrentSession(session) else { return }
        if shown {
            let current = withLock { () -> Bool in
                guard !_stopped, _session == session, !Task.isCancelled,
                      _processing[deliveryId] == token, let held = _holding[deliveryId] else { return false }
                held.notified = true
                return true
            }
            if current { await acknowledgeDelivery(deliveryId: deliveryId, session: session) }
        }
    }

    private func decryptEnvelope(_ envelope: [String: Any]) async -> RelayNotification? {
        guard let ciphertext = envelope["ciphertext"] as? String,
              let pubKey = try? recordStore.publicKey(),
              let privKey = try? recordStore.privateKey() else {
            return nil
        }
        do {
            let payload = try crypto.openSealed(
                ciphertextB64: ciphertext,
                publicKeyB64: pubKey,
                privateKeyB64: privKey
            )
            return RelayNotification.fromPayload(payload)
        } catch {
            return nil
        }
    }

    private func tryShow(_ notification: RelayNotification, deliveryId: String, session: Int) async -> Bool {
        let token = UUID()
        let item = withLock { () -> HeldDelivery? in
            guard !_stopped, _session == session, let held = _holding[deliveryId],
                  _presenting[deliveryId] == nil else { return nil }
            _presenting[deliveryId] = token
            return held
        }
        guard let item = item else { return false }
        let presenter = notificationPresenter
        let timeout = presentationTimeout
        return await withCheckedContinuation { continuation in
            let race = PresentationRace(continuation)
            Task { [weak self] in
                let shown = (try? await presenter.show(notification: notification)) ?? false
                guard let self = self else { _ = race.resolve(shown); return }

                // A reconnect preserves both the held object and its presentation
                // owner. Clearing enrollment removes both; object identity prevents
                // an old completion from affecting a replacement with the same ID.
                var activeSession: Int?
                let finish = {
                    activeSession = self.withLock { () -> Int? in
                        guard self._presenting[deliveryId] == token,
                              self._holding[deliveryId] === item else { return nil }
                        self._presenting.removeValue(forKey: deliveryId)
                        guard shown else { return nil }
                        item.notified = true
                        return self._stopped ? nil : self._session
                    }
                }
                let won = race.resolve(shown, beforeResume: finish)
                if !won { finish() }
                if shown { self.notifyHeldChange() }
                // The original handler handles an on-time result in its own
                // session. Late results and results from a replaced session use
                // the current session and recheck notification permission.
                if let current = activeSession, !won || current != session {
                    await self.acknowledgeDelivery(deliveryId: deliveryId, session: current)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                race.resolve(false)
            }
        }
    }

    /// Re-evaluate held notifications after authorization or settings change.
    public func notificationAccessChanged() async {
        let session = withLock { _session }
        guard isCurrentSession(session) else { return }
        await flushHeld(session: session)
    }

    private func holdDelivery(deliveryId: String, notification: RelayNotification, session: Int, token: UUID) -> Bool {
        let held = withLock { () -> Bool in
            guard !_stopped, _session == session, !Task.isCancelled,
                  _processing[deliveryId] == token, !_finished.contains(deliveryId),
                  _holding[deliveryId] == nil else { return false }
            _holding[deliveryId] = HeldDelivery(
                deliveryId: deliveryId,
                notification: notification,
                expiresAt: Date().addingTimeInterval(effectiveHoldFor),
                notified: false
            )
            return true
        }
        if held {
            notifyHeldChange()
            ensureHoldTimerRunning()
        }
        return held
    }

    private func tickHoldExpiryFromTimer() {
        let expired = purgeExpiredHeld()
        if !expired.isEmpty {
            notifyHeldChange()
        }
    }

    private func scheduleHoldFollowUpIfNeeded() {
        withLock {
            guard !_holding.isEmpty, !_stopped else { return }
            guard holdFollowUpTask == nil else { return }
            holdFollowUpScheduleToken += 1
            let token = holdFollowUpScheduleToken
            let session = _session
            holdFollowUpTask = Task { [weak self, token] in
                guard let self else { return }
                defer {
                    self.withLock {
                        if self.holdFollowUpScheduleToken == token { self.holdFollowUpTask = nil }
                    }
                }
                guard self.isCurrentSession(session) else { return }
                await self.flushHeld(session: session)
            }
        }
    }

    private func scheduleHoldPollIfNeeded() {
        withLock {
            guard !_holding.isEmpty, !_stopped else { return }
            guard holdPollTask == nil else { return }
            holdPollScheduleToken += 1
            let token = holdPollScheduleToken
            let session = _session
            holdPollTask = Task { [weak self, token] in
                guard let self else { return }
                defer {
                    self.withLock {
                        if self.holdPollScheduleToken == token { self.holdPollTask = nil }
                    }
                }
                guard self.isCurrentSession(session) else { return }
                guard let recordId = try? self.recordStore.recordId() else { return }
                do {
                    try await self.pollPending(recordId: recordId, session: session)
                } catch let error as ApiError where error == .recordNotFound {
                    self.reportError(error, session: session)
                } catch {}
            }
        }
    }

    private func ensureHoldTimerRunning() {
        withLock {
            guard !_holding.isEmpty, !_stopped, holdTimer == nil else { return }
            holdGeneration += 1
            let generation = holdGeneration
            holdTimer = Task { [weak self] in
                while true {
                    let interval = self?.effectiveHoldInterval ?? Self.holdRecheckInterval
                    do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                    catch { break }
                    guard let self = self, !Task.isCancelled else { break }
                    let active = self.withLock { self.holdGeneration == generation && !self._holding.isEmpty && !self._stopped }
                    if !active { break }
                    self.tickHoldExpiryFromTimer()
                    self.scheduleHoldFollowUpIfNeeded()
                    self.scheduleHoldPollIfNeeded()
                }
                self?.withLock {
                    if self?.holdGeneration == generation { self?.holdTimer = nil }
                }
            }
        }
    }

    public func recheckHeld() async {
        let expired = purgeExpiredHeld()
        let (stillHolding, session) = withLock { (!_holding.isEmpty, _session) }

        if !expired.isEmpty {
            notifyHeldChange()
        }

        if !stillHolding { return }

        await flushHeld(session: session)

        if let recordId = try? recordStore.recordId() {
            do {
                try await pollPending(recordId: recordId, session: session)
            } catch let error as ApiError where error == .recordNotFound {
                reportError(error, session: session)
            } catch {}
        }
    }

    private enum FlushAdmission {
        case proceed
        case coalesced
        case deferred
    }

    private func admitFlush(session: Int) -> (FlushAdmission, UInt) {
        withLock { () -> (FlushAdmission, UInt) in
            let epoch = permissionSessionEpoch
            let current = _session
            if let active = flushActiveSession {
                if active == session {
                    flushCoalescedPending[session, default: 0] += 1
                    return (.coalesced, epoch)
                }
                if session == current, active != current {
                    flushActiveSession = session
                    flushActiveEpoch = epoch
                    return (.proceed, epoch)
                }
                flushDeferredSessions.insert(session)
                return (.deferred, epoch)
            }
            flushActiveSession = session
            flushActiveEpoch = epoch
            return (.proceed, epoch)
        }
    }

    private func stillOwnsFlush(session: Int, epoch: UInt) -> Bool {
        withLock { flushActiveSession == session && flushActiveEpoch == epoch && !_stopped }
    }

    private func endFlushOwnership(session: Int, epoch: UInt) -> [Int] {
        withLock { () -> [Int] in
            if flushActiveSession == session, flushActiveEpoch == epoch {
                flushActiveSession = nil
            }
            let deferred = Array(flushDeferredSessions)
            flushDeferredSessions.removeAll()
            return deferred
        }
    }

    private func scheduleDeferredFlush(session: Int) {
        Task { [weak self] in
            guard let self, self.isCurrentSession(session) else { return }
            await self.flushHeld(session: session)
        }
    }

    private func parkCoalescedFlushRetry(for session: Int) {
        withLock {
            let pending = flushCoalescedPending[session] ?? 0
            flushCoalescedHandled[session] = pending
        }
    }

    private func coalescedHandledGeneration(for session: Int) -> UInt {
        withLock { flushCoalescedHandled[session] ?? 0 }
    }

    private func coalescedPendingGeneration(for session: Int) -> UInt {
        withLock { flushCoalescedPending[session] ?? 0 }
    }

    private func hasCoalescedFlushRetry(for session: Int) -> Bool {
        withLock {
            (flushCoalescedPending[session] ?? 0) > (flushCoalescedHandled[session] ?? 0)
        }
    }

    private func consumeCoalescedThrough(session: Int, generation: UInt) {
        withLock {
            let handled = flushCoalescedHandled[session] ?? 0
            if generation > handled {
                flushCoalescedHandled[session] = generation
            }
        }
    }

    private func hasUnexpiredHeldWork() -> Bool {
        let now = Date()
        return withLock { _holding.values.contains { $0.expiresAt >= now } }
    }

    private func flushRepeatAfterCoalescedRequest(for session: Int) async -> Bool {
        guard hasCoalescedFlushRetry(for: session) else { return false }
        await permissionAccessGate.abandonIncompleteProbeForRetry()
        return true
    }

    private func scheduleFlushAfterLateProbe(session: Int) async {
        guard hasCoalescedFlushRetry(for: session) else { return }
        guard isCurrentSession(session) else { return }
        scheduleDeferredFlush(session: session)
    }

    public func flushHeld(session: Int) async {
        let (admission, startedEpoch) = admitFlush(session: session)
        switch admission {
        case .coalesced, .deferred:
            return
        case .proceed:
            break
        }

        await performFlushHeld(session: session, startedEpoch: startedEpoch)

        let deferred = endFlushOwnership(session: session, epoch: startedEpoch)
        for pending in deferred {
            scheduleDeferredFlush(session: pending)
        }
        if hasCoalescedFlushRetry(for: session), hasUnexpiredHeldWork() {
            if await !permissionAccessGate.hasIncompleteProbe(for: session) {
                scheduleDeferredFlush(session: session)
            }
        } else if hasCoalescedFlushRetry(for: session) {
            parkCoalescedFlushRetry(for: session)
        }
    }

    private func performFlushHeld(session: Int, startedEpoch: UInt) async {
        var coalescedPassCount = 0
        flushLoop: while true {
            var expired = purgeExpiredHeld()
            let handledCoalescedAtStart = coalescedHandledGeneration(for: session)
            let list = withLock { Array(_holding.values) }
            if list.isEmpty {
                if !expired.isEmpty { notifyHeldChange() }
                parkCoalescedFlushRetry(for: session)
                break flushLoop
            }

            guard let access = await checkNotificationAccess(session: session) else {
                if !expired.isEmpty { notifyHeldChange() }
                break flushLoop
            }
            let coalescedPendingAfterCheck = coalescedPendingGeneration(for: session)
            guard stillOwnsFlush(session: session, epoch: startedEpoch) else { return }
            guard isCurrentSession(session) else { return }

            for delivery in list {
                guard let live = heldDeliveryIfUnexpired(delivery.deliveryId) else {
                    expired.append(delivery.deliveryId)
                    continue
                }

                if access.hidesCodes {
                    live.notified = false
                    continue
                }

                if !live.notified {
                    let shown = await tryShow(live.notification, deliveryId: live.deliveryId, session: session)
                    guard stillOwnsFlush(session: session, epoch: startedEpoch) else { return }
                    guard isCurrentSession(session) else { return }
                    if shown { withLock { _holding[live.deliveryId]?.notified = true } }
                }

                guard heldDeliveryIfUnexpired(live.deliveryId) != nil else {
                    expired.append(live.deliveryId)
                    continue
                }

                let shouldAck = withLock { _holding[live.deliveryId]?.notified == true }
                if shouldAck {
                    await acknowledgeDelivery(deliveryId: live.deliveryId, session: session)
                    guard stillOwnsFlush(session: session, epoch: startedEpoch) else { return }
                }
            }

            if !expired.isEmpty {
                notifyHeldChange()
            }
            if coalescedPendingAfterCheck > handledCoalescedAtStart {
                consumeCoalescedThrough(session: session, generation: coalescedPendingAfterCheck)
            }
            guard hasCoalescedFlushRetry(for: session) else { break flushLoop }
            coalescedPassCount += 1
            if coalescedPassCount > 8 {
                parkCoalescedFlushRetry(for: session)
                break flushLoop
            }
            guard await flushRepeatAfterCoalescedRequest(for: session) else { break flushLoop }
        }
    }

    private func acknowledgeDelivery(deliveryId: String, session: Int) async {
        // Presentation and permission checks suspend independently. Re-read the
        // current setting at the shared acknowledgement boundary, including for
        // late completions and deliveries that were already shown quietly.
        guard let access = await checkNotificationAccess(session: session) else {
            return
        }
        let accepted = withLock { () -> Bool in
            guard !_stopped, _session == session, let held = _holding[deliveryId],
                  held.expiresAt >= Date(), !_finished.contains(deliveryId) else { return false }
            guard access == .allowed else {
                held.notified = !access.hidesCodes
                return false
            }
            _holding.removeValue(forKey: deliveryId)
            _finished.insert(deliveryId)
            _pendingAcks.insert(deliveryId)
            return true
        }
        notifyHeldChange()
        guard accepted else { return }


        guard let recordId = try? recordStore.recordId(), !recordId.isEmpty else {
            scheduleAckRetry()
            return
        }
        do {
            try await apiClient.ackDelivery(recordId: recordId, deliveryId: deliveryId)
            withLock {
                _pendingAcks.remove(deliveryId)
            }
        } catch {
            // The delivery is already presented and out of `_holding`, so neither the hold
            // timer nor a poll is guaranteed to run again. Retry on our own, bounded.
            scheduleAckRetry()
        }
    }

    /// Attempts every pending acknowledgement once, stopping as soon as the session ends.
    private func attemptPendingAcks(recordId: String, session: Int) async {
        let toAck = withLock { Array(_pendingAcks) }
        for id in toAck {
            guard !Task.isCancelled, isCurrentSession(session) else { return }
            do {
                try await apiClient.ackDelivery(recordId: recordId, deliveryId: id)
                withLock {
                    _pendingAcks.remove(id)
                }
            } catch {
                // Remains in pendingAcks for the next attempt
            }
        }
    }

    private func flushPendingAcks(recordId: String, session: Int) async {
        await attemptPendingAcks(recordId: recordId, session: session)
        let stillPending = withLock { !_pendingAcks.isEmpty }
        if stillPending, isCurrentSession(session) { scheduleAckRetry() }
    }

    func ackRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        let maxAttempts = ackRetryMaxAttemptsForTesting ?? Self.ackRetryMaxAttempts
        guard attempt < maxAttempts else { return nil }
        if let fixed = ackRetryDelayForTesting { return fixed }
        return min(Self.ackRetryMaxDelay, Self.ackRetryInitialDelay * pow(2.0, Double(attempt)))
    }

    /// Starts a fresh bounded retry series for the current session, replacing any earlier
    /// one so a new failure restarts the backoff. Does nothing while stopped or with nothing
    /// pending. `stop()` (which `clear()` and removal also run) cancels the task, and a
    /// replaced or cancelled task cannot release or affect its successor's slot.
    private func scheduleAckRetry() {
        withLock {
            guard !_stopped, !_pendingAcks.isEmpty else { return }
            ackRetryTask?.cancel()
            ackRetryScheduleToken += 1
            let token = ackRetryScheduleToken
            let session = _session
            ackRetryTask = Task { [weak self, token] in
                var attempt = 0
                while true {
                    // Do not retain the service while sleeping between rounds.
                    guard let delay = self?.ackRetryDelay(forAttempt: attempt) else { break }
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
                    catch { break }
                    guard let self, !Task.isCancelled else { break }
                    attempt += 1
                    guard await self.runAckRetryRound(session: session) else { break }
                }
                self?.withLock {
                    if self?.ackRetryScheduleToken == token { self?.ackRetryTask = nil }
                }
            }
        }
    }

    /// One retry round. Returns whether another round should follow.
    private func runAckRetryRound(session: Int) async -> Bool {
        guard !Task.isCancelled, isCurrentSession(session),
              withLock({ !_pendingAcks.isEmpty }) else { return false }
        // A transient storage read failure is retried like a failed request.
        if let recordId = try? recordStore.recordId(), !recordId.isEmpty {
            await attemptPendingAcks(recordId: recordId, session: session)
        }
        guard !Task.isCancelled, isCurrentSession(session) else { return false }
        return withLock { !_pendingAcks.isEmpty }
    }

    private func reportError(_ error: ApiError, session: Int) {
        let applied = withLock { () -> Bool in
            guard !_stopped, _session == session else { return false }
            switch error {
            case .recordNotFound:
                _status = _status.replacing(state: .recordUnknown, message: nil)
            case .tooManyDevices:
                _status = _status.replacing(state: .tooManyDevices, message: nil)
            default:
                _status = _status.replacing(state: .retrying, message: error.localizedDescription)
            }
            return true
        }
        if applied {
            notifyStatusChange()
        }
    }

    func deliveryStatusForTesting() -> DeliveryStatus {
        status
    }

    func pendingAckIdsForTesting() -> Set<String> {
        withLock { _pendingAcks }
    }

    func hasAckRetryTaskForTesting() -> Bool {
        withLock { ackRetryTask != nil }
    }

    func pendingPermissionWaiterCountForTesting() async -> Int {
        await permissionAccessGate.pendingWaiterCountForTesting()
    }

    func checkNotificationAccessForTesting(timeout: TimeInterval? = nil, session: Int? = nil) async -> NotificationAccess? {
        guard let context = permissionCheckContext(forExplicitSession: session) else { return nil }
        let deadline = timeout ?? effectivePermissionCheckTimeout
        return await permissionAccessGate.check(
            permissions: notificationPermissions,
            timeout: deadline,
            session: context.session,
            serviceEpoch: context.epoch
        )
    }

    func setHeldExpiryForTesting(deliveryId: String, expiresAt: Date) {
        withLock { _holding[deliveryId]?.expiresAt = expiresAt }
    }

    func markReadyForTesting(session: Int) {
        withLock {
            guard _session == session, !_stopped else { return }
            _status = _status.replacing(state: .ready, message: nil)
        }
        notifyStatusChange()
    }

    private func notifyStatusChange() {
        let s = self.status
        Task { @MainActor in
            self.delegate?.deliveryService(self, didUpdateStatus: s)
        }
    }

    private func notifyHeldChange() {
        let h = self.heldDeliveries
        Task { @MainActor in
            self.delegate?.deliveryService(self, didUpdateHeldDeliveries: h)
        }
    }
}
