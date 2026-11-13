import Foundation

public struct OtpSender: Equatable, Hashable, Identifiable {
    public var id: String { bank }
    public let bank: String
    public let from: String
    public let subject: String

    public init(bank: String, from: String, subject: String) {
        self.bank = bank
        self.from = from
        self.subject = subject
    }
}

public enum KnownSenders {
    public static let all: [OtpSender] = [
        OtpSender(
            bank: "HSBC (credit card)",
            from: "hsbc@hsbc.bank.in",
            subject: "Your HSBC Credit Card OTP"
        ),
        OtpSender(
            bank: "RBL Bank",
            from: "alerts@rbl.bank.in",
            subject: "One-Time Password for your online transaction"
        )
    ]
}
