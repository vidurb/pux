import UserNotifications

/// Replaces the server's placeholder alert ("New code") with the decrypted
/// code. On any failure the placeholder is delivered unchanged.
final class NotificationService: UNNotificationServiceExtension {
  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
      let ciphertext = request.content.userInfo["ciphertext"] as? String,
      let publicKey = PuxKeychain.read("public_key"),
      let secretKey = PuxKeychain.read("private_key"),
      let payload = SealedPayload.open(
        ciphertext: ciphertext, publicKey: publicKey, secretKey: secretKey)
    else {
      contentHandler(request.content)
      return
    }

    let relay = RelayNotificationContent(payload: payload)
    content.title = relay.title
    content.body = relay.body
    contentHandler(content)
  }
}
