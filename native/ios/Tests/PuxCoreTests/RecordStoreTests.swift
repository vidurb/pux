import XCTest
@testable import PuxCore

private final class FlakyOnceRemovalJournal: RemovalJournal {
    private let intent: RemovalIntent
    private var failedOnce = false

    init(_ intent: RemovalIntent) { self.intent = intent }

    func read() throws -> RemovalIntent? {
        if !failedOnce {
            failedOnce = true
            throw PuxError.serverError(statusCode: 0, message: "Transient removal journal read failure")
        }
        return intent
    }

    func save(_ intent: RemovalIntent) throws {}
    func clear() throws {}
}

private final class CountingRemovalJournal: RemovalJournal {
    var readCount = 0
    private let intent: RemovalIntent?

    init(_ intent: RemovalIntent?) { self.intent = intent }

    func read() throws -> RemovalIntent? {
        readCount += 1
        return intent
    }

    func save(_ intent: RemovalIntent) throws {}
    func clear() throws {}
}

final class RecordStoreTests: XCTestCase {
    private var inMemoryStore: InMemoryKeyValueStore!
    private var recordStore: RecordStore!

    private let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let validRecordId = "00000000-0000-4000-8000-000000000001"

    override func setUp() {
        super.setUp()
        inMemoryStore = InMemoryKeyValueStore()
        recordStore = RecordStore(storage: inMemoryStore, defaultServerUrl: "https://pux.default")
    }

    private func makeValidPayload() -> [String: Any] {
        [
            "v": 1,
            "record_id": validRecordId,
            "private_key": validKey,
            "public_key": validKey,
            "inbox": "token@pux.example",
            "server": "https://pux.example"
        ]
    }

    func testParseQrValid() throws {
        let json = try JSONSerialization.data(withJSONObject: makeValidPayload())
        let string = String(data: json, encoding: .utf8)!

        let parsed = try recordStore.parseQr(string)
        XCTAssertEqual(parsed["record_id"] as? String, validRecordId)
        XCTAssertEqual(parsed["public_key"] as? String, validKey)
        XCTAssertEqual(parsed["inbox"] as? String, "token@pux.example")
    }

    func testParseQrRejectsMissingKeys() {
        var payload = makeValidPayload()
        payload.removeValue(forKey: "public_key")
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let string = String(data: json, encoding: .utf8)!

        XCTAssertThrowsError(try recordStore.parseQr(string)) { error in
            XCTAssertEqual(error as? PuxError, PuxError.missingQRField("public_key"))
        }
    }

    func testParseQrRejectsUnsupportedVersion() {
        var payload = makeValidPayload()
        payload["v"] = 2
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let string = String(data: json, encoding: .utf8)!

        XCTAssertThrowsError(try recordStore.parseQr(string)) { error in
            XCTAssertEqual(error as? PuxError, PuxError.unsupportedQRVersion(2))
        }
    }

    func testParseQrRejectsInvalidUUID() {
        var payload = makeValidPayload()
        payload["record_id"] = "not-a-uuid"
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let string = String(data: json, encoding: .utf8)!

        XCTAssertThrowsError(try recordStore.parseQr(string)) { error in
            XCTAssertEqual(error as? PuxError, PuxError.invalidRecordId("not-a-uuid"))
        }
    }

    func testValidateServerUrl() throws {
        XCTAssertEqual(
            try RecordStore.validateServerUrl("https://pux.example"),
            "https://pux.example"
        )
        XCTAssertEqual(
            try RecordStore.validateServerUrl("https://pux.example:8443/"),
            "https://pux.example:8443"
        )
        XCTAssertEqual(
            try RecordStore.validateServerUrl("http://localhost:4000"),
            "http://localhost:4000"
        )
        XCTAssertEqual(
            try RecordStore.validateServerUrl("http://127.0.0.1:4000"),
            "http://127.0.0.1:4000"
        )
        XCTAssertEqual(
            try RecordStore.validateServerUrl("http://10.0.2.2:4000"),
            "http://10.0.2.2:4000"
        )

        let badUrls = [
            "http://pux.example",
            "http://192.168.1.10:4000",
            "ftp://pux.example",
            "javascript:alert(1)",
            "pux.example",
            "https://user:pass@pux.example",
            "https://pux.example/api",
            "https://pux.example?x=1"
        ]

        for bad in badUrls {
            XCTAssertThrowsError(try RecordStore.validateServerUrl(bad), "Expected failure for \(bad)")
        }
    }

