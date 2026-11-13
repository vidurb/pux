import SwiftUI
import PuxCore

public struct OtpSenderInfo: Identifiable {
    public var id: String { bank }
    public let bank: String
    public let from: String
    public let subject: String
}

public struct ForwardingHelpView: View {
    @Environment(\.dismiss) private var dismiss
    public let inbox: String?

    public static let knownSenders: [OtpSenderInfo] = [
        OtpSenderInfo(
            bank: "HSBC (credit card)",
            from: "hsbc@hsbc.bank.in",
            subject: "Your HSBC Credit Card OTP"
        ),
        OtpSenderInfo(
            bank: "RBL Bank",
            from: "alerts@rbl.bank.in",
            subject: "One-Time Password for your online transaction"
        )
    ]

    public init(inbox: String?) {
        self.inbox = inbox
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set up forwarding")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Forward only your bank's OTP emails, not your whole mailbox. Set up a filter in your email account that matches the sender and subject of those emails and forwards them to your inbox address.")
                        .foregroundColor(.secondary)

                    if let inbox = inbox {
                        HStack {
                            Text(inbox)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy inbox address") {
                                SensitiveClipboard.shared.copy(inbox)
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }

                    // Gmail
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gmail")
                            .font(.headline)
                        Text("Filters can only be created on gmail.com in a browser, not in the Gmail app.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("1. Open Settings → See all settings → Forwarding and POP/IMAP.\n" +
                             "2. Choose \"Add a forwarding address\" and enter your inbox address.\n" +
                             "3. Gmail sends a confirmation to that address. It arrives in pux as a notification: tap it to open the confirmation link, or enter its code in Gmail. Leave forwarding itself disabled.\n" +
                             "4. In the search bar, open the search options. Fill in From and Subject with the values for your bank, then choose \"Create filter\".\n" +
                             "5. Tick \"Forward it to\", pick your inbox address, and create the filter.")
                            .font(.callout)
                    }

                    Divider()

                    // Outlook
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Outlook.com")
                            .font(.headline)
                        Text("1. Open Settings → Mail → Rules → Add new rule.\n" +
                             "2. Add the conditions \"From\" and \"Subject includes\" with the values for your bank.\n" +
                             "3. Add the action \"Redirect to\" and enter your inbox address. Use Redirect rather than Forward, so the bank stays the sender and its name can be verified.")
                            .font(.callout)
                    }

                    Divider()

                    // Known senders
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Known bank OTP emails")
                            .font(.headline)
                        Text("Check an OTP email in your own inbox first: banks use different senders for different products and change them over time.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        ForEach(Self.knownSenders) { sender in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sender.bank).font(.subheadline).bold()
                                Text("From: \(sender.from)").font(.caption).textSelection(.enabled)
                                Text("Subject: \(sender.subject)").font(.caption).textSelection(.enabled)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }

                    Divider()

                    // Testing
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Test it")
                            .font(.headline)
                        Text("To check the relay, email \"Your OTP is 123456\" straight to your inbox address; a notification should arrive within a few seconds.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 520)
    }
}
