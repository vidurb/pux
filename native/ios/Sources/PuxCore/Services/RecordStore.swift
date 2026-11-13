import Foundation
import Security

public protocol KeyValueStore: AnyObject {
    func read(_ key: String) -> String?
    func readStatus(_ key: String) -> KeychainReadStatus
    func write(_ key: String, value: String) throws
    func delete(_ key: String) throws
    func deleteAll() throws
}

public extension KeyValueStore {
    func readStatus(_ key: String) -> KeychainReadStatus {
        if let value = read(key) { return .found(value) }
        return .missing
    }
}

public final class KeychainKeyValueStore: KeyValueStore {
    public init() {}
    public func readStatus(_ key: String) -> KeychainReadStatus {
        PuxKeychain.readStatus(key)
    }
    public func read(_ key: String) -> String? {
        switch readStatus(key) {
        case .found(let value): return value
        case .missing, .unavailable: return nil
        }
    }
    public func write(_ key: String, value: String) throws {
        switch PuxKeychain.readStatus(key) {
        case .unavailable: throw PuxError.keychainUnavailable
        default: break
        }
        guard PuxKeychain.write(key, value: value) else {
            throw PuxError.keychainUnavailable
        }
    }
    public func delete(_ key: String) throws {
        guard PuxKeychain.delete(key) else {
            throw PuxError.serverError(statusCode: 500, message: "Keychain deletion failed for key \(key)")
        }
    }
    public func deleteAll() throws {
        guard PuxKeychain.deleteAll() else {
            throw PuxError.serverError(statusCode: 500, message: "Keychain deleteAll failed")
        }
    }
}

public final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: String] = [:]
    public var shouldFailOnWrite: String? = nil
    public var shouldFailOnDelete: String? = nil
    public var unavailableKeys: Set<String> = []

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func readStatus(_ key: String) -> KeychainReadStatus {
        if unavailableKeys.contains(key) {
            return .unavailable(errSecInteractionNotAllowed)
        }
        if let value = storage[key] { return .found(value) }
        return .missing
    }

    public func read(_ key: String) -> String? {
        switch readStatus(key) {
        case .found(let value): return value
        case .missing, .unavailable: return nil
        }
    }

    public func write(_ key: String, value: String) throws {
        if let failKey = shouldFailOnWrite, failKey == key {
            throw PuxError.serverError(statusCode: 500, message: "Simulated write failure for \(key)")
        }
        storage[key] = value
    }

    public func delete(_ key: String) throws {
        if let failKey = shouldFailOnDelete, failKey == key {
            throw PuxError.serverError(statusCode: 500, message: "Simulated delete failure for \(key)")
        }
        storage.removeValue(forKey: key)
    }

    public func deleteAll() throws {
        storage.removeAll()
    }
}

public enum RemovalIntent: String, Sendable {
    case device, relay, local
}

public protocol RemovalJournal: AnyObject {
    func read() throws -> RemovalIntent?
    func save(_ intent: RemovalIntent) throws
    func clear() throws
}

public final class MemoryRemovalJournal: RemovalJournal {
    public var value: RemovalIntent?
    public var failWrites = false
    public var failReads = false
    public init(_ value: RemovalIntent? = nil) { self.value = value }
    public func read() throws -> RemovalIntent? {
        if failReads { throw PuxError.serverError(statusCode: 0, message: "Removal journal read failed") }
        return value
    }
    public func save(_ intent: RemovalIntent) throws {
        if failWrites { throw PuxError.serverError(statusCode: 0, message: "Removal journal write failed") }
        value = intent
    }
    public func clear() throws {
        if failWrites { throw PuxError.serverError(statusCode: 0, message: "Removal journal clear failed") }
        value = nil
    }
}

/// Separate service survives partial deletion of the enrollment Keychain service.
public final class KeychainRemovalJournal: RemovalJournal {
    private let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "xyz.vidur.pux.removal-journal",
        kSecAttrAccount: "intent"
    ]
    public init() {}
    public func read() throws -> RemovalIntent? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let raw = String(data: data, encoding: .utf8), let intent = RemovalIntent(rawValue: raw) else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot read removal journal")
        }
        return intent
    }
    public func save(_ intent: RemovalIntent) throws {
        let data = Data(intent.rawValue.utf8)
        let changes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot update removal journal")
        }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw PuxError.serverError(statusCode: Int(added), message: "Cannot save removal journal")
        }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot clear removal journal")
        }
    }
}