    func testSaveEnrollmentAtomicRollbackOnFailure() {
        // Configure simulated failure on saving record_id
        inMemoryStore.shouldFailOnWrite = RecordStore.recordIdKey

        XCTAssertThrowsError(try recordStore.saveEnrollment(makeValidPayload()))

        // Verify that all keys were rolled back and nothing remains
        XCTAssertFalse(recordStore.isEnrolled())
        XCTAssertNil(inMemoryStore.read(RecordStore.inboxKey))
        XCTAssertNil(inMemoryStore.read(RecordStore.publicKeyKey))
        XCTAssertNil(inMemoryStore.read(RecordStore.privateKeyKey))
        XCTAssertNil(inMemoryStore.read(RecordStore.recordIdKey))
    }

    func testSuccessfulEnrollmentAndClear() throws {
        try recordStore.saveEnrollment(makeValidPayload())
        XCTAssertTrue(recordStore.isEnrolled())
        XCTAssertEqual(recordStore.recordId(), validRecordId)
        XCTAssertEqual(recordStore.serverUrl, "https://pux.example")

        try recordStore.saveNotificationPermissionAsked()
        XCTAssertTrue(recordStore.notificationPermissionAsked())

        try recordStore.clear()
        XCTAssertFalse(recordStore.isEnrolled())
        XCTAssertNil(recordStore.recordId())
        XCTAssertEqual(recordStore.serverUrl, "https://pux.default")

        // Notification permission asked must survive clear
        XCTAssertTrue(recordStore.notificationPermissionAsked())
    }

    func testUnreadableServerUrlDoesNotFallBackWhenEnrolled() throws {
        try recordStore.saveEnrollment(makeValidPayload())
        XCTAssertEqual(recordStore.serverUrl, "https://pux.example")
        inMemoryStore.unavailableKeys.insert(RecordStore.serverKey)
        recordStore.reloadServerUrl()
        XCTAssertTrue(recordStore.serverUrlUnreadable)
        XCTAssertEqual(recordStore.serverUrl, "https://pux.example")
        XCTAssertThrowsError(try recordStore.requireOperationalServerUrl()) { error in
            XCTAssertEqual(error as? PuxError, .keychainUnavailable)
        }
    }

    func testMissingServerUrlUsesDefaultWhenNotEnrolled() throws {
        XCTAssertEqual(recordStore.serverUrl, "https://pux.default")
        inMemoryStore.unavailableKeys.insert(RecordStore.serverKey)
        recordStore.reloadServerUrl()
        XCTAssertTrue(recordStore.serverUrlUnreadable)
    }

    func testPartialServerRecoveryStaysFailClosedUntilEnrollmentReadable() throws {
        try recordStore.saveEnrollment(makeValidPayload())
        let keys: Set<String> = [
            RecordStore.serverKey,
            RecordStore.recordIdKey,
            RecordStore.privateKeyKey,
            RecordStore.publicKeyKey,
        ]
        inMemoryStore.unavailableKeys = keys
        recordStore.reloadServerUrl()
        XCTAssertTrue(recordStore.serverUrlUnreadable)

        inMemoryStore.unavailableKeys.remove(RecordStore.serverKey)
        recordStore.reloadServerUrl()
        XCTAssertEqual(recordStore.serverUrl, "https://pux.example")
        XCTAssertTrue(recordStore.serverUrlUnreadable)

        inMemoryStore.unavailableKeys.removeAll()
        recordStore.reloadServerUrl()
        XCTAssertFalse(recordStore.serverUrlUnreadable)
    }

    func testUncertainRegistrationWarningSurvivesClear() throws {
        try recordStore.recordUncertainRegistrationForRemoval()
        try recordStore.markUncertainRegistrationRemovalServerComplete()
        try recordStore.saveEnrollment(makeValidPayload())
        try recordStore.clear()
        XCTAssertEqual(recordStore.uncertainRegistrationWarningPresentation(), .awaitingAcknowledgement)
    }

