#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import PuxCore

public struct ForwardingHelpScreen: View {
    public let inbox: String?
    @State private var copied: Bool = false

    public init(inbox: String?) {
        self.inbox = inbox
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Forward only your bank's OTP emails, not your whole mailbox. Set up a filter in your email account that matches the sender and subject of those emails and forwards them to your inbox address.")
                    .font(.body)

                if let inbox = inbox {
                    HStack {
                        Text(inbox)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = inbox
                            copied = true
                        }) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .foregroundColor(PuxTheme.pine)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }

                sectionHeader("Gmail")
                Text("Filters can only be created on gmail.com in a browser, not in the Gmail app.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                let address = inbox ?? "your inbox address"
                stepList([
                    "Open Settings → See all settings → Forwarding and POP/IMAP.",
                    "Choose \"Add a forwarding address\" and enter \(address).",
                    "Gmail sends a confirmation to that address. It arrives in pux as a notification: tap it to open the confirmation link, or enter its code in Gmail. Leave forwarding itself disabled.",
                    "In the search bar, open the search options. Fill in From and Subject with the values for your bank (see below), then choose \"Create filter\".",
                    "Tick \"Forward it to\", pick your inbox address, and create the filter."
                ])

                sectionHeader("Outlook.com")
                stepList([
                    "Open Settings → Mail → Rules → Add new rule.",
                    "Add the conditions \"From\" and \"Subject includes\" with the values for your bank (see below).",
                    "Add the action \"Redirect to\" and enter \(address). Use Redirect rather than Forward, so the bank stays the sender and its name can be verified."
                ])

                sectionHeader("Other providers")
                Text("Most providers support rules or filters that forward matching mail. Prefer an option that keeps the original sender (often called redirect). If your bank appears as unverified in pux, the forwarding changed the message.")
                    .font(.body)

                sectionHeader("Known bank OTP emails")
                Text("Check an OTP email in your own inbox first: banks use different senders for different products and change them over time.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(KnownSenders.all) { sender in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sender.bank)
                            .font(.subheadline.bold())
                        Text("From: \(sender.from)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Text("Subject: \(sender.subject)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }

                sectionHeader("Test it")
                Text("To check the relay, email \"Your OTP is 123456\" straight to your inbox address; a notification should arrive within a few seconds. Your next bank OTP checks the filter itself.")
                    .font(.body)
            }
            .padding(16)
        }
        .navigationTitle("Set up forwarding")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 8)
    }

    private func stepList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.subheadline.bold())
                        .frame(width: 20, alignment: .leading)
                    Text(step)
                        .font(.subheadline)
                }
            }
        }
    }
}
#endif


#endif
