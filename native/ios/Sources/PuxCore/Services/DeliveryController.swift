import Foundation
import Combine

public protocol DeliveryServiceProtocol: AnyObject, Sendable {
    func start() async throws
    func stop() async
}

@MainActor
public final class DeliveryController: ObservableObject {
    public static let shared = DeliveryController()

    nonisolated public static let minBackoff: TimeInterval = 2.0
    nonisolated public static let maxBackoff: TimeInterval = 300.0 // 5 minutes
    nonisolated public static let rateLimitedAttempt: Int = 4 // ~30s
    nonisolated public static let refreshInterval: TimeInterval = 12 * 3600 // 12 hours

    @Published public private(set) var status: DeliveryStatus = DeliveryStatus(state: .idle)

    public var deliveryService: DeliveryServiceProtocol?
    private let recordStore: RecordStore

    private var retryTask: Task<Void, Never>?
    private var attempt: Int = 0
    private var isRunning: Bool = false
    private var runningWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastRegistered: Date?
    private var generation = 0
    private var removalSuspended = false

    public init(
        recordStore: RecordStore = .shared,
        deliveryService: DeliveryServiceProtocol? = nil
    ) {
        self.recordStore = recordStore
        if let ds = deliveryService {
            self.deliveryService = ds
        } else {
            self.deliveryService = FcmRegistration(
                recordStore: recordStore,
                onRefreshError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.reportError(error)
                    }
                }
            )
        }
    }

    public func start() async {
        guard !removalSuspended, (try? recordStore.removalIntent() == nil) == true else { return }
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        await tryStart()
    }

    public func onResume() async {
        guard !removalSuspended, (try? recordStore.removalIntent() == nil) == true else { return }
        let now = Date()
        let isStale = lastRegistered.map { now.timeIntervalSince($0) > Self.refreshInterval } ?? true
        let state = status.state
        if isStale || state == .retrying || state == .tooManyDevices || state == .idle {
            await start()
        }
    }

    public func stop() async {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        if let service = deliveryService {
            await service.stop()
        }
        if isRunning {
            await withCheckedContinuation { runningWaiters.append($0) }
        }
        status = DeliveryStatus(state: .idle)
    }

    /// Prevent lifecycle callbacks from restarting delivery until removal is resolved.
    public func beginRemoval() async {
        removalSuspended = true
        await stop()
    }

    public func prepareRemoval(_ intent: RemovalIntent) async throws {
        removalSuspended = true
        do {
            try recordStore.saveRemovalIntent(intent)
        } catch {
            // A failed journal must still stop and drain an active service.
            await stop()
            throw error
        }
        await stop()
    }

    public func endRemoval(resume: Bool) async throws {
        try recordStore.clearRemovalIntent()
        removalSuspended = false
        if resume { await start() }
    }

    public func finishRemovalLocally() async throws {
        try await prepareRemoval(.local)
        try recordStore.clear()
        try await endRemoval(resume: false)
    }

    public func recoverRemoval(_ intent: RemovalIntent, apiClient: ApiClient = .shared) async throws {
        switch intent {
        case .device:
            try await removeDevice(apiClient: apiClient)
        case .relay:
            try await prepareRemoval(.relay)
            guard let id = recordStore.recordId() else {
                throw PuxError.serverError(statusCode: 0, message: "The relay ID is unavailable.")
            }
            try await apiClient.deleteRecord(recordId: id)
        case .local:
            break
        }
        try await finishRemovalLocally()
    }

    /// Replays an uncertain registration before reading its server-assigned ID.
    public func removeDevice(apiClient: ApiClient = .shared) async throws {
        try await prepareRemoval(.device)
        guard let recordId = recordStore.recordId() else {
            throw PuxError.serverError(statusCode: 0, message: "The relay ID is unavailable.")
        }
        let knownDeviceId = recordStore.deviceId()
        if knownDeviceId == nil, let token = recordStore.pendingRegistration() {
            let id = try await apiClient.registerDevice(
                recordId: recordId, pushToken: token, replacesDeviceId: nil
            )
            try recordStore.saveDeviceId(id)
            try recordStore.clearPendingRegistration()
        } else if knownDeviceId != nil, recordStore.pendingRegistration() != nil {
            var journalRecorded = false
            var journalUnreadableDuringRecord = false
            do {
                try recordStore.recordUncertainRegistrationForRemoval()
                journalRecorded = true
            } catch {
                if Self.isUncertainJournalReadFailure(error) {
                    journalUnreadableDuringRecord = true
                }
            }
            if journalRecorded {
                try? recordStore.clearPendingRegistration()
            }
            guard let deviceId = recordStore.deviceId(), !deviceId.isEmpty else {
                throw PuxError.serverError(statusCode: 0, message: "This device's server registration cannot be identified. It may still be active on the server.")
            }
            try await apiClient.deleteDevice(recordId: recordId, deviceId: deviceId)
            if journalUnreadableDuringRecord {
                throw Self.unresolvedUncertainRegistrationWarningError()
            }
            if journalRecorded {
                do {
                    try recordStore.markUncertainRegistrationRemovalServerComplete()
                } catch {
                    if Self.isUncertainJournalReadFailure(error) { throw error }
                    throw PuxError.serverError(
                        statusCode: 0,
                        message: "This device was removed from the server, but the stale-registration reminder could not be finalized."
                    )
                }
            } else {
                throw PuxError.serverError(
                    statusCode: 0,
                    message: "This device was removed from the server, but a reminder about a stale registration could not be saved. The pending registration marker was kept until a retry."
                )
            }
            return
        }
        guard let deviceId = recordStore.deviceId(), !deviceId.isEmpty else {
            throw PuxError.serverError(statusCode: 0, message: "This device's server registration cannot be identified. It may still be active on the server.")
        }
        try await apiClient.deleteDevice(recordId: recordId, deviceId: deviceId)
        let shouldFinalize: Bool
        do {
            shouldFinalize = try recordStore.uncertainRegistrationRemovalWarningPhase() == .recorded
        } catch {
            if Self.isUncertainJournalReadFailure(error) {
                throw Self.unresolvedUncertainRegistrationWarningError()
            }
            throw error
        }
        if shouldFinalize {
            do {
                try recordStore.markUncertainRegistrationRemovalServerComplete()
            } catch {
                if Self.isUncertainJournalReadFailure(error) { throw error }
                throw PuxError.serverError(
                    statusCode: 0,
                    message: "This device was removed from the server, but the stale-registration reminder could not be finalized."
                )
            }
        }
    }

    private static func isUncertainJournalReadFailure(_ error: Error) -> Bool {
        guard let err = error as? PuxError,
              case .serverError(_, let message) = err else { return false }
        return message.contains("read failure") || message.contains("Cannot read uncertain-registration")
    }

    private static func unresolvedUncertainRegistrationWarningError() -> PuxError {
        PuxError.serverError(
            statusCode: 0,
            message: "This device was removed from the server, but the stale-registration reminder could not be read or updated. Retry when secure storage is available."
        )
    }

    public func handleApnsToken(_ token: Data) async {
        if let fcm = deliveryService as? FcmRegistration {
            await fcm.handleApnsToken(token)
        }
    }

    public func handleFIDUpdate(_ fid: String) async {
        if let fcm = deliveryService as? FcmRegistration {
            await fcm.handleFIDUpdate(fid)
        }
    }

    public func reportReady() {
        status = status.copyWith(state: .ready)
    }

    public func reportError(_ error: Error) {
        guard !removalSuspended, (try? recordStore.removalIntent() == nil) == true else { return }
        if let puxErr = error as? PuxError {
            switch puxErr {
            case .recordNotFound:
                status = status.copyWith(state: .recordUnknown, message: puxErr.localizedDescription)
                Task { [weak self] in await self?.deliveryService?.stop() }
                return
            case .tooManyDevices:
                status = status.copyWith(state: .tooManyDevices, message: puxErr.localizedDescription)
                return
            default:
                break
            }
        }
        retryTask?.cancel()
        scheduleRetry(isRateLimited: (error as? PuxError) == .rateLimited, error: error)
    }

    public func reportUndecryptable() {
        status = status.copyWith(
            state: status.state,
            message: status.message,
            undecryptable: status.undecryptable + 1
        )
    }

    private func tryStart() async {
        guard !removalSuspended, (try? recordStore.removalIntent() == nil) == true else { return }
        if isRunning { return }
        recordStore.refreshFromStorage()
        if !recordStore.isEnrolled() {
            status = DeliveryStatus(state: .idle)
            return
        }

        isRunning = true
        let currentGeneration = generation
        defer {
            isRunning = false
            let waiters = runningWaiters
            runningWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        status = status.copyWith(state: .connecting)

        do {
            guard let service = deliveryService else {
                throw PuxError.firebaseNotConfigured
            }
            try await service.start()
            guard generation == currentGeneration else { return }
            lastRegistered = Date()
            attempt = 0
            status = status.copyWith(state: .ready)
        } catch let puxErr as PuxError {
            guard generation == currentGeneration else { return }
            switch puxErr {
            case .firebaseNotConfigured:
                status = status.copyWith(
                    state: .firebaseUnconfigured,
                    message: "Push notifications are not configured in this build."
                )
            case .recordNotFound:
                status = status.copyWith(state: .recordUnknown, message: puxErr.localizedDescription)
            case .tooManyDevices:
                status = status.copyWith(state: .tooManyDevices, message: puxErr.localizedDescription)
            case .rateLimited:
                scheduleRetry(isRateLimited: true, error: puxErr)
            default:
                scheduleRetry(isRateLimited: false, error: puxErr)
            }
        } catch {
            guard generation == currentGeneration else { return }
            scheduleRetry(isRateLimited: false, error: error)
        }
    }

    private func scheduleRetry(isRateLimited: Bool, error: Error) {
        let currentAttempt = attempt
        attempt += 1
        let effectiveAttempt = isRateLimited ? max(currentAttempt, Self.rateLimitedAttempt) : currentAttempt
        let delay = Self.calculateBackoff(attempt: effectiveAttempt)
        status = status.copyWith(
            state: .retrying,
            message: "\(error.localizedDescription) (retrying in \(Int(delay))s)"
        )

        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled {
                await self?.tryStart()
            }
        }
    }

    nonisolated public static func calculateBackoff(attempt: Int, randomFraction: Double = 1.0) -> TimeInterval {
        let base = minBackoff * pow(2.0, Double(min(attempt, 16)))
        let capped = min(base, maxBackoff)
        let jitter = (capped / 4.0) * randomFraction
        return capped + jitter
    }
}