    func testUncertainWarningAcknowledgeBlockedUntilServerDeleteComplete() throws {
        try recordStore.recordUncertainRegistrationForRemoval()
        XCTAssertEqual(try recordStore.uncertainRegistrationRemovalWarningPhase(), .recorded)
        XCTAssertFalse(try recordStore.uncertainRegistrationRemovalWarningAwaitingAcknowledgement())
        try recordStore.acknowledgeUncertainRegistrationRemovalWarning()
        XCTAssertEqual(try recordStore.uncertainRegistrationRemovalWarningPhase(), .recorded)
        try recordStore.markUncertainRegistrationRemovalServerComplete()
        try recordStore.acknowledgeUncertainRegistrationRemovalWarning()
        XCTAssertNil(try recordStore.uncertainRegistrationRemovalWarningPhase())
    }

    func testUncertainWarningPresentationReportsJournalUnreadable() {
        let journal = MemoryUncertainRegistrationWarningJournal()
        journal.stored = .awaitingAcknowledgement
        journal.failRead = true
        let store = RecordStore(storage: inMemoryStore, uncertainRegistrationWarningJournal: journal)
        XCTAssertEqual(store.uncertainRegistrationWarningPresentation(), .journalUnreadable)
    }

    func testContentShellRecoveryWhenWarningJournalUnreadable() throws {
        let warningJournal = MemoryUncertainRegistrationWarningJournal()
        warningJournal.failRead = true
        let removalJournal = MemoryRemovalJournal(.device)
        let store = RecordStore(
            storage: inMemoryStore,
            removalJournal: removalJournal,
            uncertainRegistrationWarningJournal: warningJournal
        )
        try store.saveEnrollment(makeValidPayload())
        let shell = store.contentShellState()
        XCTAssertEqual(shell.route, .recoverRemoval(.device))
        XCTAssertTrue(shell.showsUncertainWarningJournalNotice)
        XCTAssertFalse(shell.showsUncertainWarningAlert)
    }

    func testContentShellEnrolledHomeWhenWarningJournalUnreadable() throws {
        let warningJournal = MemoryUncertainRegistrationWarningJournal()
        warningJournal.failRead = true
        let store = RecordStore(storage: inMemoryStore, uncertainRegistrationWarningJournal: warningJournal)
        try store.saveEnrollment(makeValidPayload())
        let shell = store.contentShellState()
        XCTAssertEqual(shell.route, .home)
        XCTAssertTrue(shell.showsUncertainWarningJournalNotice)
        XCTAssertNil(shell.removalIntentReadErrorMessage)
    }

    func testContentShellTransientRemovalIntentReadFailureThenRecovery() throws {
        let removalJournal = FlakyOnceRemovalJournal(.device)
        let store = RecordStore(storage: inMemoryStore, removalJournal: removalJournal)
        try store.saveEnrollment(makeValidPayload())
        let failed = store.contentShellState()
        XCTAssertEqual(failed.route, .removalIntentCheckFailed)
        XCTAssertNotNil(failed.removalIntentReadErrorMessage)
        let recovered = store.contentShellState()
        XCTAssertEqual(recovered.route, .recoverRemoval(.device))
        XCTAssertNil(recovered.removalIntentReadErrorMessage)
    }

    func testContentShellReadsRemovalIntentOncePerSnapshot() throws {
        let removalJournal = CountingRemovalJournal(.relay)
        let store = RecordStore(storage: inMemoryStore, removalJournal: removalJournal)
        try store.saveEnrollment(makeValidPayload())
        _ = store.contentShellState()
        XCTAssertEqual(removalJournal.readCount, 1)
    }

    func testContentShellRemovalIntentCheckFailedPausesDelivery() throws {
        let removalJournal = MemoryRemovalJournal(.relay)
        removalJournal.failReads = true
        let store = RecordStore(storage: inMemoryStore, removalJournal: removalJournal)
        try store.saveEnrollment(makeValidPayload())
        let shell = store.contentShellState()
        XCTAssertEqual(shell.route, .removalIntentCheckFailed)
        XCTAssertNotNil(shell.removalIntentReadErrorMessage)
        XCTAssertFalse(shell.showsUncertainWarningJournalNotice)
    }

    func testContentShellHomeShowsUncertainWarningAlert() throws {
        let warningJournal = MemoryUncertainRegistrationWarningJournal()
        warningJournal.stored = .awaitingAcknowledgement
        let store = RecordStore(storage: inMemoryStore, uncertainRegistrationWarningJournal: warningJournal)
        try store.saveEnrollment(makeValidPayload())
        let shell = store.contentShellState()
        XCTAssertEqual(shell.route, .home)
        XCTAssertTrue(shell.showsUncertainWarningAlert)
    }

}
