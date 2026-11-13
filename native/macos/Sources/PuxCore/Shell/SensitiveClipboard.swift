import AppKit
import Foundation

public final class SensitiveClipboard: @unchecked Sendable {
    public static let shared = SensitiveClipboard()

    public static let defaultClearAfter: TimeInterval = 60.0
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let lock = NSLock()
    private var pendingChangeCount: Int?

    public init() {}

    public func copy(_ text: String, clearAfter: TimeInterval = SensitiveClipboard.defaultClearAfter) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)

        let changeCount = pasteboard.changeCount
        lock.lock()
        pendingChangeCount = changeCount
        lock.unlock()

        guard clearAfter > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let expected = self.pendingChangeCount
            self.lock.unlock()

            guard expected == changeCount, pasteboard.changeCount == changeCount else {
                return
            }

            pasteboard.clearContents()
            self.lock.lock()
            if self.pendingChangeCount == changeCount {
                self.pendingChangeCount = nil
            }
            self.lock.unlock()
        }
    }
}