public enum UncertainRegistrationWarningPhase: String, Equatable, Sendable {
    case recorded
    case awaitingAcknowledgement
}

public protocol UncertainRegistrationWarningJournal: AnyObject {
    func phase() throws -> UncertainRegistrationWarningPhase?
    func recordUncertaintyForRemoval() throws
    func markServerDeleteCompleted() throws
    func acknowledge() throws
}

public final class MemoryUncertainRegistrationWarningJournal: UncertainRegistrationWarningJournal {
    public var stored: UncertainRegistrationWarningPhase?
    public var failRead = false
    public var failRecord = false
    public var failMarkComplete = false
    public init() {}
    public func phase() throws -> UncertainRegistrationWarningPhase? {
        if failRead {
            throw PuxError.serverError(statusCode: 0, message: "Simulated uncertain-registration warning read failure")
        }
        return stored
    }
    public func recordUncertaintyForRemoval() throws {
        if failRecord {
            throw PuxError.serverError(statusCode: 0, message: "Simulated uncertain-registration warning save failure")
        }
        if try phase() != nil { return }
        stored = .recorded
    }
    public func markServerDeleteCompleted() throws {
        guard stored != nil else { return }
        if failMarkComplete {
            throw PuxError.serverError(statusCode: 0, message: "Simulated uncertain-registration phase update failure")
        }
        stored = .awaitingAcknowledgement
    }
    public func acknowledge() throws { stored = nil }
}

/// Survives enrollment `deleteAll` and cleanup of the main Keychain service.
public final class KeychainUncertainRegistrationWarningJournal: UncertainRegistrationWarningJournal {
    private let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "xyz.vidur.pux.uncertain-registration-warning",
        kSecAttrAccount: "pending"
    ]
    public init() {}
    public func phase() throws -> UncertainRegistrationWarningPhase? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let raw = String(data: data, encoding: .utf8),
              let phase = UncertainRegistrationWarningPhase(rawValue: raw)
        else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot read uncertain-registration warning")
        }
        return phase
    }
    public func recordUncertaintyForRemoval() throws {
        if try phase() != nil { return }
        try writePhase(.recorded)
    }
    public func markServerDeleteCompleted() throws {
        guard try phase() != nil else { return }
        try writePhase(.awaitingAcknowledgement)
    }
    public func acknowledge() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot clear uncertain-registration warning")
        }
    }

    private func writePhase(_ phase: UncertainRegistrationWarningPhase) throws {
        let data = Data(phase.rawValue.utf8)
        let changes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw PuxError.serverError(statusCode: Int(status), message: "Cannot update uncertain-registration warning")
        }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw PuxError.serverError(statusCode: Int(added), message: "Cannot save uncertain-registration warning")
        }
    }
}

public final class RecordStore {
    public static let shared = makeShared(context: .current)

    /// The app-wide store. A test process gets in-memory storage and journals, so views and services
    /// that default to `RecordStore.shared` cannot reach the Keychain from a test run.
    static func makeShared(context: PuxLaunchContext) -> RecordStore {
        switch context {
        case .production: return RecordStore()
        case .test: return RecordStore(storage: InMemoryKeyValueStore())
        }
    }

    public static let recordIdKey = "record_id"
    public static let privateKeyKey = "private_key"
    public static let publicKeyKey = "public_key"
    public static let inboxKey = "inbox"
    public static let serverKey = "server_url"
    public static let deviceIdKey = "device_id"
    public static let pendingRegistrationKey = "pending_fcm_registration"
    public static let desktopDeviceIdKey = "desktop_device_id"
    public static let dismissedRestrictionPromptsKey = "dismissed_restriction_prompts"
    public static let notificationPermissionAskedKey = "notification_permission_asked"
    public static let notificationExplainerSkippedKey = "notification_explainer_skipped"
    private static let cleartextHosts: Set<String> = ["localhost", "127.0.0.1", "10.0.2.2"]

    public var defaultServerUrl: String = "https://pux.vidur.xyz"
    public var serverUrl: String = "https://pux.vidur.xyz"
    /// Enrolled relay with a server URL that cannot be read from secure storage (device locked, etc.).
    public private(set) var serverUrlUnreadable = false

    private let storage: KeyValueStore
    private let removalJournal: RemovalJournal
    private let uncertainRegistrationWarningJournal: UncertainRegistrationWarningJournal

