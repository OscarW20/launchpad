#if os(macOS)
import SwiftUI
import AppKit

/// Launchpad's own look: warm paper, soft peach and a friendly coral accent.
enum Theme {
    static let accent = Color.dynamic(light: "#E2674C", dark: "#F08A70")
    static let canvas = Color.dynamic(light: "#FBF6EF", dark: "#1E1A17")
    static let surface = Color.dynamic(light: "#FFFFFF", dark: "#2A2521")
    static let raised = Color.dynamic(light: "#F5EDE3", dark: "#332D28")
    static let border = Color.dynamic(light: "#EADFD2", dark: "#3D352F")
    static let userBubble = Color.dynamic(light: "#F9DCCF", dark: "#5A3328")
    static let warning = Color.dynamic(light: "#C9603C", dark: "#F2A65A")
    static let success = Color.dynamic(light: "#4E8C5B", dark: "#8DB580")
    static let failure = Color.dynamic(light: "#C0443A", dark: "#E77A6F")
    static let codeBackground = Color.dynamic(light: "#2B2622", dark: "#151210")
    static let codeText = Color(hex: "#F3E9DF")
    static let codeMuted = Color(hex: "#B5A698")

    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        if s.count != 6 { value = 0xE8735A }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func dynamic(light: String, dark: String) -> Color {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

enum TimeLabel {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// "14:05", "Tue" or "12/11/2026", like a messaging app.
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 { return weekday.string(from: date) }
        return day.string(from: date)
    }

    static func clock(_ date: Date) -> String { time.string(from: date) }
}
#endif
