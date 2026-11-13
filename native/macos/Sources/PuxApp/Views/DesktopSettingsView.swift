import SwiftUI
import PuxCore

public struct DesktopSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openAtLogin: Bool = false
    @State private var loginStatus: LaunchAtLoginStatus = .disabled
    @State private var startHidden: Bool = false
    @State private var closeQuits: Bool = false
    @State private var errorMessage: String? = nil

    public init() {}

    private var isMacOS12: Bool {
        if #available(macOS 13.0, *) {
            return false
        } else {
            return true
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Desktop settings")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 16) {
                // 1. Open at login
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open at login", isOn: Binding(
                        get: { openAtLogin },
                        set: { toggleOpenAtLogin($0) }
                    ))
                    .disabled(loginStatus == .unsupported)

                    Text(loginSubtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if loginStatus == .requiresApproval || (loginStatus == .unsupported && isMacOS12) {
                        Button(isMacOS12 ? "Open Users & Groups" : "Open Login Items") {
                            LaunchAtLogin.openSystemSettings()
                        }
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }

                Divider()

                // 2. Start in the menu bar
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start in the menu bar", isOn: Binding(
                        get: { startHidden },
                        set: {
                            startHidden = $0
                            DesktopShell.shared.startHidden = $0
                        }
                    ))

                    Text("Open without a window. Click the pux icon in the menu bar to show it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Divider()

                // 3. Quit when the window is closed
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Quit when the window is closed", isOn: Binding(
                        get: { closeQuits },
                        set: {
                            closeQuits = $0
                            DesktopShell.shared.closeQuits = $0
                        }
                    ))

                    Text(closeQuits
                         ? "Closing the window quits pux, and codes stop arriving until you open it again."
                         : "Closing the window keeps pux in the menu bar, so codes keep arriving.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 340)
        .onAppear {
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        loginStatus = LaunchAtLogin.status
        openAtLogin = (loginStatus == .enabled || loginStatus == .requiresApproval)
        startHidden = DesktopShell.shared.startHidden
        closeQuits = DesktopShell.shared.closeQuits
    }

    private func toggleOpenAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    private var loginSubtitle: String {
        switch loginStatus {
        case .unsupported:
            if isMacOS12 {
                return "On macOS 12, login items can be added manually in System Preferences → Users & Groups → Login Items."
            }
            return "Needs macOS 13 or later."
        case .requiresApproval:
            return "Waiting for you to allow pux in System Settings → General → Login Items."
        default:
            return "Start pux when you log in, so codes arrive without opening it."
        }
    }
}
