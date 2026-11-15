import Foundation

/// A short-lived view of an OTP. The cache stores only the original sealed envelope.
public struct AutoFillCode {
    public static let lifetime: TimeInterval = 300
    public let code: String
    public let sender: String
    public let senderDomain: String?
    public let verified: Bool
    public let receivedAt: Date

    public init?(payload: [String: Any], now: Date = Date()) {
        guard (payload["type"] as? String ?? "otp") == "otp",
              let code = payload["otp"] as? String,
              (4...12).contains(code.count),
              code.utf8.allSatisfy({ (48...57).contains($0) }),
              let timestamp = payload["received_at"] as? String
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        guard let date, date <= now, now.timeIntervalSince(date) < Self.lifetime else { return nil }
        self.code = code
        sender = payload["sender"] as? String ?? "Unknown sender"
        senderDomain = AutoFillMapping.domain(payload["sender_domain"] as? String ?? "")
        verified = (payload["verified"] as? Bool) == true
        receivedAt = date
    }
}

/// One explicit sender-to-website association for the prototype. Never guess a checkout domain.
public struct AutoFillMapping: Codable, Equatable {
    public let senderDomain: String
    public let websiteDomain: String

    public init?(senderDomain: String, websiteDomain: String) {
        guard let sender = Self.domain(senderDomain), let website = Self.domain(websiteDomain) else { return nil }
        self.senderDomain = sender
        self.websiteDomain = website
    }

    public func matches(_ code: AutoFillCode) -> Bool {
        code.verified && code.senderDomain == senderDomain
    }

    public static func domain(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return host
    }
}

public struct AutoFillStore {
    public static let enabledKey = "autofill_enabled"
    public static let envelopeKey = "autofill_envelope"
    public static let mappingKey = "autofill_mapping"
    private let backend: any PuxKeychainBackend

    public init(backend: any PuxKeychainBackend = PuxKeychain.backend) {
        self.backend = backend
    }

    private func read(_ key: String) -> String? {
        if case .found(let value) = backend.readStatus(key) { return value }
        return nil
    }

    public var isEnabled: Bool { read(Self.enabledKey) == "true" }
    public var mapping: AutoFillMapping? {
        guard let raw = read(Self.mappingKey), let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AutoFillMapping.self, from: data)
        else { return nil }
        return AutoFillMapping(senderDomain: decoded.senderDomain, websiteDomain: decoded.websiteDomain)
    }

    @discardableResult
    public func configure(enabled: Bool, mapping: AutoFillMapping?) -> Bool {
        // Disable first, so a failed write cannot leave the feature partially enabled.
        guard backend.write(Self.enabledKey, value: "false"), backend.delete(Self.envelopeKey) else { return false }
        if let mapping {
            guard let data = try? JSONEncoder().encode(mapping), let raw = String(data: data, encoding: .utf8),
                  backend.write(Self.mappingKey, value: raw) else { return false }
        } else if !backend.delete(Self.mappingKey) { return false }
        return backend.write(Self.enabledKey, value: enabled ? "true" : "false")
    }

    /// Keep the newest valid OTP only. Forwarding confirmations never replace it.
    @discardableResult
    public func capture(ciphertext: String, payload: [String: Any], now: Date = Date()) -> Bool {
        guard isEnabled, let code = AutoFillCode(payload: payload, now: now),
              let record = read("record_id") else { return false }
        if let previous = latest(now: now), previous.receivedAt > code.receivedAt { return false }
        let envelope = ["ciphertext": ciphertext, "record_id": record]
        guard let data = try? JSONEncoder().encode(envelope), let raw = String(data: data, encoding: .utf8) else { return false }
        return backend.write(Self.envelopeKey, value: raw)
    }

    public func latest(now: Date = Date()) -> AutoFillCode? {
        guard isEnabled,
              let raw = read(Self.envelopeKey), let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode([String: String].self, from: data),
              let record = read("record_id"), envelope["record_id"] == record,
              let ciphertext = envelope["ciphertext"],
              let publicKey = read("public_key"), let privateKey = read("private_key"),
              let payload = try? CryptoService.shared.openSealed(
                  ciphertextB64: ciphertext, publicKeyB64: publicKey, privateKeyB64: privateKey
              ) else { return nil }
        // Recheck expiry on every read, including immediately before filling.
        return AutoFillCode(payload: payload, now: now)
    }
}
