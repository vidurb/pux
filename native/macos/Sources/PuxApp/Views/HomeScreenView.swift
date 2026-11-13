import SwiftUI
import PuxCore

public struct HomeScreenView: View {
    @EnvironmentObject var controller: DeliveryController
    @Environment(\.scenePhase) private var scenePhase
    public let onOpenSettings: () -> Void
    public let onOpenHelp: () -> Void

    @State private var showingCopyJsonAlert: Bool = false
    @State private var showingRemoveDeviceAlert: Bool = false
    @State private var showingRemoveDeviceError: Bool = false
    @State private var removeDeviceError: String? = nil
    @State private var showingRelayRemovalError: Bool = false
    @State private var relayRemovalError: String? = nil
    @State private var showingDeleteRelaySheet: Bool = false
    @State private var showingForgetMacAlert: Bool = false
    @State private var forgetLocalPending: PendingRemoval? = nil
    @State private var testCodeResponse: TestCodeResponse? = nil
    @State private var isSendingTest: Bool = false
    @State private var testCodeError: String? = nil
    @State private var showingTestCodeError: Bool = false
    @State private var alertErrorMessage: String? = nil
    @State private var enrollmentJson: String? = nil

    public init(onOpenSettings: @escaping () -> Void, onOpenHelp: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onOpenHelp = onOpenHelp
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let err = controller.storageError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Secure storage warning: \(err)")
                            .font(.callout)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if let pending = controller.pendingRemoval {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Removal needs to be completed").bold()
                            if pending == .deviceLimit {
                                Text("The relay is full. Free a device slot and retry, or forget the enrollment on this Mac only.")
                                    .font(.caption)
                                    .foregroundColor(PuxColors.warningCaptionOnTint)
                            } else {
                                Text(pendingRemovalCaption(pending))
                                    .font(.caption)
                                    .foregroundColor(PuxColors.warningCaptionOnTint)
                            }
                            HStack {
                                Button("Retry removal") {
                                    if pending == .relay {
                                        showingDeleteRelaySheet = true
                                    } else {
                                        showingRemoveDeviceAlert = true
                                    }
                                }
                                .disabled(controller.removing)
                                Button("Cancel") {
                                    Task { try? await controller.cancelPendingRemoval() }
                                }
                                .disabled(controller.removing)
                                if pending == .deviceLimit {
                                    Button("Forget on this Mac…") { showingForgetMacAlert = true }
                                        .disabled(controller.removing)
                                } else {
                                    Button("Forget locally anyway") {
                                        forgetLocalPending = pending
                                    }
                                    .disabled(controller.removing)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PuxColors.warningBannerFill)
                    .cornerRadius(8)
                }

                deliveryBanner

                ServerStatusView()

                notificationPrompt

                HeldCodesView()

                inboxCard

                exportCard

                actionButtons
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            Task { await controller.refreshNotificationAccess() }
            loadEnrollmentJson()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await controller.refreshNotificationAccess() } }
        }
        .sheet(item: $testCodeResponse) { resp in
            TestCodeDialog(
                sent: resp,
                inbox: controller.currentInbox ?? "your inbox",
                onDismiss: { testCodeResponse = nil }
            )
        }
        .sheet(isPresented: $showingDeleteRelaySheet) {
            DeleteRelayDialog(
                onConfirm: {
                    do {
                        try await controller.deleteRelayEverywhere()
                        showingDeleteRelaySheet = false
                    } catch {
                        relayRemovalError = error.localizedDescription
                        showingDeleteRelaySheet = false
                        showingRelayRemovalError = true
                    }
                },
                onCancel: {
                    showingDeleteRelaySheet = false
                }
            )
        }
        .alert("Copy enrollment JSON?", isPresented: $showingCopyJsonAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Copy") {
                if let json = enrollmentJson {
                    SensitiveClipboard.shared.copy(json)
                }
            }
        } message: {
            Text("This contains your private key and relay ID. Anyone who has it can read your OTP codes. Paste it only into your own desktop app, then clear your clipboard.")
        }
        .alert("Remove this device?", isPresented: $showingRemoveDeviceAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await controller.removeThisDevice()
                    } catch {
                        removeDeviceError = error.localizedDescription
                        showingRemoveDeviceError = true
                    }
                }
            }
        } message: {
            Text("This device stops receiving codes and its keys are deleted from it. Other devices on this relay keep working. To use pux here again you will need to import a relay.")
        }
        .alert("Couldn't remove this device from the server", isPresented: $showingRemoveDeviceError, presenting: removeDeviceError) { _ in
            Button("Forget locally anyway", role: .destructive) {
                Task { try? await controller.forgetLocallyAfterFailedRemoval() }
            }
            Button("Try again") {
                showingRemoveDeviceAlert = true
            }
            Button("Cancel") {
                Task { try? await controller.cancelPendingRemoval() }
            }
        } message: { error in
            Text("The server could not be reached or refused: \(error)\n\nIf you forget it locally, the server may keep this registration until it expires, which might take up to 2 years.")
        }
        .alert("Forget locally anyway?", isPresented: Binding(
            get: { forgetLocalPending != nil },
            set: { if !$0 { forgetLocalPending = nil } }
        ), presenting: forgetLocalPending) { pending in
            Button("Forget locally anyway", role: .destructive) {
                Task {
                    try? await controller.forgetLocallyAfterFailedRemoval()
                    forgetLocalPending = nil
                }
            }
            Button("Cancel", role: .cancel) { forgetLocalPending = nil }
        } message: { pending in
            if pending == .relay {
                Text("If you forget it locally, the relay may keep running on the server and your other devices might keep receiving codes.")
            } else {
                Text("If you forget it locally, the server may keep this registration until it expires, which might take up to 2 years.")
            }
        }
        .alert("Couldn't delete the relay", isPresented: $showingRelayRemovalError, presenting: relayRemovalError) { _ in
            Button("Forget locally anyway", role: .destructive) {
                Task { try? await controller.forgetLocallyAfterFailedRemoval() }
            }
            Button("Try again") {
                showingDeleteRelaySheet = true
            }
            Button("Cancel") {
                Task { try? await controller.cancelPendingRemoval() }
            }
        } message: { error in
            Text("The server could not be reached or refused: \(error)\n\nIf you forget it locally, the relay may keep running on the server and your other devices might keep receiving codes.")
        }
        .alert("Forget enrollment on this Mac?", isPresented: $showingForgetMacAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget on this Mac", role: .destructive) {
                Task {
                    do {
                        try await controller.forgetThisMacAfterDeviceLimit()
                    } catch {
                        removeDeviceError = error.localizedDescription
                        showingRemoveDeviceError = true
                    }
                }
            }
        } message: {
            Text("This deletes the local relay keys and stops delivery on this Mac. Server removal is not confirmed: a device registration could still exist or appear later. To use this relay here again, you will need to import it.")
        }
        .alert("Test code failed", isPresented: $showingTestCodeError, presenting: testCodeError) { _ in
            Button("Try again") {
                sendTestCode()
            }
            Button("Cancel", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Delivery Banner

    @ViewBuilder
    private var deliveryBanner: some View {
        switch controller.status.state {
        case .connecting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

        case .retrying:
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(PuxColors.warningText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not connected")
                        .bold()
                    Text(controller.status.message ?? "unknown error")
                        .font(.caption)
                        .foregroundColor(PuxColors.warningCaptionOnTint)
                }
                Spacer()
                Button("Retry now") {
                    Task { await controller.start() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PuxColors.warningBannerFill)
            .cornerRadius(8)

        case .recordUnknown:
            HStack(alignment: .top) {
                Image(systemName: "xmark.circle")
                    .foregroundColor(PuxColors.errorText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The server no longer knows this relay. It may have expired after going a long time with no registered devices. Forget it on this device and create a new relay (then update your email forwarding).")
                        .font(.callout)
                        .foregroundColor(PuxColors.errorText)
                    Button("Forget relay") {
                        Task { do { try await controller.forgetUnknownRelayLocally() } catch { /* The controller displays the storage error. */ } }
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)

        case .tooManyDevices:
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(PuxColors.errorText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("This relay already has the maximum number of devices. On a device you no longer use, choose \"Remove this device\", then retry here.")
                        .font(.callout)
                        .foregroundColor(PuxColors.errorText)
                    Button("Retry") {
                        Task { await controller.start() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)

        case .ready, .idle:
            if controller.status.undecryptable > 0 {
                Text("\(controller.status.undecryptable) message(s) could not be decrypted with this device's key.")
                    .font(.callout)
                    .foregroundColor(PuxColors.warningText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PuxColors.warningBannerFill)
                    .cornerRadius(8)
            } else {
                EmptyView()
            }
        }
    }

    private func pendingRemovalCaption(_ pending: PendingRemoval) -> String {
        var base = "Delivery is paused until removal succeeds. Connect to the server and try again."
        if pending == .deviceReconciling || pending == .deviceDeleting {
            base += " If an earlier registration's outcome was unknown, the server might still hold a stale registration after removal; deleting the relay on the server might clear it."
        }
        return base
    }

    // MARK: - Notification Prompt

    @ViewBuilder
    private var notificationPrompt: some View {
        if controller.notificationAccess != .allowed {
            HStack {
                Image(systemName: "bell.slash").foregroundColor(PuxColors.warningText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.notificationAccess == .quiet ? "Notifications are quiet" : "Notifications are off")
                        .bold()
                        .foregroundColor(PuxColors.warningText)
                    Text(controller.notificationAccess == .quiet
                         ? "Alerts may be delivered quietly. Codes will remain available here."
                         : "Codes will wait on this screen instead of popping up.")
                        .font(.caption)
                        .foregroundColor(PuxColors.warningCaptionOnTint)
                }
                Spacer()
                if controller.notificationAccess == .notAsked {
                    Button("Allow notifications") {
                        Task { await controller.requestNotificationAccess() }
                    }
                    .disabled(controller.requestingNotifications)
                    .controlSize(.small)
                } else {
                    Button("Settings") { NotificationPermissions.openSettings() }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(PuxColors.warningBannerFill)
            .cornerRadius(8)
        }
    }

    // MARK: - Cards

    private var inboxCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay inbox")
                .font(.headline)

            if let inbox = controller.currentInbox {
                HStack {
                    Text(inbox)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        SensitiveClipboard.shared.copy(inbox)
                    }
                    .controlSize(.small)
                }
            } else {
                Text("No inbox available")
                    .foregroundColor(.secondary)
            }

            Button("How to forward mail…") {
                onOpenHelp()
            }
            .font(.footnote)
            .buttonStyle(.link)
        }
        .puxCardStyle()
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup & Transfer")
                .font(.headline)

            Text("Transfer this relay to another computer, or save a backup.")
                .font(.callout)
                .foregroundColor(.secondary)

            Button("Copy enrollment JSON") {
                showingCopyJsonAlert = true
            }
            .controlSize(.small)
        }
        .puxCardStyle()
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Desktop settings…") {
                    onOpenSettings()
                }

                Spacer()

                Button {
                    sendTestCode()
                } label: {
                    if isSendingTest {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send test code")
                    }
                }
                .disabled(isSendingTest)
            }

            Divider()

            HStack {
                Button("Remove this device") {
                    showingRemoveDeviceAlert = true
                }
                .foregroundColor(.red)

                Spacer()

                Button("Delete relay everywhere…") {
                    showingDeleteRelaySheet = true
                }
                .foregroundColor(.red)
            }
        }
        .padding(.top, 12)
    }

    private func loadEnrollmentJson() {
        Task {
            if let payload = try? controller.recordStore.enrollmentPayload() {
                enrollmentJson = payload.asJsonString()
            }
        }
    }

    private func sendTestCode() {
        isSendingTest = true
        testCodeError = nil
        Task {
            do {
                let resp = try await controller.sendTestCode()
                testCodeResponse = resp
            } catch {
                testCodeError = error.localizedDescription
                showingTestCodeError = true
            }
            isSendingTest = false
        }
    }
}

extension TestCodeResponse: Identifiable {
    public var id: String { otp }
}