    public init(
        storage: KeyValueStore = KeychainKeyValueStore(),
        removalJournal: RemovalJournal? = nil,
        uncertainRegistrationWarningJournal: UncertainRegistrationWarningJournal? = nil,
        defaultServerUrl: String = "https://pux.vidur.xyz"
    ) {
        self.storage = storage
        self.removalJournal = removalJournal ?? (storage is KeychainKeyValueStore ? KeychainRemovalJournal() : MemoryRemovalJournal())
        self.uncertainRegistrationWarningJournal = uncertainRegistrationWarningJournal
            ?? (storage is KeychainKeyValueStore
                ? KeychainUncertainRegistrationWarningJournal()
                : MemoryUncertainRegistrationWarningJournal())
        self.defaultServerUrl = defaultServerUrl
        applyServerUrlFromStorage()
    }

    public func reloadServerUrl() {
        applyServerUrlFromStorage()
    }

    public func requireOperationalServerUrl() throws {
        applyServerUrlFromStorage()
        if serverUrlUnreadable {
            throw PuxError.keychainUnavailable
        }
    }

    /// True when any enrollment key exists but cannot be read (device locked, etc.). Asks only the
    /// injected storage: a `KeychainKeyValueStore` already reads through `PuxKeychain`, and any other
    /// store must not depend on the process-wide Keychain backend.
    private func enrollmentStorageLocked() -> Bool {
        for key in [Self.recordIdKey, Self.privateKeyKey, Self.publicKeyKey] {
            if case .unavailable = storage.readStatus(key) { return true }
        }
        return false
    }

    /// Whether this store reads and writes the real Keychain (and keeps its journals there).
    var usesKeychainStorage: Bool { storage is KeychainKeyValueStore }

    private func applyServerUrlFromStorage() {
        let locked = enrollmentStorageLocked()
        switch storage.readStatus(Self.serverKey) {
        case .found(let stored) where !stored.isEmpty:
            serverUrl = stored
            serverUrlUnreadable = locked
        case .missing:
            serverUrl = defaultServerUrl
            serverUrlUnreadable = locked
        case .unavailable:
            serverUrlUnreadable = true
        case .found:
            serverUrl = defaultServerUrl
            serverUrlUnreadable = locked
        }
    }

    public enum EnrollmentAvailability: Equatable {
        case enrolled
        case notEnrolled
        case storageUnavailable
    }

    public func enrollmentAvailability() -> EnrollmentAvailability {
        if enrollmentStorageLocked() { return .storageUnavailable }
        return isEnrolled() ? .enrolled : .notEnrolled
    }

    public func isEnrolled() -> Bool {
        guard let recordId = storage.read(Self.recordIdKey), !recordId.isEmpty,
              let priv = storage.read(Self.privateKeyKey), !priv.isEmpty,
              let pub = storage.read(Self.publicKeyKey), !pub.isEmpty
        else {
            return false
        }
        return true
    }

    public func recordId() -> String? { storage.read(Self.recordIdKey) }
    public func privateKey() -> String? { storage.read(Self.privateKeyKey) }
    public func publicKey() -> String? { storage.read(Self.publicKeyKey) }
    public func inbox() -> String? { storage.read(Self.inboxKey) }
    public func deviceId() -> String? { storage.read(Self.deviceIdKey) }

    public func removalIntent() throws -> RemovalIntent? { try removalJournal.read() }
    public func saveRemovalIntent(_ intent: RemovalIntent) throws { try removalJournal.save(intent) }
    public func clearRemovalIntent() throws { try removalJournal.clear() }

    public func pendingRegistration() -> String? { storage.read(Self.pendingRegistrationKey) }

    public func savePendingRegistration(_ token: String) throws {
        try storage.write(Self.pendingRegistrationKey, value: token)
    }

    public func clearPendingRegistration() throws {
        try storage.delete(Self.pendingRegistrationKey)
    }

    public func uncertainRegistrationRemovalWarningPhase() throws -> UncertainRegistrationWarningPhase? {
        try uncertainRegistrationWarningJournal.phase()
    }

    public func uncertainRegistrationRemovalWarningAwaitingAcknowledgement() throws -> Bool {
        try uncertainRegistrationRemovalWarningPhase() == .awaitingAcknowledgement
    }

    public enum UncertainRegistrationWarningPresentation: Equatable {
        case none
        case awaitingAcknowledgement
        case journalUnreadable
    }

    public func uncertainRegistrationWarningPresentation() -> UncertainRegistrationWarningPresentation {
        do {
            switch try uncertainRegistrationRemovalWarningPhase() {
            case nil: return .none
            case .awaitingAcknowledgement: return .awaitingAcknowledgement
            case .recorded: return .none
            }
        } catch {
            return .journalUnreadable
        }
    }

