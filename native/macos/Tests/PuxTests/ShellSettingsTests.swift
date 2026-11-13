import XCTest
@testable import PuxCore

@MainActor
final class ShellSettingsTests: PuxTestCase {
    func testSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "xyz.vidur.pux.tests")!
        defaults.removePersistentDomain(forName: "xyz.vidur.pux.tests")

        let shell = DesktopShell(defaults: defaults)
        XCTAssertFalse(shell.closeQuits)
        XCTAssertFalse(shell.startHidden)

        shell.closeQuits = true
        shell.startHidden = true

        let shell2 = DesktopShell(defaults: defaults)
        XCTAssertTrue(shell2.closeQuits)
        XCTAssertTrue(shell2.startHidden)
    }

    func testAttachMainWindowSetsDelegate() {
        let shell = DesktopShell(defaults: UserDefaults(suiteName: "xyz.vidur.pux.shell.attach")!)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        shell.attachMainWindow(window)
        XCTAssertTrue(window.delegate === shell)
    }
}
