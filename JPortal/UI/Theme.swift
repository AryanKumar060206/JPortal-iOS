import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// picked off jportal's own screens: charcoal slate surfaces, white type, colour only where it means something
struct Palette {
    let dark: Bool
    let primary: Color
    let onPrimary: Color
    let primaryContainer: Color
    let onPrimaryContainer: Color
    let secondaryContainer: Color
    let onSecondaryContainer: Color
    let tertiary: Color
    let tertiaryContainer: Color
    let onTertiaryContainer: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let error: Color
    let errorContainer: Color
    let outlineVariant: Color
    let containerLow: Color
    let container: Color
    let containerHigh: Color
    let containerHighest: Color

    // jportal's sgpa green / cgpa blue, grade letters and attendance verdicts
    let sgpa: Color
    let cgpa: Color
    let good: Color
    let goodContainer: Color
    let warn: Color

    private let grades: [String: Color]
    private let marksBands: [Color]
    private let marksInkBands: [Color]

    /// jportal's grade colours: greens for a, yellows for b and c+, oranges below, red for the ones that hurt
    func grade(_ letter: String) -> Color { grades[letter.trimmingCharacters(in: .whitespaces).uppercased()] ?? onSurfaceVariant }

    private func band(_ f: Double) -> Int { f >= 0.8 ? 0 : f >= 0.6 ? 1 : f >= 0.4 ? 2 : 3 }
    /// jportal's marks bands for a score out of 1: green from 80%, yellow from 60%, orange from 40%, red below
    func marks(_ fraction: Double) -> Color { marksBands[band(fraction)] }
    /// marks for text, darker on light where the bar's yellow can't be read
    func marksInk(_ fraction: Double) -> Color { marksInkBands[band(fraction)] }

    static func make(dark: Bool, amoled: Bool) -> Palette {
        if dark {
            let black = amoled
            return Palette(
                dark: true,
                primary: Color(hex: 0xA3C9FE), onPrimary: Color(hex: 0x0B1D33),
                primaryContainer: black ? Color(hex: 0x161B22) : Color(hex: 0x1F2937), onPrimaryContainer: .white,
                secondaryContainer: Color(hex: 0x2A3039), onSecondaryContainer: Color(hex: 0xE6E7E9),
                tertiary: Color(hex: 0x4ADE80), tertiaryContainer: Color(hex: 0x14532D), onTertiaryContainer: Color(hex: 0xBBF7D0),
                surface: black ? .black : Color(hex: 0x191C20), onSurface: .white, onSurfaceVariant: Color(hex: 0x95989C),
                error: Color(hex: 0xF87171), errorContainer: Color(hex: 0x7F1D1D), outlineVariant: Color(hex: 0x2F3540),
                containerLow: black ? Color(hex: 0x0F1113) : Color(hex: 0x1D2126),
                container: black ? Color(hex: 0x16191E) : Color(hex: 0x242A32),
                containerHigh: black ? Color(hex: 0x1D2228) : Color(hex: 0x2A3039),
                containerHighest: black ? Color(hex: 0x282E37) : Color(hex: 0x323A45),
                sgpa: Color(hex: 0x4ADE80), cgpa: Color(hex: 0x60A5FA), good: Color(hex: 0x4ADE80), goodContainer: Color(hex: 0x14532D),
                warn: Color(hex: 0xEAB308),
                grades: ["A+": Color(hex: 0x4ADE80), "A": Color(hex: 0x22C55E), "B+": Color(hex: 0xFACC15), "B": Color(hex: 0xEAB308),
                         "C+": Color(hex: 0xCA8A04), "C": Color(hex: 0xF97316), "D": Color(hex: 0xEA580C), "F": Color(hex: 0xEF4444),
                         "I": Color(hex: 0xEF4444), "X": Color(hex: 0xEF4444)],
                marksBands: [Color(hex: 0x00C950), Color(hex: 0xF0B000), Color(hex: 0xFF6A00), Color(hex: 0xEF4444)],
                marksInkBands: [Color(hex: 0x00C950), Color(hex: 0xF0B000), Color(hex: 0xFF6A00), Color(hex: 0xEF4444)]
            )
        }
        return Palette(
            dark: false,
            primary: Color(hex: 0x2563EB), onPrimary: .white,
            primaryContainer: Color(hex: 0xE5E7EB), onPrimaryContainer: Color(hex: 0x111827),
            secondaryContainer: Color(hex: 0xE5E7EB), onSecondaryContainer: Color(hex: 0x1F2937),
            tertiary: Color(hex: 0x16A34A), tertiaryContainer: Color(hex: 0xDCFCE7), onTertiaryContainer: Color(hex: 0x14532D),
            surface: .white, onSurface: Color(hex: 0x111827), onSurfaceVariant: Color(hex: 0x4B5563),
            error: Color(hex: 0xDC2626), errorContainer: Color(hex: 0xFEE2E2), outlineVariant: Color(hex: 0xD1D5DB),
            containerLow: Color(hex: 0xF7F8FA), container: Color(hex: 0xF1F2F5), containerHigh: Color(hex: 0xEBEDF0),
            containerHighest: Color(hex: 0xE5E7EB),
            sgpa: Color(hex: 0x16A34A), cgpa: Color(hex: 0x2563EB), good: Color(hex: 0x15803D), goodContainer: Color(hex: 0xDCFCE7),
            warn: Color(hex: 0xA16207),
            grades: ["A+": Color(hex: 0x16A34A), "A": Color(hex: 0x15803D), "B+": Color(hex: 0xCA8A04), "B": Color(hex: 0xA16207),
                     "C+": Color(hex: 0x854D0E), "C": Color(hex: 0xC2410C), "D": Color(hex: 0x9A3412), "F": Color(hex: 0xDC2626),
                     "I": Color(hex: 0xDC2626), "X": Color(hex: 0xDC2626)],
            marksBands: [Color(hex: 0x16A249), Color(hex: 0xF5C73D), Color(hex: 0xF58A3D), Color(hex: 0xEF4444)],
            marksInkBands: [Color(hex: 0x15803D), Color(hex: 0xA16207), Color(hex: 0xC2410C), Color(hex: 0xDC2626)]
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.make(dark: false, amoled: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// big numbers: rounded, heavy, tabular so they don't jiggle while they change
extension Font {
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// jportal's corner sizes
enum Radius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32
}
