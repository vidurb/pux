import XCTest
@testable import PuxCore

final class EnrollmentPayloadServerTests: PuxTestCase {
    func testRejectsNonStringServer() throws {
        let keys = try SodiumCrypto.shared.generateKeyPair()
        var dict: [String: Any] = [
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": keys.privateKey,
            "public_key": keys.publicKey,
            "inbox": "inbox@pux.test",
            "server": 1,
        ]
        XCTAssertThrowsError(try EnrollmentPayload.parse(dictionary: dict)) { error in
            guard case EnrollmentError.invalidField("server") = error else {
                XCTFail("expected invalid server field, got \(error)")
                return
            }
        }
    }
}
