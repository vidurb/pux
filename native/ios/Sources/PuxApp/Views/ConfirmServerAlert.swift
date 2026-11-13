#if os(iOS)
import SwiftUI

public struct ConfirmServerAlert: ViewModifier {
    @Binding var isPresented: Bool
    let serverUrl: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public func body(content: Content) -> some View {
        content.alert("Connect to this server?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            Button("Connect") {
                onConfirm()
            }
        } message: {
            let components = URLComponents(string: serverUrl)
            let host = {
                guard let c = components, let h = c.host else { return serverUrl }
                if let port = c.port { return "\(h):\(port)" }
                return h
            }()
            let isHttp = serverUrl.lowercased().hasPrefix("http://")
            let warn = isHttp ? "\n\nUnencrypted connection (local development only)." : ""
            Text("This enrollment uses the pux server\n\n\(host)\(warn)\n\nOnly continue if you recognise this server.")
        }
    }
}

extension View {
    public func confirmServerAlert(
        isPresented: Binding<Bool>,
        serverUrl: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        modifier(ConfirmServerAlert(
            isPresented: isPresented,
            serverUrl: serverUrl,
            onConfirm: onConfirm,
            onCancel: onCancel
        ))
    }
}

#endif
