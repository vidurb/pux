#if os(iOS)
#if canImport(UIKit)
import UIKit
import SwiftUI

public enum PuxTheme {
    /// Fixed Brand Colors
    public static let pine = Color(red: 0.055, green: 0.231, blue: 0.196)
    public static let mint = Color(red: 0.867, green: 0.953, blue: 0.839)
    public static let ink = Color(red: 0.047, green: 0.122, blue: 0.106)
    public static let paper = Color(red: 0.961, green: 0.973, blue: 0.945)
    public static let night = Color(red: 0.039, green: 0.090, blue: 0.078)
    /// Adaptive link / accent green
    public static let leaf = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.82, blue: 0.68, alpha: 1.0)
            : UIColor(red: 0.090, green: 0.396, blue: 0.310, alpha: 1.0)
    })

    /// Adaptive success / confirmation text (e.g. "copied" notices)
    public static let success = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.88, blue: 0.58, alpha: 1.0)
            : UIColor(red: 0.08, green: 0.50, blue: 0.28, alpha: 1.0)
    })

    /// Adaptive inline error text on page background
    public static let errorText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.55, blue: 0.52, alpha: 1.0)
            : UIColor(red: 0.72, green: 0.11, blue: 0.11, alpha: 1.0)
    })

    /// Retry / warning action text on banners
    public static let warningAction = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.72, blue: 0.33, alpha: 1.0)
            : UIColor(red: 0.62, green: 0.28, blue: 0.0, alpha: 1.0)
    })

    /// OTP / code emphasis (replaces fixed pine on dark backgrounds)
    public static let codeText = primary

    /// Adaptive primary brand color: dark pine in light mode, bright mint in dark mode
    public static let primary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.867, green: 0.953, blue: 0.839, alpha: 1.0)
            : UIColor(red: 0.055, green: 0.231, blue: 0.196, alpha: 1.0)
    })

    /// Adaptive text on primary filled button
    public static let onPrimary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.231, blue: 0.196, alpha: 1.0)
            : UIColor(red: 0.867, green: 0.953, blue: 0.839, alpha: 1.0)
    })

    /// Adaptive border / outline: pine in light, mint in dark for high contrast
    public static let border = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.867, green: 0.953, blue: 0.839, alpha: 0.85)
            : UIColor(red: 0.055, green: 0.231, blue: 0.196, alpha: 0.8)
    })

    /// Adaptive text: ink on paper in light, pure white on night in dark
    public static let text = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.047, green: 0.122, blue: 0.106, alpha: 1.0)
    })

    /// Adaptive page background: paper (#F5F8F1) in light, night (#0A1714) in dark
    public static let background = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.039, green: 0.090, blue: 0.078, alpha: 1.0)
            : UIColor(red: 0.961, green: 0.973, blue: 0.945, alpha: 1.0)
    })

    /// Adaptive card background
    public static let cardBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.14, blue: 0.12, alpha: 1.0)
            : UIColor.white
    })

    /// Amber caution text
    public static let amber = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.98, green: 0.65, blue: 0.25, alpha: 1.0)
            : UIColor(red: 0.541, green: 0.294, blue: 0.0, alpha: 1.0)
    })

    /// Amber warning background
    public static let amberBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.25, green: 0.18, blue: 0.05, alpha: 1.0)
            : UIColor(red: 0.992, green: 0.941, blue: 0.847, alpha: 1.0)
    })
}
#endif
#endif
