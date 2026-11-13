import Foundation

public struct RelayNotification: Equatable, Sendable {
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
            let validatedUrl = confirmationUri(rawUrl)

            var lines: [String] = []
            if let from = from { lines.append("Forwarding from \(from)") }
            if let code = code { lines.append("Code: \(code)") }
            if let rawUrl = rawUrl { lines.append(rawUrl) }
            if from == nil { lines.append("From \(sender)") }

            return RelayNotification(
                title: "Email forwarding confirmation",
                body: lines.joined(separator: "\n"),
                code: code,
                url: validatedUrl
            )

        case "otp":
            fallthrough
        default:
            let otp = payload["otp"] as? String ?? "??????"
            let marker = (payload["verified"] as? Bool) == false ? " (unverified)" : ""
            return RelayNotification(
                title: "OTP from \(sender)\(marker)",
                body: otp,
                code: otp,
                url: nil
            )
        }
    }

    public static func confirmationUri(_ urlString: String?) -> URL? {
        guard let urlString = urlString, let url = URL(string: urlString) else {
            return nil
        }
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host,
              confirmationHosts.contains(host) else {
            return nil
        }
        return url
    }
}
