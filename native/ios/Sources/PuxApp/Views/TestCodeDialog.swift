#if os(iOS)
import SwiftUI
import PuxCore

public struct TestCodeDialog: View {
    let testCode: TestCode
    let inbox: String
    @Environment(\.dismiss) private var dismiss

    public init(testCode: TestCode, inbox: String) {
        self.testCode = testCode
        self.inbox = inbox
    }

    public var body: some View {
        PuxStackNavigation {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Look for \"OTP from pux test\" with the code")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(testCode.otp)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .foregroundColor(PuxTheme.codeText)
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Test code \(testCode.otp)")

                    let others = testCode.devices > 1 ? " It went to all \(testCode.devices) devices on this relay." : ""
                    Text("On this phone it arrives as a notification within a few seconds.\(others)")
                        .font(.body)

                    Divider()

                    Text("This checks the server and push. To check that mail reaches the relay too, email \"Your OTP is 123456\" straight to \(inbox). It should arrive the same way, with 123456 as the code.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Test code sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#endif
