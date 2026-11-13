import Foundation

/// Swift counterpart of `RelayNotification.fromPayload` in Flutter and the iOS extension.
public struct RelayNotification: Equatable {
    public let title: String
    public let body: String
    public let code: String?
    public let url: URL?

    public static let confirmationHosts: Set<String> = [
        "mail.google.com",
        "mail-settings.google.com"
    ]

    public init(title: String, body: String, code: String? = nil, url: URL? = nil) {
        self.title = title
        self.body = body
        self.code = code
        self.url = url
    }

    public static func fromPayload(_ payload: [String: Any]) -> RelayNotification {
        let sender = payload["sender"] as? String ?? "Unknown sender"
        let type = payload["type"] as? String ?? "otp"

        switch type {
        case "forward_confirm":
            let code = payload["code"] as? String
            let rawUrl = payload["url"] as? String
            let from = payload["forwarding_from"] as? String

            let title = "Email forwarding confirmation"
            var parts: [String] = []
            if let from = from {
                parts.append("Forwarding from \(from)")
            }
            if let code = code {
                parts.append("Code: \(code)")
            }
            if let rawUrl = rawUrl {
                parts.append(rawUrl)
            }
            if from == nil {
                parts.append("From \(sender)")
            }
            let body = parts.joined(separator: "\n")

            return RelayNotification(
                title: title,
                body: body,
                code: code,
                url: confirmationUri(rawUrl)
            )

        default: // "otp"
            let otp = payload["otp"] as? String ?? "??????"
            // Older servers send no `verified` key; only an explicit false is marked.
            let unverified = (payload["verified"] as? Bool) == false
            let marker = unverified ? " (unverified)" : ""
            let title = "OTP from \(sender)\(marker)"
            return RelayNotification(
                title: title,
                body: otp,
                code: otp,
                url: nil
            )
        }
    }

    public static func isConfirmationUrlAllowed(_ url: URL) -> Bool {
        confirmationUri(url.absoluteString) != nil
    }

    /// Validates that a confirmation link is an https link to allowed Gmail confirmation hosts.
    public static func confirmationUri(_ raw: String?) -> URL? {
        guard let raw = raw, let components = URLComponents(string: raw) else {
            return nil
        }
        guard components.scheme == "https",
              let host = components.host,
              confirmationHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil
        else {
            return nil
        }
        return components.url
    }
}
