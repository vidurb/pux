import Foundation

extension String {
    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: .caseInsensitive
    )

    public var isValidUUID: Bool {
        let range = NSRange(location: 0, length: self.utf16.count)
        return Self.uuidRegex.firstMatch(in: self, options: [], range: range) != nil
    }
}
