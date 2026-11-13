import SwiftUI
import PuxCore

public struct ContentView: View {
    @EnvironmentObject var controller: DeliveryController
    @State private var showingSettings: Bool = false
    @State private var showingHelp: Bool = false
    @State private var showingImport: Bool = false
    @State private var showingExplainer: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                NavigationStack {
                    rootContent
                }
            } else {
                NavigationView {
                    rootContent
                }
            }
        }
    }

    private var rootContent: some View {
        Group {
            if let error = controller.storageError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.yellow)
                    Text("Keychain Storage Error")
                        .font(.headline)
                    Text("pux was unable to securely access your keychain: \(error)\n\nPlease ensure the app has permission to access your keychain.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Retry") {
                        Task {
                            await controller.initialize()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if controller.isEnrolled {
                HomeScreenView(
                    onOpenSettings: { showingSettings = true },
                    onOpenHelp: { showingHelp = true }
                )
            } else {
                EnrollChooserScreenView(
                    onImport: { showingImport = true }
                )
            }
        }
        .navigationTitle("pux")
        .sheet(isPresented: $showingSettings) {
            DesktopSettingsView()
        }
        .sheet(isPresented: $showingHelp) {
            ForwardingHelpView(inbox: controller.currentInbox)
        }
        .sheet(isPresented: $showingImport) {
            ImportEnrollmentView()
        }
        .sheet(isPresented: $showingExplainer) {
            NotificationExplainerView()
        }
        .onAppear {
            DesktopShell.shared.onOpenSettings = {
                showingSettings = true
            }
            checkExplainer()
        }
    }

    private func checkExplainer() {
        Task {
            let skipped = (try? controller.recordStore.notificationExplainerSkipped()) ?? false
            guard !skipped else { return }
            let access = await NotificationPermissions.shared.check()
            if access == .notAsked {
                showingExplainer = true
            }
        }
    }
}
