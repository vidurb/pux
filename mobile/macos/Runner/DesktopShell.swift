import Cocoa
import FlutterMacOS
import ServiceManagement

/// Keeps pux in the menu bar so codes keep arriving with the window closed,
/// and applies the desktop settings: quit when the window closes, start
/// without a window, and open at login.
///
/// The settings live in UserDefaults rather than Dart, because they are needed
/// before Flutter runs (whether to show the window at launch) and after it
/// stops listening (whether closing the window quits).
final class DesktopShell: NSObject, NSWindowDelegate {
  static let closeQuitsKey = "desktop.closeQuits"
  static let startHiddenKey = "desktop.startHidden"

  private let window: NSWindow
  private let defaults: UserDefaults
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?

  init(window: NSWindow, defaults: UserDefaults = .standard) {
    self.window = window
    self.defaults = defaults
    super.init()
    window.delegate = self
  }

  /// Closing the window quits pux instead of leaving it in the menu bar. Off by default.
  var closeQuits: Bool {
    get { defaults.bool(forKey: Self.closeQuitsKey) }
    set { defaults.set(newValue, forKey: Self.closeQuitsKey) }
  }

  /// Launches with only the menu bar icon, no window. Off by default.
  var startHidden: Bool {
    get { defaults.bool(forKey: Self.startHiddenKey) }
    set { defaults.set(newValue, forKey: Self.startHiddenKey) }
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "xyz.vidur.pux/desktop_shell", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    self.channel = channel
  }

  /// Shows the window at launch unless the user chose to start in the menu bar.
  func applicationDidFinishLaunching() {
    installStatusItem()
    if startHidden {
      NSApp.setActivationPolicy(.accessory)
    } else {
      showWindow()
    }
  }

  func showWindow() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// Hides the window and the Dock icon; pux stays in the menu bar.
  func hideWindow() {
    window.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  // MARK: NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Closing for real lets applicationShouldTerminateAfterLastWindowClosed quit.
    if closeQuits { return true }
    hideWindow()
    return false
  }

  // MARK: Status item

  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(named: "MenuBarIcon")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "pux"
      button.setAccessibilityLabel("pux")
    }

    let menu = NSMenu()
    menu.addItem(withTitle: "Open pux", action: #selector(openFromMenu), keyEquivalent: "")
    menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit pux", action: #selector(quitFromMenu), keyEquivalent: "q")
    for menuItem in menu.items { menuItem.target = self }
    item.menu = menu
    statusItem = item
  }

  @objc private func openFromMenu() {
    showWindow()
  }

  @objc private func openSettingsFromMenu() {
    showWindow()
    channel?.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func quitFromMenu() {
    NSApp.terminate(nil)
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool
    switch call.method {
    case "getSettings":
      result(settings())
    case "setCloseQuits":
      guard let enabled else { return result(Self.badArgs) }
      closeQuits = enabled
      result(settings())
    case "setStartHidden":
      guard let enabled else { return result(Self.badArgs) }
      startHidden = enabled
      result(settings())
    case "setLaunchAtLogin":
      guard let enabled else { return result(Self.badArgs) }
      do {
        try LaunchAtLogin.set(enabled)
        result(settings())
      } catch {
        result(
          FlutterError(
            code: "launch_at_login_failed", message: error.localizedDescription, details: nil))
      }
    case "openLoginItemsSettings":
      LaunchAtLogin.openSystemSettings()
      result(nil)
    case "showWindow":
      showWindow()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func settings() -> [String: Any] {
    [
      "closeQuits": closeQuits,
      "startHidden": startHidden,
      "launchAtLogin": LaunchAtLogin.status,
    ]
  }

  private static let badArgs = FlutterError(
    code: "bad_args", message: "enabled is required", details: nil)
}

/// Registers pux as a login item with SMAppService, which needs macOS 13.
/// The system keeps the state, so the user can also change it in System
/// Settings → General → Login Items.
enum LaunchAtLogin {
  /// "enabled", "disabled", "requiresApproval" or "unsupported".
  static var status: String {
    guard #available(macOS 13.0, *) else { return "unsupported" }
    switch SMAppService.mainApp.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notRegistered, .notFound: return "disabled"
    @unknown default: return "disabled"
    }
  }

  static func set(_ enabled: Bool) throws {
    guard #available(macOS 13.0, *) else {
      throw NSError(
        domain: "xyz.vidur.pux", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Opening at login needs macOS 13 or later"])
    }
    let service = SMAppService.mainApp
    if enabled {
      guard service.status != .enabled else { return }
      try service.register()
    } else {
      guard service.status != .notRegistered else { return }
      try service.unregister()
    }
  }

  static func openSystemSettings() {
    if #available(macOS 13.0, *) {
      SMAppService.openSystemSettingsLoginItems()
    }
  }
}
