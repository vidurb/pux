import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class SensitiveClipboard {
    public static let shared = SensitiveClipboard()

    public static let clearAfter: TimeInterval = 60.0

    private var clearTimer: Timer?

    public init() {}

    public func copy(_ text: String) {
        #if canImport(UIKit)
        clearTimer?.invalidate()
        clearTimer = nil

        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: Date().addingTimeInterval(Self.clearAfter)]
        )
        #endif
    }
}
