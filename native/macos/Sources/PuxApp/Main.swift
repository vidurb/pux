import SwiftUI
import AppKit
import PuxCore
import Clibsodium

@main
struct PuxEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            print(AppVersion.display)
        } else if CommandLine.arguments.contains("--probe-keychain") {
            do {
                try KeychainAppProbe.run()
                print("keychain app probe: ok")
            } catch {
                fputs("keychain app probe failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        } else if CommandLine.arguments.contains("--check") {
            _ = SodiumCrypto.initializeSodium()
            print(AppVersion.display)
            print("libsodium version: \(String(cString: sodium_version_string()))")
            print("bundle id: \(Bundle.main.bundleIdentifier ?? "xyz.vidur.pux")")
            print("status: ready")
        } else if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print("Usage: pux [--version | --check | --probe-keychain | --help]")
        } else {
            PuxMacApp.main()
        }
    }
}

struct PuxMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
