import XCTest
@testable import PuxCore

final class EnrollmentImportAccessibilityTests: XCTestCase {
  func testEditorHasAPurposeSpecificSpokenName() {
    XCTAssertEqual(EnrollmentImportAccessibility.editorLabel, "Enrollment JSON")
  }

  func testEditorNameHintAndIdentifierAreDistinctAndNonEmpty() {
    let values = [
      EnrollmentImportAccessibility.editorLabel,
      EnrollmentImportAccessibility.editorHint,
      EnrollmentImportAccessibility.editorIdentifier,
    ]
    for value in values {
      XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    XCTAssertEqual(Set(values).count, values.count)
  }
}
