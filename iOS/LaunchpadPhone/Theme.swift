import SwiftUI
import UIKit

/// Placeholder look: system fonts and colours with a blue accent. The app will be restyled later, so every colour
/// the views use lives here.
enum Theme {
    static let accent = dynamic("#2F6BFF", "#5B8CFF")
    static let ink = Color(uiColor: .label)
    static let subtle = Color(uiColor: .secondaryLabel)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let line = Color(uiColor: .separator)
    static let field = Color(uiColor: .tertiarySystemFill)
    static let bubbleIn = Color(uiColor: .secondarySystemGroupedBackground)
    static let bubbleMine = dynamic("#2F6BFF", "#3D6FF0")
    static let soft = dynamic("#E8EFFF", "#1C2440")
    static let danger = Color.red

    static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

extension Font {
    /// Titles: the system font, rounded.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Full-width rounded button.
struct PillButton: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(filled ? .white : Theme.accent)
            .background(Capsule().fill(filled ? Theme.accent : Theme.soft))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Three dots, as in a typing bubble.
struct TypingDots: View {
    var size: CGFloat = 7
    @State private var on = false
    var body: some View {
        HStack(spacing: size * 0.55) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.subtle).frame(width: size, height: size)
                    .opacity(on ? 1 : 0.35)
                    .offset(y: on ? -size * 0.35 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .frame(height: size * 1.6)
        .onAppear { on = true }
    }
}
