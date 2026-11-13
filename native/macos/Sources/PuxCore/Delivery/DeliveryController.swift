import Foundation
import Combine

@MainActor
public final class DeliveryController: ObservableObject, DesktopDeliveryServiceDelegate {
    public static let shared = DeliveryController()

    @Published public private(set) var isEnrolled: Bool = false
    @Published public private(set) var currentInbox: String? = nil
    @Published public private(set) var status: DeliveryStatus = DeliveryStatus(state: .idle)
    @Published public private(set) var heldDeliveries: [HeldDelivery] = []
    @Published public private(set) var serverHealth: ServerHealth = ServerHealth(state: .checking)
    @Published public private(set) var storageError: String? = nil
    @Published public private(set) var notificationAccess: NotificationAccess = .notAsked
    @Published public private(set) var requestingNotifications = false

    @Published public private(set) var pendingRemoval: PendingRemoval? = nil
    @Published public private(set) var removing = false

    public let recordStore: RecordStore
    public let apiClient: ApiClient
    public let deliveryService: DesktopDeliveryService
    private let notificationPermissions: NotificationPermissionsProtocol
    private var preservingUnknownRelayRecovery = false

    public init(
        recordStore: RecordStore = RecordStore(),
        apiClient: ApiClient? = nil,
        service: DesktopDeliveryService? = nil,
        notificationPermissions: NotificationPermissionsProtocol = NotificationPermissions.shared
    ) {
        self.recordStore = recordStore
        self.notificationPermissions = notificationPermissions
        let client = apiClient ?? ApiClient(recordStore: recordStore)
        self.apiClient = client
        let s = service ?? DesktopDeliveryService(recordStore: recordStore, apiClient: client, notificationPermissions: notificationPermissions)
        self.deliveryService = s
        s.delegate = self
    }

    public func initialize() async {
        Task { await checkHealth() }
        do {
            try await recordStore.initialize()
            try await refreshEnrollmentState()
            if isEnrolled {
                await start()
            }
        } catch {
            storageError = error.localizedDescription
            isEnrolled = false
            currentInbox = nil
        }
    }

    public func refreshEnrollmentState() async throws {
        do {
            pendingRemoval = try recordStore.pendingRemoval()
            isEnrolled = try await recordStore.isEnrolled()
            currentInbox = try recordStore.inbox()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            isEnrolled = false
            currentInbox = nil
            throw error
        }
    }

    public func start() async {
        guard !removing, pendingRemoval == nil else { return }
        do {
            try await refreshEnrollmentState()
        } catch {
            return
        }
        guard isEnrolled, !removing, pendingRemoval == nil else { return }
        Task { await checkHealth() }
        await deliveryService.start()
    }

    public func stop() {
        deliveryService.stop()
    }

    public func checkHealth(userAsked: Bool = false) async {
        serverHealth = ServerHealth(state: .checking)
        let health = await apiClient.checkHealth()
        self.serverHealth = health

        if userAsked && health.state == .reachable && status.state == .retrying {
            await start()
        }
    }

    public func refreshNotificationAccess() async {
        notificationAccess = await notificationPermissions.check()
        await deliveryService.notificationAccessChanged()
    }

    public func requestNotificationAccess() async {
        guard !requestingNotifications else { return }
        requestingNotifications = true
        notificationAccess = await notificationPermissions.ask()
        requestingNotifications = false
        await deliveryService.notificationAccessChanged()
    }

    public func commitEnrollment(_ payload: EnrollmentPayload) async throws {
        guard !removing, try recordStore.pendingRemoval() == nil else { throw ApiError.networkError("Finish the pending removal before enrolling") }
        try recordStore.saveEnrollment(payload)
        try await refreshEnrollmentState()
        Task {
            await self.start()
        }
    }

    /// Persist the intent before stopping delivery or making a server request. If
    /// any operation is uncertain, startup stays blocked until this is retried.
    private func beginRemoval(_ requested: PendingRemoval) throws {
        guard !removing else { throw ApiError.networkError("Removal is already in progress") }
        let existing = try recordStore.pendingRemoval()
        let compatible = existing == nil || existing == requested ||
            (requested == .deviceReconciling && (existing == .deviceDeleting || existing == .deviceLimit))
        guard compatible else { throw ApiError.networkError("Finish the pending removal first") }
        if existing == nil { try recordStore.savePendingRemoval(requested) }
        pendingRemoval = existing ?? requested
        removing = true
    }

