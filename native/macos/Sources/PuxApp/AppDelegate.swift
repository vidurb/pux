import AppKit
import Foundation
import SwiftUI
import PuxCore
import Clibsodium

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        let content = ContentView()
        .environmentObject(DeliveryController.shared)
        .frame(minWidth: 500, minHeight: 600)

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "pux"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = hosting
        window.center()
        DesktopShell.shared.attachMainWindow(window)
        mainWindow = window
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = SodiumCrypto.initializeSodium()
        DesktopShell.shared.applicationDidFinishLaunching()

        Task { @MainActor in
            await DeliveryController.shared.initialize()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return DesktopShell.shared.closeQuits
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DesktopShell.shared.showWindow()
        }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
