#if os(iOS)
import SwiftUI
import PuxCore

public struct NotificationExplainerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isAsking = false
    let onComplete: (Bool) -> Void

    public init(onComplete: @escaping (Bool) -> Void = { _ in }) {
        self.onComplete = onComplete
    }

    public var body: some View {
        PuxStackNavigation {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 64))
                            .foregroundColor(PuxTheme.primary)
                            .padding(.top, 32)

                        Text("Allow notifications to see your codes")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Text("Codes sent to your inbox address reach this device only as notifications. Without them, pux can't show you a code.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        Text("pux notifies you only when a code or a forwarding confirmation arrives. Nothing else is sent.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        Text("After you continue, your device asks whether to allow notifications from pux.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                    }
                    .padding()
                }

                VStack(spacing: 12) {
                    if isAsking {
                        ProgressView()
                            .padding(.bottom, 4)
                    }

                    Button(action: handleContinue) {
                        Text("Continue")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(PuxTheme.primary)
                            .foregroundColor(PuxTheme.onPrimary)
                            .cornerRadius(12)
                    }
                    .disabled(isAsking)

                    Button(action: handleNotNow) {
                        Text("Not now")
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .foregroundColor(.secondary)
                    }
                    .disabled(isAsking)
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleContinue() {
        isAsking = true
        Task {
            let granted = await NotificationPermissions.shared.ask()
            isAsking = false
            onComplete(granted)
            dismiss()
        }
    }

    private func handleNotNow() {
        try? RecordStore.shared.saveNotificationExplainerSkipped()
        onComplete(false)
        dismiss()
    }
}

#endif