    public struct ContentShellState: Equatable {
        public enum Route: Equatable {
            case storageUnavailable
            case removalIntentCheckFailed
            case recoverRemoval(RemovalIntent)
            case home
            case enroll
        }

        public let route: Route
        /// Set when `route` is `.removalIntentCheckFailed` from the same removal-journal read as routing.
        public let removalIntentReadErrorMessage: String?
        /// Inline retryable notice; home and recovery stay reachable (known-device removal, DELETE retry).
        public let showsUncertainWarningJournalNotice: Bool
        public let showsUncertainWarningAlert: Bool
    }

    public func contentShellState() -> ContentShellState {
        if case .storageUnavailable = enrollmentAvailability() {
            return ContentShellState(
                route: .storageUnavailable,
                removalIntentReadErrorMessage: nil,
                showsUncertainWarningJournalNotice: false,
                showsUncertainWarningAlert: false
            )
        }
        let warning = uncertainRegistrationWarningPresentation()
        let warningUnreadable = warning == .journalUnreadable
        let warningAlert = warning == .awaitingAcknowledgement
        let removalResult = Result { try removalIntent() }
        switch removalResult {
        case .failure(let error):
            return ContentShellState(
                route: .removalIntentCheckFailed,
                removalIntentReadErrorMessage: error.localizedDescription,
                showsUncertainWarningJournalNotice: false,
                showsUncertainWarningAlert: warningAlert
            )
        case .success(let intent?):
            return ContentShellState(
                route: .recoverRemoval(intent),
                removalIntentReadErrorMessage: nil,
                showsUncertainWarningJournalNotice: warningUnreadable,
                showsUncertainWarningAlert: warningAlert
            )
        case .success(nil):
            if isEnrolled() {
                return ContentShellState(
                    route: .home,
                    removalIntentReadErrorMessage: nil,
                    showsUncertainWarningJournalNotice: warningUnreadable,
                    showsUncertainWarningAlert: warningAlert
                )
            }
            return ContentShellState(
                route: .enroll,
                removalIntentReadErrorMessage: nil,
                showsUncertainWarningJournalNotice: warningUnreadable,
                showsUncertainWarningAlert: warningAlert
            )
        }
    }

    public static let uncertainRegistrationWarningJournalUnreadableMessage =
        "Could not read the stale-registration reminder from secure storage. Try again when the device is unlocked."

    public func recordUncertainRegistrationForRemoval() throws {
        try uncertainRegistrationWarningJournal.recordUncertaintyForRemoval()
    }

    public func markUncertainRegistrationRemovalServerComplete() throws {
        try uncertainRegistrationWarningJournal.markServerDeleteCompleted()
    }

    public func acknowledgeUncertainRegistrationRemovalWarning() throws {
        guard try uncertainRegistrationRemovalWarningPhase() == .awaitingAcknowledgement else { return }
        try uncertainRegistrationWarningJournal.acknowledge()
    }

    public static let uncertainRegistrationRemovalWarningMessage =
        "A push registration on the server may not have finished. The server might still hold a stale device registration. Delete the relay everywhere from another enrolled device, or reinstall pux here, to clear it."

    public func saveDeviceId(_ id: String?) throws {
        guard let id = id, !id.isEmpty else { return }
        try storage.write(Self.deviceIdKey, value: id)
    }

    public func dismissedRestrictionPrompts() -> Set<String> {
        guard let raw = storage.read(Self.dismissedRestrictionPromptsKey), !raw.isEmpty else {
            return []
        }
        return Set(raw.split(separator: ",").map(String.init))
    }

    public func saveDismissedRestrictionPrompts(_ names: Set<String>) throws {
        let joined = names.sorted().joined(separator: ",")
        try storage.write(Self.dismissedRestrictionPromptsKey, value: joined)
    }

    public func notificationPermissionAsked() -> Bool {
        storage.read(Self.notificationPermissionAskedKey) == "true"
    }

    public func saveNotificationPermissionAsked() throws {
        try storage.write(Self.notificationPermissionAskedKey, value: "true")
    }

    public func notificationExplainerSkipped() -> Bool {
        storage.read(Self.notificationExplainerSkippedKey) == "true"
    }

    public func saveNotificationExplainerSkipped() throws {
        try storage.write(Self.notificationExplainerSkippedKey, value: "true")
    }

