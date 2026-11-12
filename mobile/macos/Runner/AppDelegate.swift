import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var shell: DesktopShell? { (mainFlutterWindow as? MainFlutterWindow)?.shell }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    shell?.applicationDidFinishLaunching()
  }

  /// Only reached when "Quit when the window is closed" is on: otherwise
  /// closing hides the window and pux stays in the menu bar.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return shell?.closeQuits ?? true
  }

  /// Opening pux again (from Finder, Launchpad or the Dock) shows the window.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag { shell?.showWindow() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
