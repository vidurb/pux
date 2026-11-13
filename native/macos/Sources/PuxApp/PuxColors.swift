import AppKit
import SwiftUI

/// Appearance-aware colours meeting WCAG AA for native macOS UI.
enum PuxColors {
    /// Light: #B91C1C on white ≈ 5.9:1; dark: #F87171 on #1E1E1E ≈ 5.4:1
    static var errorText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
                : NSColor(red: 0.73, green: 0.11, blue: 0.11, alpha: 1)
        })
    }

    /// Light: #C2410C on white ≈ 4.6:1; dark: #FB923C on #1E1E1E ≈ 4.8:1
    static var warningText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1)
                : NSColor(red: 0.76, green: 0.25, blue: 0.05, alpha: 1)
        })
    }

    /// Light: #9A3412 on orange 10% tint ≈ 4.7:1; dark: #FDBA74 ≈ 4.9:1
    static var warningCaptionOnTint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.99, green: 0.73, blue: 0.45, alpha: 1)
                : NSColor(red: 0.60, green: 0.20, blue: 0.07, alpha: 1)
        })
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// Orange banner surface — caption uses `warningCaptionOnTint` (≥4.5:1 on this fill).
    static var warningBannerFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.35, green: 0.20, blue: 0.05, alpha: 1)
                : NSColor(red: 1.0, green: 0.94, blue: 0.88, alpha: 1)
        })
    }

    static var cardBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.35, alpha: 1)
                : NSColor(white: 0.82, alpha: 1)
        })
    }
}

extension View {
    func puxCardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PuxColors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(PuxColors.cardBorder, lineWidth: 1)
            )
            .cornerRadius(10)
    }
}
