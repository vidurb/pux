#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import PuxCore

public struct ServerStatusView: View {
  @State private var health: ServerHealth?
  @State private var isChecking = false
  private let apiClient: ApiClient
  private let recordStore: RecordStore

  public init(
    apiClient: ApiClient = .shared,
    recordStore: RecordStore = .shared
  ) {
    self.apiClient = apiClient
    self.recordStore = recordStore
  }

  public var body: some View {
    HStack(spacing: 12) {
      statusIcon
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text("Server: \(hostString)")
          .font(.subheadline.weight(.medium))

        Text(statusSubtitle)
          .font(.caption)
          .foregroundColor(statusColor)
      }

      Spacer()

      Button(action: {
        Task { await checkHealth(userAsked: true) }
      }) {
        Image(systemName: "arrow.clockwise")
          .foregroundColor(PuxTheme.primary)
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityLabel("Check again")
      .accessibilityHint("Checks whether the pux server is reachable")
      .disabled(isChecking)
    }
    .padding(12)
    .background(Color(UIColor.secondarySystemBackground))
    .cornerRadius(10)
    .onAppear {
      Task { await checkHealth(userAsked: false) }
    }
  }

  private var hostString: String {
    guard let url = URL(string: recordStore.serverUrl) else { return recordStore.serverUrl }
    if let port = url.port {
      return "\(url.host ?? ""):\(port)"
    }
    return url.host ?? recordStore.serverUrl
  }

  @ViewBuilder
  private var statusIcon: some View {
    if isChecking || health == nil {
      ProgressView()
        .scaleEffect(0.8)
    } else {
      switch health!.state {
      case .reachable:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
      case .unreachable:
        Image(systemName: "icloud.slash.fill")
          .foregroundColor(PuxTheme.warningAction)
      case .serverError:
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundColor(PuxTheme.errorText)
      }
    }
  }

  private var statusSubtitle: String {
    if isChecking { return "Checking…" }
    guard let health else { return "Not checked yet" }
    switch health.state {
    case .reachable:
      return "Reachable"
    case .unreachable:
      let reason = health.reason.map { ": \($0)" } ?? ""
      return "Can't reach the server\(reason)"
    case .serverError:
      let reason = health.reason.map { ": \($0)" } ?? ""
      return "Server error\(reason)"
    }
  }

  private var statusColor: Color {
    if isChecking || health == nil { return .secondary }
    switch health!.state {
    case .reachable: return .secondary
    case .unreachable: return PuxTheme.warningAction
    case .serverError: return PuxTheme.errorText
    }
  }

  private func checkHealth(userAsked: Bool) async {
    isChecking = true
    let result = await apiClient.checkHealth()
    health = result
    isChecking = false

    if userAsked && result.state == .reachable {
      await DeliveryController.shared.start()
    }
  }
}
#endif

#endif
