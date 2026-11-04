import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let sensitiveClipboard = SensitiveClipboard()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    sensitiveClipboard.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Copies secrets marked concealed for clipboard managers, and clears them
/// later if nothing else has been copied since (tracked by changeCount, so
/// the clipboard is never read).
private class SensitiveClipboard {
  private var pendingChangeCount: Int?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "xyz.vidur.pux/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "copySensitive" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String else {
        result(FlutterError(code: "bad_args", message: "text is required", details: nil))
        return
      }
      self?.copy(text, clearAfterMs: args["clearAfterMs"] as? Int ?? 0)
      result(nil)
    }
  }

  private func copy(_ text: String, clearAfterMs: Int) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

    let changeCount = pasteboard.changeCount
    pendingChangeCount = changeCount
    guard clearAfterMs > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(clearAfterMs)) { [weak self] in
      guard self?.pendingChangeCount == changeCount, pasteboard.changeCount == changeCount else {
        return
      }
      pasteboard.clearContents()
      self?.pendingChangeCount = nil
    }
  }
}
