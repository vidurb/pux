import SwiftUI

public struct ConfirmServerDialog: View {
    public let serverUrl: String
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    public init(serverUrl: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.serverUrl = serverUrl
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var hostDisplay: String {
        guard let url = URL(string: serverUrl) else { return serverUrl }
        if let port = url.port {
            return "\(url.host ?? ""):\(port)"
        }
        return url.host ?? serverUrl
    }

    private var isHttp: Bool {
        return URL(string: serverUrl)?.scheme == "http"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to this server?")
                .font(.headline)

            Text("This enrollment uses the pux server")
                .foregroundColor(.secondary)

            Text(hostDisplay)
                .font(.body)
                .bold()
                .textSelection(.enabled)

            if isHttp {
                Text("Unencrypted connection (local development only).")
                    .foregroundColor(PuxColors.warningText)
                    .font(.callout)
            }

            Text("Only continue if you recognise this server.")
                .foregroundColor(.secondary)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 380)
    }
}
