#if os(iOS)
import Foundation
import UIKit
import FirebaseCore
import FirebaseMessaging
import PuxCore

public final class NativeFirebaseRegistrationSource: NSObject, FcmRegistrationSource, MessagingDelegate,
  @unchecked Sendable
{
  public static let shared = NativeFirebaseRegistrationSource()

  private let lock = NSLock()
  private var registrationHandler: (@Sendable (String) -> Void)?
  private var errorHandler: (@Sendable (Error) -> Void)?
  private var pendingApnsToken: Data?
  private let registerBridge = RegisterAsyncBridge()

  public override init() {
    super.init()
  }

  public func configure() -> Bool {
    guard let config = FirebaseConfig.load(), config.bundleId == Bundle.main.bundleIdentifier,
      let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
      let options = FirebaseOptions(contentsOfFile: path)
    else { return false }
    if FirebaseApp.app() == nil {
      FirebaseApp.configure(options: options)
    }
    Messaging.messaging().delegate = self
    lock.lock()
    let apns = pendingApnsToken
    lock.unlock()
    if let token = apns {
      Messaging.messaging().apnsToken = token
    }
    return true
  }

  public func setApnsToken(_ token: Data) {
    lock.lock()
    pendingApnsToken = token
    lock.unlock()
    if FirebaseApp.app() != nil { Messaging.messaging().apnsToken = token }
  }

  public func setRegistrationHandler(_ handler: @escaping @Sendable (String) -> Void) {
    lock.lock()
    registrationHandler = handler
    lock.unlock()
  }

  public func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
    lock.lock()
    errorHandler = handler
    lock.unlock()
  }

  private func hasApnsToken() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingApnsToken != nil
  }

  public func register() async throws {
    guard hasApnsToken() else {
      throw PuxError.serverError(statusCode: 0, message: "Waiting for APNs registration")
    }
    try await registerBridge.run { _, complete in
      Messaging.messaging().register { error in
        if let error {
          complete(.failure(error))
        } else {
          complete(.success(()))
        }
      }
    }
  }

  public func messaging(_ messaging: Messaging, didReceiveRegistration registration: String?) {
    guard let fid = registration, !fid.isEmpty else { return }
    lock.lock()
    let handler = registrationHandler
    lock.unlock()
    handler?(fid)
  }
}
#endif
