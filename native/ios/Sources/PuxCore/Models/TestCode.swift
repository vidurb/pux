import Foundation

public struct TestCode: Equatable, Sendable {
    public let otp: String
    public let devices: Int

    public init(otp: String, devices: Int) {
        self.otp = otp
        self.devices = devices
    }
}
