import Foundation

/// WCAG 2.x relative-luminance contrast ratio, for auditing `Theme.Colors`
/// pairs against plan §13.2's "maintain sufficient text contrast" — AA
/// requires 4.5:1 for normal text, 3:1 for large (≥18pt, or ≥14pt bold) text.
public enum WCAGContrast {
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private static func channel(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
