import SwiftUI
import PuxCore

public struct NotificationExplainerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: DeliveryController
    @State private var isAsking: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundColor(.accentColor)
                .padding(.top, 16)

            Text("Allow notifications to see your codes")
                .font(.title2)
                .bold()
                .multilineTextAlignment(.center)

            Text("When a code arrives, pux shows it as a notification. Without notifications, new codes wait on the home screen until they expire, up to 15 minutes after arriving.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)

            Text("pux notifies you only when a code or a forwarding confirmation arrives. Nothing else is sent.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)

            Text("After you continue, your device asks whether to allow notifications from pux.")
                .font(.footnote)
                .foregroundColor(.secondary)

            if isAsking {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            VStack(spacing: 8) {
                Button("Continue") {
                    handleContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .disabled(isAsking)

                Button("Not now") {
                    handleNotNow()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)
                .disabled(isAsking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func handleContinue() {
        isAsking = true
        Task {
            await controller.requestNotificationAccess()
            dismiss()
        }
    }

    private func handleNotNow() {
        Task {
            try? controller.recordStore.saveNotificationExplainerSkipped()
            dismiss()
        }
    }
}
