import AppKit
import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Sendable {
    case enabled
    case requiresApproval
    case disabled
    case unsupported
}

public enum LaunchAtLogin {
    public static var status: LaunchAtLoginStatus {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered, .notFound:
                return .disabled
            @unknown default:
                return .disabled
            }
        } else {
            return .unsupported
        }
    }

    public static func set(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } else {
            throw NSError(
                domain: "xyz.vidur.pux",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "On macOS 12, add pux manually in System Preferences → Users & Groups → Login Items."
                ]
            )
        }
    }

    public static func openSystemSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") {
            NSWorkspace.shared.open(url)
        }
    }
}
