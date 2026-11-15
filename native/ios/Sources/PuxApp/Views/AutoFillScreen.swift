#if os(iOS)
import SwiftUI
import PuxCore

@available(iOS 18.0, *)
public struct AutoFillScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = AutoFillStore().isEnabled
    @State private var sender = AutoFillStore().mapping?.senderDomain ?? ""
    @State private var website = AutoFillStore().mapping?.websiteDomain ?? ""
    @State private var status: String?
    @State private var testCode = ""

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Use received codes in AutoFill", isOn: $enabled)
                Text("Pux keeps your latest code available for five minutes. Enable Pux in Settings → General → AutoFill & Passwords too.")
                    .font(.footnote)
            } header: { Text("Keyboard AutoFill prototype") }

            Section {
                TextField("Email sender domain", text: $sender)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Website domain", text: $website)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Optional: associate one email sender with the website where you use its codes. Enter domains only, such as bank.example and login.bank.example. Suggestions require a verified sender. You can choose other codes from Pux’s AutoFill picker.")
                    .font(.footnote)
            } header: { Text("Suggest codes on a website") }

            Section {
                Button("Save AutoFill settings", action: save)
                if let status { Text(status).font(.footnote) }
                Text("After saving, receive a new OTP or use Send a test code on the home screen. In another app’s verification field, open AutoFill and select Pux. Test codes appear in the picker; they have no sender domain for website suggestions.")
                    .font(.footnote)
            }
#if DEBUG
            Section {
                SecureField("Verification code", text: $testCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                Text("This field lets you inspect the system’s OTP AutoFill controls. Use a real app or Safari to test website matching.")
                    .font(.footnote)
            } header: { Text("Try the keyboard") }
#endif
        }
        .navigationTitle("Keyboard AutoFill")
        .onChange(of: scenePhase) { phase in
            if phase == .active { AutoFillIdentities.refresh() }
        }
    }

    private func save() {
        let mapping: AutoFillMapping?
        if sender.isEmpty && website.isEmpty { mapping = nil }
        else {
            guard let value = AutoFillMapping(senderDomain: sender, websiteDomain: website) else {
                status = "Enter both domains without https://, paths, or email addresses."
                return
            }
            mapping = value
        }
        guard AutoFillStore().configure(enabled: enabled, mapping: mapping) else {
            status = "Could not save AutoFill settings. Unlock the device and try again."
            return
        }
        AutoFillIdentities.refresh { success in
            DispatchQueue.main.async {
                if !enabled {
                    status = "AutoFill is off. The stored code has been cleared."
                } else {
                    status = success
                        ? "Saved. Receive a new code to try AutoFill."
                        : "Saved. Enable Pux in AutoFill & Passwords, then return here."
                }
            }
        }
    }
}
#endif
