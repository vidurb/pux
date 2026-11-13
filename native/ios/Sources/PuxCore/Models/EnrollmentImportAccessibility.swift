import Foundation

/// Accessibility metadata for the enrollment JSON editor on the import screen. The editor is a bare
/// text area, so without these a screen reader announces it with no purpose-specific name.
public enum EnrollmentImportAccessibility {
  /// Spoken name of the editor. Matches the "Enrollment JSON" wording used on the other platforms.
  public static let editorLabel = "Enrollment JSON"
  public static let editorHint = "Paste the enrollment JSON copied from another device"
  /// Stable handle for UI tests; never spoken.
  public static let editorIdentifier = "enrollment-json-editor"
}
