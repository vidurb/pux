#if os(iOS)
import SwiftUI
import PuxCore

public struct DeliveryBannerView: View {
    @ObservedObject var controller: DeliveryController
    let onForgetRelay: () -> Void

    public init(controller: DeliveryController, onForgetRelay: @escaping () -> Void) {
        self.controller = controller
        self.onForgetRelay = onForgetRelay
    }

    public var body: some View {
        let status = controller.status
        let undecryptableText = status.undecryptable > 0
            ? "\(status.undecryptable) message(s) could not be decrypted with this device's key."
            : nil

        if shouldShowBanner(status: status, undecryptable: undecryptableText) {
            VStack(alignment: .leading, spacing: 8) {
                if let mainText = bannerText(for: status) {
                    Text(mainText)
                        .font(.subheadline)
                        .foregroundColor(bannerColor(for: status))
                }

                if let undecryptable = undecryptableText {
                    Text(undecryptable)
                        .font(.subheadline)
                        .foregroundColor(PuxTheme.warningAction)
                }

                HStack {
                    Spacer()
                    bannerActions(for: status)
                }
            }
            .padding(12)
            .background(bannerColor(for: status).opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(bannerColor(for: status), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    private func shouldShowBanner(status: DeliveryStatus, undecryptable: String?) -> Bool {
        if undecryptable != nil { return true }
        switch status.state {
        case .idle, .ready: return false
        default: return true
        }
    }

    private func bannerText(for status: DeliveryStatus) -> String? {
        switch status.state {
        case .connecting:
            return "Connecting…"
        case .retrying:
            return "Not connected: \(status.message ?? "unknown error")"
        case .firebaseUnconfigured:
            return status.message ?? "Push notifications are not configured in this build."
        case .recordUnknown:
            return "The server no longer knows this relay. It may have expired after going a long time with no registered devices. Forget it on this device and create a new relay (then update your email forwarding)."
        case .tooManyDevices:
            return "This relay already has the maximum number of devices. On a device you no longer use, choose \"Remove this device\", then retry here."
        case .idle, .ready:
            return nil
        }
    }

    private func bannerColor(for status: DeliveryStatus) -> Color {
        switch status.state {
        case .connecting: return .secondary
        case .retrying: return PuxTheme.warningAction
        case .firebaseUnconfigured, .recordUnknown, .tooManyDevices: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private func bannerActions(for status: DeliveryStatus) -> some View {
        switch status.state {
        case .retrying:
            Button("Retry now") {
                Task { await controller.start() }
            }
            .font(.subheadline.bold())
            .foregroundColor(PuxTheme.warningAction)

        case .recordUnknown:
            Button("Forget relay") {
                onForgetRelay()
            }
            .font(.subheadline.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red)
            .cornerRadius(6)

        case .tooManyDevices:
            Button("Retry") {
                Task { await controller.start() }
            }
            .font(.subheadline.bold())
            .foregroundColor(.red)

        default:
            EmptyView()
        }
    }
}

#endif
