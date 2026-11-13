import Security
import XCTest
@testable import PuxCore

/// A store built on injected storage must never consult the process-wide Keychain backend, and a store
/// built on `KeychainKeyValueStore` must still go through it. `SpyPuxKeychainBackend` stands in for the
/// backend so these tests do not touch Security either way.
final class RecordStoreKeychainIsolationTests: XCTestCase {
  private let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  private let validRecordId = "00000000-0000-4000-8000-000000000001"
  private let enrollmentKeys = [
    RecordStore.recordIdKey,
    RecordStore.privateKeyKey,
    RecordStore.publicKeyKey,
  ]

  private var spy: SpyPuxKeychainBackend!
  private var originalBackend: PuxKeychainBackend!

  override func setUp() {
    super.setUp()
    originalBackend = PuxKeychain.backend
    spy = SpyPuxKeychainBackend()
    PuxKeychain.backend = spy
  }

  override func tearDown() {
    PuxKeychain.backend = originalBackend
    super.tearDown()
  }

  private func payload() -> [String: Any] {
    [
      "v": 1,
      "record_id": validRecordId,
      "private_key": validKey,
      "public_key": validKey,
      "inbox": "token@pux.example",
      "server": "https://pux.example",
    ]
  }

  // MARK: Injected storage never reaches the global backend

  func testConstructingStoreWithInjectedStorageDoesNotReadTheGlobalBackend() {
    _ = RecordStore(storage: InMemoryKeyValueStore())
    XCTAssertEqual(spy.calls, [])
  }

  func testEveryStoreOperationOnInjectedStorageStaysOffTheGlobalBackend() throws {
    let store = RecordStore(storage: InMemoryKeyValueStore(), defaultServerUrl: "https://pux.default")

    store.reloadServerUrl()
    try store.requireOperationalServerUrl()
    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)
    XCTAssertEqual(store.contentShellState().route, .enroll)

    try store.saveEnrollment(payload())
    XCTAssertEqual(store.enrollmentAvailability(), .enrolled)
    XCTAssertEqual(store.contentShellState().route, .home)
    XCTAssertEqual(store.recordId(), validRecordId)
    XCTAssertEqual(try store.enrollmentPayload()["server"] as? String, "https://pux.example")

    try store.saveDeviceId("device-1")
    try store.savePendingRegistration("pending-token")
    try store.clearPendingRegistration()
    try store.saveDismissedRestrictionPrompts(["scheduledSummary"])
    try store.saveNotificationPermissionAsked()
    try store.saveNotificationExplainerSkipped()

    try store.saveRemovalIntent(.device)
    XCTAssertEqual(store.contentShellState().route, .recoverRemoval(.device))
    try store.clearRemovalIntent()
    try store.recordUncertainRegistrationForRemoval()
    try store.markUncertainRegistrationRemovalServerComplete()
    try store.acknowledgeUncertainRegistrationRemovalWarning()

