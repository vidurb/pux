import Foundation

public enum PendingRemoval: String, Sendable {
    case deviceReconciling
    case deviceLimit
    case deviceDeleting
    case relay
}

public final class RecordStore: @unchecked Sendable {
    public static let defaultServer = "https://pux.vidur.xyz"

    public static let recordIdKey = "record_id"
    public static let privateKeyKey = "private_key"
    public static let publicKeyKey = "public_key"
    public static let inboxKey = "inbox"
    public static let serverKey = "server_url"
    public static let desktopDeviceIdKey = "desktop_device_id"
    public static let deviceIdKey = "device_id"
    public static let pendingRemovalKey = "native_macos_pending_removal"
    public static let dismissedRestrictionPromptsKey = "dismissed_restriction_prompts"
    public static let notificationPermissionAskedKey = "notification_permission_asked"
    public static let notificationExplainerSkippedKey = "notification_explainer_skipped"

    private let storage: SecureStorage
    private let lock = NSLock()

    private var _defaultServerUrl: String
    private var _serverUrl: String

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    public var serverUrl: String {
        withLock { _serverUrl }
    }

    public var defaultServerUrl: String {
        withLock { _defaultServerUrl }
    }

    public init(storage: SecureStorage = KeychainStorage.shared, defaultServerUrl: String = RecordStore.defaultServer) {
        self.storage = storage
        self._defaultServerUrl = defaultServerUrl
        if let stored = try? storage.read(key: Self.serverKey), !stored.isEmpty {
            self._serverUrl = stored
        } else {
            self._serverUrl = defaultServerUrl
        }
    }

    public func initialize(defaultServer: String = RecordStore.defaultServer) async throws {
        let stored = try storage.read(key: Self.serverKey)
        withLock {
            _defaultServerUrl = defaultServer
            if let stored = stored, !stored.isEmpty {
                _serverUrl = stored
            } else {
                _serverUrl = _defaultServerUrl
            }
        }
    }

    public func setServerUrlForTesting(_ url: String) {
        lock.lock()
        _defaultServerUrl = url
        _serverUrl = url
        lock.unlock()
    }

    public func isEnrolled() async throws -> Bool {
        let recId = try recordId()
        let priv = try privateKey()
        let pub = try publicKey()
        return (recId != nil && !recId!.isEmpty) &&
               (priv != nil && !priv!.isEmpty) &&
               (pub != nil && !pub!.isEmpty)
    }

    public func recordId() throws -> String? {
        return try storage.read(key: Self.recordIdKey)
    }

    public func privateKey() throws -> String? {
        return try storage.read(key: Self.privateKeyKey)
    }

    public func publicKey() throws -> String? {
        return try storage.read(key: Self.publicKeyKey)
    }

    public func inbox() throws -> String? {
        return try storage.read(key: Self.inboxKey)
    }

    public func deviceId() throws -> String? {
        return try storage.read(key: Self.deviceIdKey)
    }

    public func saveDeviceId(_ id: String?) throws {
        guard let id = id, !id.isEmpty else { return }
        try storage.write(key: Self.deviceIdKey, value: id)
    }

    public func pendingRemoval() throws -> PendingRemoval? {
        guard let value = try storage.read(key: Self.pendingRemovalKey) else { return nil }
        guard let pending = PendingRemoval(rawValue: value) else {
            throw ApiError.incompleteResponse("Unrecognized pending removal state")
        }
        return pending
    }

    public func savePendingRemoval(_ pending: PendingRemoval) throws {
        try storage.write(key: Self.pendingRemovalKey, value: pending.rawValue)
    }

    public func clearPendingRemoval() throws {
        try storage.delete(key: Self.pendingRemovalKey)
    }

    public func effectiveServer(for payload: EnrollmentPayload) -> String {
        if let server = payload.server, !server.isEmpty {
            return server
        }
        return serverUrl
    }

    public func saveEnrollment(_ payload: EnrollmentPayload) throws {
        let effective = effectiveServer(for: payload)

        // The record ID goes last: isEnrolled checks it, so a partial save
        // can never look enrolled, even if cleanup below fails too.
        let values: [(key: String, value: String)] = [
            (Self.inboxKey, payload.inbox),
            (Self.serverKey, effective),
            (Self.publicKeyKey, payload.publicKey),
            (Self.privateKeyKey, payload.privateKey),
            (Self.recordIdKey, payload.recordId),
        ]

        var writtenKeys: [String] = []
        do {
            for entry in values {
                try storage.write(key: entry.key, value: entry.value)
                writtenKeys.append(entry.key)
            }
        } catch {
            for key in writtenKeys {
                try? storage.delete(key: key)
            }
            throw error
        }

        lock.lock()
        _serverUrl = effective
        lock.unlock()
    }

    public func desktopDeviceId() throws -> String {
        if let existing = try storage.read(key: Self.desktopDeviceIdKey), !existing.isEmpty {
            return existing
        }
        let generated = generateDesktopDeviceId()
        try storage.write(key: Self.desktopDeviceIdKey, value: generated)
        return generated
    }

    private func generateDesktopDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func enrollmentPayload() throws -> EnrollmentPayload? {
        guard let recId = try recordId(),
              let priv = try privateKey(),
              let pub = try publicKey(),
              let inb = try inbox() else {
            return nil
        }
        let srv = try storage.read(key: Self.serverKey) ?? serverUrl
        return EnrollmentPayload(
            version: 1,
            recordId: recId,
            privateKey: priv,
            publicKey: pub,
            inbox: inb,
            server: srv
        )
    }

    public func dismissedRestrictionPrompts() throws -> Set<String> {
        guard let stored = try storage.read(key: Self.dismissedRestrictionPromptsKey), !stored.isEmpty else {
            return []
        }
        return Set(stored.components(separatedBy: ","))
    }

    public func saveDismissedRestrictionPrompts(_ names: Set<String>) throws {
        let joined = names.joined(separator: ",")
        try storage.write(key: Self.dismissedRestrictionPromptsKey, value: joined)
    }

    public func notificationPermissionAsked() throws -> Bool {
        let stored = try storage.read(key: Self.notificationPermissionAskedKey)
        return stored == "true"
    }

    public func saveNotificationPermissionAsked() throws {
        try storage.write(key: Self.notificationPermissionAskedKey, value: "true")
    }

    public func notificationExplainerSkipped() throws -> Bool {
        let stored = try storage.read(key: Self.notificationExplainerSkippedKey)
        return stored == "true"
    }

    public func saveNotificationExplainerSkipped() throws {
        try storage.write(key: Self.notificationExplainerSkippedKey, value: "true")
    }

    /// Forgets the enrollment on this device only. Keeps notificationPermissionAsked.
    public func clear() throws {
        let asked = try? storage.read(key: Self.notificationPermissionAskedKey)
        try storage.deleteAll()

        lock.lock()
        _serverUrl = _defaultServerUrl
        lock.unlock()

        if let asked = asked {
            try? storage.write(key: Self.notificationPermissionAskedKey, value: asked)
        }
    }
}
