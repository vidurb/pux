import Foundation

public enum PuxError: Error, LocalizedError, Equatable {
    case relayDeletionUncertain
    case recordNotFound
    case tooManyDevices
    case rateLimited
    case noDevices
    case firebaseNotConfigured
    case fcmRegistrationTimedOut
    case keychainUnavailable
    case alreadyEnrolled
    case invalidQRPayload(String)
    case unsupportedQRVersion(Int)
    case missingQRField(String)
    case invalidRecordId(String)
    case invalidKeyEncoding(String)
    case invalidKeyLength(String, actual: Int, expected: Int)
    case invalidServerUrl(String)
    case insecureServerUrl(String)
    case serverUrlContainsPathOrQuery(String)
    case serverError(statusCode: Int, message: String)
    case undecryptablePayload
    case cryptoInitFailed

    public var errorDescription: String? {
        switch self {
        case .relayDeletionUncertain:
            return "The server rejected this relay deletion. The relay may already be deleted, or the credentials may be invalid. Its status cannot be confirmed. You can retry or explicitly clear local credentials."
        case .recordNotFound:
            return "Relay not found on the server"
        case .tooManyDevices:
            return "This relay already has the maximum number of devices"
        case .rateLimited:
            return "The server is rate limiting requests"
        case .noDevices:
            return "No device is registered on this relay yet"
        case .firebaseNotConfigured:
            return "Push notifications are not configured in this build."
        case .fcmRegistrationTimedOut:
            return "FCM did not finish registering"
        case .keychainUnavailable:
            return "Secure storage is temporarily unavailable. Try again when the device is unlocked."
        case .alreadyEnrolled:
            return "This device is already enrolled. Remove it before enrolling again."
        case .invalidQRPayload(let reason):
            return "Invalid QR payload: \(reason)"
        case .unsupportedQRVersion(let v):
            return "Unsupported QR version: \(v)"
        case .missingQRField(let field):
            return "Missing \(field) in QR payload"
        case .invalidRecordId(let id):
            return "Invalid record_id in enrollment: \(id)"
        case .invalidKeyEncoding(let field):
            return "Invalid \(field) encoding"
        case .invalidKeyLength(let field, let actual, let expected):
            return "Invalid \(field) length (\(actual) bytes, expected \(expected))"
        case .invalidServerUrl(let url):
            return "Invalid server URL in enrollment: \(url)"
        case .insecureServerUrl(let url):
            return "Refusing insecure server \(url): https is required"
        case .serverUrlContainsPathOrQuery(let url):
            return "Server URL must not have a path, query or credentials: \(url)"
        case .serverError(let code, let msg):
            return "Server error (\(code)): \(msg)"
        case .undecryptablePayload:
            return "Message could not be decrypted with this device's key."
        case .cryptoInitFailed:
            return "Crypto initialization failed"
        }
    }
}
