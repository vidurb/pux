#if os(iOS)
import UserNotifications
import PuxCore

public final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    public override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        let ciphertextRaw = request.content.userInfo["ciphertext"] as? String
            ?? (request.content.userInfo["data"] as? [String: Any])?["ciphertext"] as? String

        guard let content = bestAttemptContent,
              let ciphertext = ciphertextRaw,
              let publicKey = PuxKeychain.read("public_key"),
              let secretKey = PuxKeychain.read("private_key"),
              let payload = try? CryptoService.shared.openSealed(
                  ciphertextB64: ciphertext,
                  publicKeyB64: publicKey,
                  privateKeyB64: secretKey
              )
        else {
            contentHandler(request.content)
            return
        }

        let relay = RelayNotification.fromPayload(payload)
        content.title = relay.title
        content.body = relay.body

        if let url = relay.url {
            content.userInfo["confirmation_url"] = url.absoluteString
            content.categoryIdentifier = "FORWARDING_CONFIRMATION"
        }

        contentHandler(content)
    }

    public override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
#endif
