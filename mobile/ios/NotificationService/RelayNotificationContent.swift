import Foundation
import Sodium

/// Swift twin of `RelayNotification.fromPayload` in
/// lib/src/services/notification_service.dart. Keep the two in sync.
struct RelayNotificationContent: Equatable {
  let title: String
  let body: String

  init(payload: [String: Any]) {
    let sender = payload["sender"] as? String ?? "Unknown sender"

    switch payload["type"] as? String ?? "otp" {
    case "forward_confirm":
      let code = payload["code"] as? String
      let url = payload["url"] as? String
      let from = payload["forwarding_from"] as? String
      title = "Email forwarding confirmation"
      body = [
        from.map { "Forwarding from \($0)" },
        code.map { "Code: \($0)" },
        url,
        from == nil ? "From \(sender)" : nil,
      ].compactMap { $0 }.joined(separator: "\n")
    default:
      let otp = payload["otp"] as? String ?? "??????"
      // Older servers send no `verified` key; only an explicit false is marked.
      let unverified = (payload["verified"] as? Bool) == false
      title = "OTP from \(sender)\(unverified ? " (unverified)" : "")"
      body = otp
    }
  }
}

/// Opens the server's libsodium sealed boxes (`:enacl.box_seal`). Keys and
/// ciphertext are unpadded base64url, as in CryptoService.
enum SealedPayload {
  static func open(ciphertext: String, publicKey: String, secretKey: String) -> [String: Any]? {
    guard let cipherText = decodeBase64URL(ciphertext),
      let publicKey = decodeBase64URL(publicKey), publicKey.count == 32,
      var secretKey = decodeBase64URL(secretKey), secretKey.count == 32
    else { return nil }

    let sodium = Sodium()
    defer { sodium.utils.zero(&secretKey) }
    guard
      let plaintext = sodium.box.open(
        anonymousCipherText: cipherText,
        recipientPublicKey: publicKey,
        recipientSecretKey: secretKey
      )
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(plaintext))) as? [String: Any]
  }

  static func decodeBase64URL(_ value: String) -> Bytes? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64).map { Bytes($0) }
  }
}