    public func removeThisDevice() async throws {
        guard let recordId = try recordStore.recordId() else {
            throw ApiError.incompleteResponse("Cannot finish removal without the relay ID")
        }
        try beginRemoval(.deviceReconciling)
        defer { removing = false }
        _ = await deliveryService.stopAndWaitForRegistration(recordId: recordId)

        if pendingRemoval == .deviceLimit {
            // Once a retry starts, its outcome can again become uncertain.
            try recordStore.savePendingRemoval(.deviceReconciling)
            pendingRemoval = .deviceReconciling
        }

        if pendingRemoval == .deviceReconciling {
            // Registration is an upsert by record and stable desktop token. A
            // response lost after commit is reconciled by repeating the upsert.
            let token = try recordStore.desktopDeviceId()
            do {
                guard let id = try await apiClient.registerDevice(recordId: recordId, pushToken: token), !id.isEmpty else {
                    throw ApiError.incompleteResponse("Device registration returned no device ID")
                }
                try recordStore.saveDeviceId(id)
                try recordStore.savePendingRemoval(.deviceDeleting)
                pendingRemoval = .deviceDeleting
            } catch ApiError.tooManyDevices {
                // This response rejected the upsert. Persist this distinct state
                // so the user can choose a local-only recovery after restart.
                try recordStore.savePendingRemoval(.deviceLimit)
                pendingRemoval = .deviceLimit
                throw ApiError.tooManyDevices
            } catch ApiError.recordNotFound {
                // The relay is already gone, so it cannot retain this device.
                deliveryService.clear()
                try recordStore.clear()
                try await refreshEnrollmentState()
                return
            }
        }

        guard let deviceId = try recordStore.deviceId(), !deviceId.isEmpty else {
            throw ApiError.incompleteResponse("Cannot finish device removal without its ID")
        }
        // A retry in the deleting phase repeats DELETE, never registration.
        try await apiClient.deleteDevice(recordId: recordId, deviceId: deviceId)
        deliveryService.clear()
        try recordStore.clear()
        try await refreshEnrollmentState()
    }

    /// Explicit local-only recovery after a device-limit rejection. The caller
    /// must explain that server-side absence cannot be guaranteed.
    public func forgetThisMacAfterDeviceLimit() async throws {
        guard !removing else { throw ApiError.networkError("Removal is already in progress") }
        guard try recordStore.pendingRemoval() == .deviceLimit else {
            throw ApiError.networkError("Local-only recovery is unavailable for an uncertain removal")
        }
        removing = true
        defer { removing = false }
        deliveryService.clear()
        try recordStore.clear()
        try await refreshEnrollmentState()
    }

    /// Abandon a persisted removal intent and resume delivery.
    public func cancelPendingRemoval() async throws {
        guard !removing else { throw ApiError.networkError("Removal is already in progress") }
        try recordStore.clearPendingRemoval()
        pendingRemoval = nil
        await start()
    }

    /// Local-only forget after a failed removal attempt (server state may differ).
    public func forgetLocallyAfterFailedRemoval() async throws {
        removing = true
        defer { removing = false }
        deliveryService.clear()
        try recordStore.clear()
        pendingRemoval = nil
        try await refreshEnrollmentState()
    }

    /// Forget a relay the server no longer recognizes (record unknown).
    public func forgetUnknownRelayLocally() async throws {
        removing = true
        defer { removing = false }
        preservingUnknownRelayRecovery = true
        deliveryService.stop()
        do {
            try recordStore.clear()
            deliveryService.clear()
            pendingRemoval = nil
            try await refreshEnrollmentState()
            preservingUnknownRelayRecovery = false
        } catch {
            storageError = error.localizedDescription
            status = DeliveryStatus(state: .recordUnknown)
            throw error
        }
    }

    public func deleteRelayEverywhere() async throws {
        guard let recordId = try recordStore.recordId() else {
            throw ApiError.incompleteResponse("Cannot finish removal without the relay ID")
        }
        try beginRemoval(.relay)
        defer { removing = false }
        _ = await deliveryService.stopAndWaitForRegistration(recordId: recordId)
        try await apiClient.deleteRecord(recordId: recordId)
        deliveryService.clear()
        try recordStore.clear()
        try await refreshEnrollmentState()
    }

    public func sendTestCode() async throws -> TestCodeResponse {
        guard let recordId = try recordStore.recordId() else {
            throw ApiError.recordNotFound
        }
        return try await apiClient.sendTestCode(recordId: recordId)
    }

    // MARK: - DesktopDeliveryServiceDelegate

    public func deliveryService(_ service: DesktopDeliveryService, didUpdateStatus status: DeliveryStatus) {
        if preservingUnknownRelayRecovery && status.state == .idle { return }
        self.status = status
    }

    public func deliveryService(_ service: DesktopDeliveryService, didUpdateHeldDeliveries held: [HeldDelivery]) {
        self.heldDeliveries = held
    }
}
