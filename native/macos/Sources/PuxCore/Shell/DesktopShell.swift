import AppKit
import Foundation

@MainActor
public final class DesktopShell: NSObject, NSWindowDelegate {
    public static let shared = DesktopShell()

    public static let closeQuitsKey = "desktop.closeQuits"
    public static let startHiddenKey = "desktop.startHidden"

    public private(set) weak var window: NSWindow?

    public func attachMainWindow(_ window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    private let defaults: UserDefaults
    private var statusItem: NSStatusItem?
    public var onOpenSettings: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    public var closeQuits: Bool {
        get { defaults.bool(forKey: Self.closeQuitsKey) }
        set { defaults.set(newValue, forKey: Self.closeQuitsKey) }
    }

    public var startHidden: Bool {
        get { defaults.bool(forKey: Self.startHiddenKey) }
        set { defaults.set(newValue, forKey: Self.startHiddenKey) }
    }

    /// Shows the window at launch unless the user chose to start in the menu bar (Flutter runner parity).
    public func applicationDidFinishLaunching() {
        installStatusItem()
        applyLaunchVisibility()
    }

    public func applyLaunchVisibility() {
        if startHidden {
            NSApp?.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }
    }

    public func showWindow() {
        NSApp?.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        if let app = NSApp {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(ignoringOtherApps: true)
            }
        }
    }

    public func hideWindow() {
        window?.orderOut(nil)
        NSApp?.setActivationPolicy(.accessory)
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeQuits {
            return true
        }
        hideWindow()
        return false
    }

    // MARK: - Status Item

    public func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon") ??
                        Bundle.main.image(forResource: "MenuBarIcon") ??
                        NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "pux")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "pux"
            button.setAccessibilityLabel("pux")
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open pux", action: #selector(openFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit pux", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func openFromMenu() {
        showWindow()
    }

    @objc private func openSettingsFromMenu() {
        showWindow()
        onOpenSettings?()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}
