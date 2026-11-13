#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import PuxCore

@main
public struct PuxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .accentColor(PuxTheme.primary)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            if RecordStore.shared.isEnrolled() {
                                await DeliveryController.shared.onResume()
                            }
                            _ = await NotificationPermissions.shared.check()
                        }
                    }
                }
        }
    }
}
#endif

#endif