    store.refreshFromStorage()
    try store.clear()
    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)

    XCTAssertEqual(spy.calls, [], "an injected store must not reach PuxKeychain.backend")
  }

  func testUnavailableEnrollmentKeyInInjectedStorageIsReportedWithoutTheGlobalBackend() {
    for lockedKey in enrollmentKeys {
      let storage = InMemoryKeyValueStore()
      storage.unavailableKeys = [lockedKey]
      let store = RecordStore(storage: storage)

      XCTAssertEqual(store.enrollmentAvailability(), .storageUnavailable, lockedKey)
      XCTAssertEqual(store.contentShellState().route, .storageUnavailable, lockedKey)
      XCTAssertTrue(store.serverUrlUnreadable, lockedKey)
      XCTAssertThrowsError(try store.requireOperationalServerUrl(), lockedKey) { error in
        XCTAssertEqual(error as? PuxError, .keychainUnavailable)
      }
      XCTAssertThrowsError(try store.saveEnrollment(payload()), lockedKey) { error in
        XCTAssertEqual(error as? PuxError, .keychainUnavailable)
      }
    }
    XCTAssertEqual(spy.calls, [])
  }

  /// The global backend reporting a locked Keychain must not lock a store that does not use it. Before
  /// the fix the in-memory store inherited the global result and refused to enroll.
  func testLockedGlobalBackendDoesNotLockAnInjectedStore() throws {
    spy.forceReadStatus(.unavailable(errSecInteractionNotAllowed))
    let store = RecordStore(storage: InMemoryKeyValueStore())

    XCTAssertFalse(store.serverUrlUnreadable)
    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)
    XCTAssertNoThrow(try store.requireOperationalServerUrl())
    try store.saveEnrollment(payload())
    XCTAssertEqual(store.enrollmentAvailability(), .enrolled)
    XCTAssertEqual(spy.calls, [])
  }

  func testEnrolledGlobalBackendDoesNotEnrollAnInjectedStore() {
    for key in enrollmentKeys { spy.seed(key, "from-the-real-keychain") }
    let store = RecordStore(storage: InMemoryKeyValueStore())

    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)
    XCTAssertFalse(store.isEnrolled())
    XCTAssertNil(store.recordId())
    XCTAssertEqual(spy.calls, [])
  }

  // MARK: Services on injected storage

  @MainActor
  func testDeliveryControllerAndApiClientOnInjectedStorageStayOffTheGlobalBackend() async throws {
    let store = RecordStore(storage: InMemoryKeyValueStore())
    try store.saveEnrollment(payload())
    _ = ApiClient(session: MockURLProtocol.makeSession(), recordStore: store)

    let service = CountingDeliveryService()
    let controller = DeliveryController(recordStore: store, deliveryService: service)
    await controller.start()
    await controller.onResume()
    await controller.stop()

    XCTAssertEqual(service.starts, 1)
    XCTAssertEqual(spy.calls, [])
  }

  /// `DeliveryController(recordStore:)` builds its own `FcmRegistration`, which defaults to
  /// `ApiClient.shared` and so to `RecordStore.shared`. In a test process that must stay in memory.
  @MainActor
  func testDefaultServiceWiringStaysOffTheGlobalBackend() throws {
    let store = RecordStore(storage: InMemoryKeyValueStore())
    _ = DeliveryController(recordStore: store)
    XCTAssertEqual(spy.calls, [])
  }

  // MARK: The shared store

  func testSharedStoreInThisTestProcessIsInMemory() {
    XCTAssertFalse(RecordStore.shared.usesKeychainStorage)
    XCTAssertFalse(RecordStore.shared.isEnrolled())
    XCTAssertEqual(spy.calls, [])
  }

  func testSharedStoreForTestContextIsInMemory() {
    let store = RecordStore.makeShared(context: .test)
    XCTAssertFalse(store.usesKeychainStorage)
    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)
    XCTAssertEqual(store.contentShellState().route, .enroll)
    XCTAssertEqual(spy.calls, [])
  }

  // MARK: Production behaviour is preserved

  func testSharedStoreForProductionContextIsKeychainBacked() {
    let store = RecordStore.makeShared(context: .production)
    XCTAssertTrue(store.usesKeychainStorage)
    XCTAssertEqual(
      spy.calls,
      [
        .read(RecordStore.recordIdKey),
        .read(RecordStore.privateKeyKey),
        .read(RecordStore.publicKeyKey),
        .read(RecordStore.serverKey),
      ],
      "constructing the production store reads the enrollment keys and server URL through PuxKeychain"
    )
  }

  func testKeychainBackedStoreReportsALockedKeychainAsStorageUnavailable() {
    spy.forceReadStatus(.unavailable(errSecInteractionNotAllowed))
    let store = keychainBackedStore()

    XCTAssertTrue(store.serverUrlUnreadable)
    XCTAssertEqual(store.enrollmentAvailability(), .storageUnavailable)
    XCTAssertEqual(store.contentShellState().route, .storageUnavailable)
    XCTAssertThrowsError(try store.requireOperationalServerUrl()) { error in
      XCTAssertEqual(error as? PuxError, .keychainUnavailable)
    }
    XCTAssertThrowsError(try store.saveEnrollment(payload())) { error in
      XCTAssertEqual(error as? PuxError, .keychainUnavailable)
    }
    XCTAssertFalse(spy.calls.contains { if case .write = $0 { return true } else { return false } })
  }

  func testKeychainBackedStoreReadsEnrollmentFromTheGlobalBackend() {
    spy.seed(RecordStore.recordIdKey, validRecordId)
    spy.seed(RecordStore.privateKeyKey, validKey)
    spy.seed(RecordStore.publicKeyKey, validKey)
    spy.seed(RecordStore.serverKey, "https://relay.example")
    let store = keychainBackedStore()

    XCTAssertEqual(store.enrollmentAvailability(), .enrolled)
    XCTAssertTrue(store.isEnrolled())
    XCTAssertEqual(store.recordId(), validRecordId)
    XCTAssertEqual(store.serverUrl, "https://relay.example")
    XCTAssertFalse(store.serverUrlUnreadable)
  }

  func testKeychainBackedStoreWritesEnrollmentThroughTheGlobalBackend() throws {
    let store = keychainBackedStore()
    try store.saveEnrollment(payload())

    XCTAssertEqual(store.enrollmentAvailability(), .enrolled)
    XCTAssertEqual(spy.storedItems[RecordStore.recordIdKey], validRecordId)
    XCTAssertEqual(spy.storedItems[RecordStore.privateKeyKey], validKey)
    XCTAssertEqual(spy.storedItems[RecordStore.publicKeyKey], validKey)
    XCTAssertEqual(spy.storedItems[RecordStore.inboxKey], "token@pux.example")
    XCTAssertEqual(spy.storedItems[RecordStore.serverKey], "https://pux.example")

    try store.clear()
    XCTAssertTrue(spy.calls.contains(.deleteAll))
    XCTAssertEqual(store.enrollmentAvailability(), .notEnrolled)
  }

  /// A Keychain-backed store with in-memory journals: the journals use Security directly, which these
  /// tests must not reach.
  private func keychainBackedStore() -> RecordStore {
    RecordStore(
      storage: KeychainKeyValueStore(),
      removalJournal: MemoryRemovalJournal(),
      uncertainRegistrationWarningJournal: MemoryUncertainRegistrationWarningJournal()
    )
  }
}

private final class CountingDeliveryService: DeliveryServiceProtocol, @unchecked Sendable {
  var starts = 0
  func start() async throws { starts += 1 }
  func stop() async {}
}
