import SwiftUI
import PuxCore

public struct TestCodeDialog: View {
    public let sent: TestCodeResponse
    public let inbox: String
    public let onDismiss: () -> Void

    public init(sent: TestCodeResponse, inbox: String, onDismiss: @escaping () -> Void) {
        self.sent = sent
        self.inbox = inbox
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test code sent")
                .font(.headline)

            Text("Look for \"OTP from pux test\" with the code:")
                .foregroundColor(.secondary)

            Text(sent.otp)
                .font(.system(.title, design: .monospaced))
                .bold()
                .textSelection(.enabled)

            let deviceText = sent.devices > 1 ? " It went to all \(sent.devices) devices on this relay." : ""
            Text("Here it appears as a notification. If pux can't tell whether the notification showed, the code is also listed on this screen for a few minutes.\(deviceText)")
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            Text("This checks the server and push. To check that mail reaches the relay too, email \"Your OTP is 123456\" straight to \(inbox). It should arrive the same way, with 123456 as the code.")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
