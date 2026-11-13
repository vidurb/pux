import XCTest
@testable import PuxCore

@MainActor
final class DesktopShellLaunchTests: PuxTestCase {
    func testStartHiddenDoesNotRequireVisibleWindowAtLaunch() {
        let defaults = UserDefaults(suiteName: "xyz.vidur.pux.launch")!
        defaults.removePersistentDomain(forName: "xyz.vidur.pux.launch")
        let shell = DesktopShell(defaults: defaults)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        shell.attachMainWindow(window)
        shell.startHidden = true
        shell.applyLaunchVisibility()
        XCTAssertFalse(window.isVisible)
    }

    func testWindowAttachedBeforeApplyLaunchVisibility() {
        let defaults = UserDefaults(suiteName: "xyz.vidur.pux.launch2")!
        defaults.removePersistentDomain(forName: "xyz.vidur.pux.launch2")
        let shell = DesktopShell(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        shell.attachMainWindow(window)
        shell.startHidden = false
        shell.applyLaunchVisibility()
        XCTAssertTrue(window.isVisible)
    }
}
