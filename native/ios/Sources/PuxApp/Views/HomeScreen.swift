#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import PuxCore

public struct HomeScreen: View {
    @ObservedObject private var deliveryController = DeliveryController.shared
    @ObservedObject private var permissions = NotificationPermissions.shared

    @State private var inbox: String?
    @State private var enrollmentJson: String?
    @State private var showQr = false
    @State private var showTestCodeDialog = false
    @State private var testCodeResult: TestCode?
    @State private var isSendingTestCode = false
    @State private var isRemoving = false
    @State private var showDeleteRelayDialog = false
    @State private var showRemoveDeviceAlert = false
    @State private var showCopyJsonAlert = false
    @State private var showNotificationExplainer = false
    @State private var copiedNotice: String?
    @State private var copiedInboxNotice: String?
    @State private var testCodeSnack: String?

    @State private var removalAlert: RemovalFailureAlert?

    let onRelayForgotten: () -> Void

    public init(onRelayForgotten: @escaping () -> Void) {
        self.onRelayForgotten = onRelayForgotten
    }

    public var body: some View {
        PuxStackNavigation {
            ScrollView {
                VStack(spacing: 20) {
                    DeliveryPromptView(permissions: permissions)

                    ServerStatusView()

                    DeliveryBannerView(
                        controller: deliveryController,
                        onForgetRelay: {
                            handleForgetLocally()
                        }
                    )

                    if let inboxAddress = inbox {
                        inboxSection(address: inboxAddress)
                    }

                    if showQr, let json = enrollmentJson {
                        addDeviceSection(json: json)
                    }
                }
                .padding(16)
            }
            .background(PuxTheme.background.ignoresSafeArea())
            .navigationTitle("pux")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showQr.toggle() }) {
                        Image(systemName: showQr ? "qrcode.viewfinder" : "qrcode")
                            .foregroundColor(PuxTheme.primary)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(showQr ? "Hide add-device QR code" : "Add device")
                    .accessibilityHint("Shows a QR code to enroll another device on this relay")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showRemoveDeviceAlert = true }) {
                            Label("Remove this device", systemImage: "minus.circle")
                        }

                        Button(role: .destructive, action: { showDeleteRelayDialog = true }) {
                            Label("Delete relay everywhere", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(PuxTheme.primary)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Relay actions")
                    .accessibilityHint("Remove this device or delete the relay everywhere")
                    .disabled(isRemoving)
                }
            }
            .overlay(alignment: .bottom) {
                if let snack = testCodeSnack {
                    Text(snack)
                        .font(.footnote)
                        .foregroundColor(PuxTheme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(PuxTheme.cardBackground)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                        .padding()
                        .onAppear {
                            Task {
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                                await MainActor.run { testCodeSnack = nil }
                            }
                        }
                }
            }
            .onAppear {
                loadEnrollmentData()
                Task {
                    _ = await permissions.check()
                    checkNotificationExplainer()
                    if deliveryController.status.state == .idle {
                        await deliveryController.start()
                    }
                }
            }
            .sheet(isPresented: $showTestCodeDialog) {
                if let test = testCodeResult, let inboxAddr = inbox {
                    TestCodeDialog(testCode: test, inbox: inboxAddr)
                }
            }
            .sheet(isPresented: $showDeleteRelayDialog) {
                DeleteRelayDialog(isPresented: $showDeleteRelayDialog) {
                    handleDeleteRelay()
                }
            }
            .sheet(isPresented: $showNotificationExplainer) {
                NotificationExplainerView()
            }
            .alert("Copy enrollment JSON?", isPresented: $showCopyJsonAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Copy") {
                    if let json = enrollmentJson {
                        SensitiveClipboard.shared.copy(json)
                        copiedNotice = "Enrollment JSON copied. It is cleared from the clipboard in a minute."
                    }
                }
            } message: {
                Text("This contains your private key and relay ID. Anyone who has it can read your OTP codes. Paste it only into your own desktop app, then clear your clipboard.")
            }
            .alert("Remove this device?", isPresented: $showRemoveDeviceAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    handleRemoveDevice()
                }
            } message: {
                Text("This device will stop receiving codes. Other devices on this relay will keep working. If this is the only device, the relay cannot receive codes until you enroll another.")
            }
            .alert(
                removalAlert?.title ?? "",
                isPresented: Binding(
                    get: { removalAlert != nil },
                    set: { if !$0 { removalAlert = nil } }
                ),
                presenting: removalAlert
            ) { alert in
                Button("Try again") {
                    alert.onRetry()
                }
                if alert.allowLocalForget {
                    Button("Forget locally anyway", role: .destructive) { alert.onForgetLocally() }
                }
                if alert.allowResume {
                    Button("Keep relay and resume", role: .cancel) { resumeDelivery() }
                }
            } message: { alert in
                Text(alert.message)
            }

        }
    }

    private func notificationWarningBanner(title: String, message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(PuxTheme.amber)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(PuxTheme.amber)
            }

            Text(message)
                .font(.footnote)
                .foregroundColor(PuxTheme.text)

            Button(action: action) {
                Text(buttonTitle)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(PuxTheme.amber.opacity(0.15))
                    .foregroundColor(PuxTheme.amber)
                    .cornerRadius(6)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PuxTheme.amberBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(PuxTheme.amber.opacity(0.4), lineWidth: 1)
        )
    }

    private func inboxSection(address: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward OTP emails to:")
                .font(.headline)
                .foregroundColor(PuxTheme.text)

            Text(address)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(PuxTheme.text)
                .textSelection(.enabled)

            if let notice = copiedInboxNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(PuxTheme.success)
            }

            Button(action: {
                UIPasteboard.general.string = address
                copiedInboxNotice = "Inbox address copied."
            }) {
                Text("Copy inbox address")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(PuxTheme.primary)
                    .foregroundColor(PuxTheme.onPrimary)
                    .cornerRadius(8)
            }

            NavigationLink(destination: ForwardingHelpScreen(inbox: address)) {
                HStack {
                    Image(systemName: "questionmark.circle")
                    Text("How to set up forwarding")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(10)
                .foregroundColor(PuxTheme.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PuxTheme.border, lineWidth: 1)
                )
            }

            Button(action: handleSendTestCode) {
                HStack {
                    if isSendingTestCode {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane")
                    }
                    Text("Send a test code")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(10)
                .foregroundColor(PuxTheme.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PuxTheme.border, lineWidth: 1)
                )
            }
            .disabled(isSendingTestCode)
        }
        .padding()
        .background(PuxTheme.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func addDeviceSection(json: String) -> some View {
        VStack(spacing: 12) {
            Text("Add another device")
                .font(.headline)
                .foregroundColor(PuxTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            QRCodeView(content: json, size: 220)

            Text("Scan this QR on another phone, or copy the enrollment JSON and paste it into the desktop app. Both contain your private key: only use them with devices you trust.")
                .font(.caption)
                .foregroundColor(PuxTheme.amber)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: { showCopyJsonAlert = true }) {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy enrollment JSON")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(10)
                .foregroundColor(PuxTheme.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PuxTheme.border, lineWidth: 1)
                )
            }

            if let notice = copiedNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(PuxTheme.success)
            }
        }
        .padding()
        .background(PuxTheme.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func loadEnrollmentData() {
        inbox = RecordStore.shared.inbox()
        if let payload = try? RecordStore.shared.enrollmentPayload(),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            enrollmentJson = str
        }
    }

    private func checkNotificationExplainer() {
        if !RecordStore.shared.notificationExplainerSkipped() {
            if permissions.status == .notAsked {
                showNotificationExplainer = true
            }
        }
    }

    private func handleSendTestCode() {
        guard let recordId = RecordStore.shared.recordId() else { return }
        isSendingTestCode = true
        Task {
            do {
                let code = try await ApiClient.shared.sendTestCode(recordId: recordId)
                testCodeResult = code
                showTestCodeDialog = true
            } catch {
                testCodeSnack = Self.testCodeFailureMessage(error)
            }
            isSendingTestCode = false
        }
    }

    private static func testCodeFailureMessage(_ error: Error) -> String {
        if let err = error as? PuxError {
            switch err {
            case .rateLimited:
                return "Too many test codes for now. Wait a minute, then try again."
            case .noDevices:
                return "No device is registered on this relay yet. Wait until this device has connected, then try again."
            case .recordNotFound:
                return "The server no longer knows this relay."
            default:
                break
            }
        }
        return "Couldn't send a test code: \(error.localizedDescription)"
    }

    private func handleRemoveDevice() {
        executeRemoval(
            intent: .device,
            title: "Couldn't remove this device from the server",
            warning: "If you forget it locally, the server keeps this registration until it expires, which can take up to 2 years.",
            serverCall: {
                try await deliveryController.removeDevice()
            }
        )
    }

    private func handleDeleteRelay() {
        guard let recordId = RecordStore.shared.recordId() else {
            handleForgetLocally()
            return
        }

        executeRemoval(
            intent: .relay,
            title: "Couldn't delete the relay",
            warning: "If you forget it locally, the relay keeps running on the server and your other devices keep receiving codes.",
            serverCall: {
                try await ApiClient.shared.deleteRecord(recordId: recordId)
            }
        )
    }

    private func executeRemoval(
        intent: RemovalIntent,
        title: String,
        warning: String,
        serverCall: @escaping () async throws -> Void
    ) {
        isRemoving = true
        Task {
            do {
                try await deliveryController.prepareRemoval(intent)
                try await serverCall()
                handleForgetLocally()
            } catch {
                isRemoving = false
                removalAlert = RemovalFailureAlert(
                    title: title,
                    message: "The server could not be reached or refused: \(error.localizedDescription)\n\n\(warning)",
                    onRetry: {
                        executeRemoval(intent: intent, title: title, warning: warning, serverCall: serverCall)
                    },
                    onForgetLocally: {
                        handleForgetLocally()
                    },
                    allowLocalForget: true,
                    allowResume: true
                )
            }
        }
    }

    private func resumeDelivery() {
        Task {
            do {
                try await deliveryController.endRemoval(resume: true)
            } catch {
                removalAlert = RemovalFailureAlert(
                    title: "Couldn't resume delivery",
                    message: "\(error.localizedDescription)\n\nDelivery remains paused. Retry resuming when Keychain is available.",
                    onRetry: { resumeDelivery() },
                    onForgetLocally: {},
                    allowLocalForget: false,
                    allowResume: false
                )
            }
        }
    }

    private func handleForgetLocally() {
        isRemoving = true
        Task {
            do {
                try await deliveryController.finishRemovalLocally()
                isRemoving = false
                onRelayForgotten()
            } catch {
                isRemoving = false
                let canResume: Bool
                do { canResume = try RecordStore.shared.removalIntent() == nil }
                catch { canResume = false }
                removalAlert = RemovalFailureAlert(
                    title: "Couldn't clear local credentials",
                    message: "\(error.localizedDescription)\n\nDelivery remains paused. Retry clearing credentials" + (canResume ? " or explicitly resume delivery." : "."),
                    onRetry: { handleForgetLocally() },
                    onForgetLocally: {},
                    allowLocalForget: false,
                    allowResume: canResume
                )
            }
        }
    }
}

public struct RemovalFailureAlert: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let onRetry: () -> Void
    public let onForgetLocally: () -> Void
    public let allowLocalForget: Bool
    public let allowResume: Bool
}
#endif

#endif
