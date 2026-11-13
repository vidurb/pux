import SwiftUI
import PuxCore

public struct ServerStatusView: View {
    @EnvironmentObject var controller: DeliveryController
    @State private var isRefreshing: Bool = false

    public init() {}

    private var serverHost: String {
        let raw = controller.recordStore.serverUrl
        guard let url = URL(string: raw) else { return raw }
        if let port = url.port {
            return "\(url.host ?? ""):\(port)"
        }
        return url.host ?? raw
    }

    public var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text("Server: \(serverHost)")
                    .font(.subheadline)
                    .bold()
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            Spacer()

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help("Check again")
            .accessibilityLabel("Check server health again")
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.serverHealth.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .unreachable:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(PuxColors.warningText)
        case .serverError:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(PuxColors.errorText)
        }
    }

    private var statusSubtitle: String {
        let reason = controller.serverHealth.reason.map { ": \($0)" } ?? ""
        switch controller.serverHealth.state {
        case .checking:
            return "Checking…"
        case .reachable:
            return "Reachable"
        case .unreachable:
            return "Can't reach the server\(reason)"
        case .serverError:
            return "Server error\(reason)"
        }
    }

    private var statusColor: Color {
        switch controller.serverHealth.state {
        case .checking:
            return .secondary
        case .reachable:
            return .secondary
        case .unreachable:
            return PuxColors.warningText
        case .serverError:
            return PuxColors.errorText
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await controller.checkHealth(userAsked: true)
            isRefreshing = false
        }
    }
}