    public func enrollmentPayload() throws -> [String: Any] {
        let payload: [String: Any] = [
            "v": 1,
            "record_id": recordId() ?? "",
            "private_key": privateKey() ?? "",
            "public_key": publicKey() ?? "",
            "inbox": inbox() ?? "",
            "server": storage.read(Self.serverKey) ?? serverUrl
        ]
        return payload
    }

    /// Saves enrollment atomically. The record_id goes last: isEnrolled needs it,
    /// so a partial save can never look enrolled. If any write fails, cleans up all written keys.
    public func saveEnrollment(_ payload: [String: Any]) throws {
        if case .storageUnavailable = enrollmentAvailability() {
            throw PuxError.keychainUnavailable
        }
        if isEnrolled() {
            throw PuxError.alreadyEnrolled
        }
        let enrollment = try validateEnrollmentPayload(payload)
        let effectiveServer = try enrollmentServer(payload)

        let valuesToSave: [(String, String)] = [
            (Self.inboxKey, enrollment.inbox),
            (Self.serverKey, effectiveServer),
            (Self.publicKeyKey, enrollment.publicKey),
            (Self.privateKeyKey, enrollment.privateKey),
            (Self.recordIdKey, enrollment.recordId) // recordId written last
        ]

        var savedKeys: [String] = []
        do {
            for (key, val) in valuesToSave {
                try storage.write(key, value: val)
                savedKeys.append(key)
            }
            self.serverUrl = effectiveServer
        } catch {
            // Clean up all written keys on partial failure
            for key in savedKeys {
                try? storage.delete(key)
            }
            throw error
        }
    }

    /// Clears the enrollment on this device. Preserves notificationPermissionAsked.
    public func clear() throws {
        let asked = storage.read(Self.notificationPermissionAskedKey)
        try storage.deleteAll()
        self.serverUrl = defaultServerUrl
        applyServerUrlFromStorage()
        if let asked = asked {
            try? storage.write(Self.notificationPermissionAskedKey, value: asked)
        }
    }

    public func parseQr(_ raw: String) throws -> [String: Any] {
        let payload = try EnrollmentPayload.parse(raw: raw)
        return payload.toDictionary()
    }

    public func enrollmentServer(_ payload: [String: Any]) throws -> String {
        guard let server = payload["server"] else {
            return serverUrl
        }
        guard let serverStr = server as? String, !serverStr.isEmpty else {
            return serverUrl
        }
        if serverStr == defaultServerUrl {
            return serverStr
        }
        return try Self.validateServerUrl(serverStr)
    }

    public static func validateServerUrl(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty
        else {
            throw PuxError.invalidServerUrl(trimmed)
        }

        let secure = scheme == "https"
        let local = scheme == "http" && cleartextHosts.contains(host)
        if !secure && !local {
            throw PuxError.insecureServerUrl("\(scheme)://\(host)")
        }

        if components.user != nil ||
           components.password != nil ||
           components.query != nil ||
           components.fragment != nil ||
           components.path.count > 1 {
            throw PuxError.serverUrlContainsPathOrQuery(trimmed)
        }

        var normalized = components
        normalized.path = ""
        guard let url = normalized.url else {
            throw PuxError.invalidServerUrl(trimmed)
        }
        return url.absoluteString
    }

    /// Reloads in-memory state from Keychain (e.g. after protected data becomes available).
    public func refreshFromStorage() {
        reloadServerUrl()
    }

    private func validateEnrollmentPayload(_ payload: [String: Any]) throws -> EnrollmentPayload {
        if let rawVersion = payload["v"] {
            let version = try EnrollmentPayload.parseVersionField(rawVersion)
            guard version == 1 else {
                throw PuxError.unsupportedQRVersion(version)
            }
        }
        guard let recordId = payload["record_id"] as? String, recordId.isValidUUID else {
            throw PuxError.invalidRecordId(payload["record_id"] as? String ?? "")
        }
        guard let inbox = payload["inbox"] as? String, !inbox.isEmpty else {
            throw PuxError.missingQRField("inbox")
        }
        guard let priv = payload["private_key"] as? String else {
            throw PuxError.missingQRField("private_key")
        }
        _ = try Base64URL.decodeKey(priv, fieldName: "private_key")

        guard let pub = payload["public_key"] as? String else {
            throw PuxError.missingQRField("public_key")
        }
        _ = try Base64URL.decodeKey(pub, fieldName: "public_key")

        let server = payload["server"] as? String

        return EnrollmentPayload(
            recordId: recordId,
            privateKey: priv,
            publicKey: pub,
            inbox: inbox,
            server: server
        )
    }
}
