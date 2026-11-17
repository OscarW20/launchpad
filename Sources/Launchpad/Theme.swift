#if os(macOS)
import SwiftUI
import AppKit

/// Launchpad's look: blue and black. Floating frosted panels on a dark (or pale) background
/// with a faint blue glow, pill buttons, round icon buttons and soft cards.
enum Theme {
    // MARK: Surfaces
    /// The window behind the panels (a blue glow sits on top of it, see `GlowBackground`).
    static let background = Color.dynamic(light: "#EDF0F5", dark: "#06070A")
    /// Floating panels (sidebar, list, conversation). Slightly see-through, over a material.
    static let panel = Color.dynamic(light: "#FFFFFFCC", dark: "#111318DB")
    /// Opaque panel colour, for sheets and popovers.
    static let panelSolid = Color.dynamic(light: "#FFFFFF", dark: "#111318")
    static let card = Color.dynamic(light: "#FFFFFF", dark: "#171A21")
    static let line = Color.dynamic(light: "#E1E6EE", dark: "#232733")
    static let field = Color.dynamic(light: "#F1F4F9", dark: "#1B1F28")
    static let code = Color.dynamic(light: "#EEF2F8", dark: "#20252F")
    static let rowHover = Color.dynamic(light: "#0B0F190A", dark: "#FFFFFF0A")

    // MARK: Text
    static let text = Color.dynamic(light: "#0B0F19", dark: "#F2F5FA")
    static let secondary = Color.dynamic(light: "#5B6577", dark: "#8B94A7")

    // MARK: Accent
    static let accent = Color.dynamic(light: "#1F6BFF", dark: "#3B82FF")
    static let accentDeep = Color.dynamic(light: "#0B4FD6", dark: "#1E5EEA")
    /// Soft accent fill: selected sidebar rows, secondary buttons, tags.
    static let accentSoft = Color.dynamic(light: "#E6EEFF", dark: "#16233F")
    /// Accent-coloured text that stays readable (4.5:1+) on panels and on `accentSoft`.
    static let accentText = Color.dynamic(light: "#0B4FD6", dark: "#6AA5FF")
    /// A solid accent with white text on it (badges, small pills): 4.5:1+ in both modes.
    static let accentStrong = Color.dynamic(light: "#1F6BFF", dark: "#2F6FEB")
    /// Your bubbles and primary buttons.
    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .top, endPoint: .bottom)
    static let bubbleGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Status
    /// Text and icons (readable on white); `successFill` for dots and bars.
    static let success = Color.dynamic(light: "#0B7F4B", dark: "#3DD68C")
    static let successFill = Color.dynamic(light: "#12A15F", dark: "#3DD68C")
    static let failure = Color.dynamic(light: "#C62F36", dark: "#FF5A5F")
    static let failureFill = Color.dynamic(light: "#E5484D", dark: "#FF5A5F")
    static let warning = Color.dynamic(light: "#A14A06", dark: "#F5A524")

    // MARK: Layout
    /// Spacing: 4, 8, 12, 16, 24, 32 only.
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 18
        static let composer: CGFloat = 26
        static let bubble: CGFloat = 20
        static let card: CGFloat = 24
        static let row: CGFloat = 16
        static let small: CGFloat = 12
    }

    /// System font: SF Pro for interface text, SF Pro Rounded only for big titles.
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        switch style {
        case .largeTitle, .title, .title2: return .system(style, design: .rounded).weight(weight)
        default: return .system(style).weight(weight)
        }
    }
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        var alpha: CGFloat = 1
        if s.count == 8 {
            alpha = CGFloat(value & 0xFF) / 255
            value >>= 8
        } else if s.count != 6 {
            value = 0x3B82FF
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
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

// MARK: - Backgrounds

/// The window background: near-black (or pale grey) with a faint blue glow top-right.
struct GlowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background
                RadialGradient(
                    colors: [Theme.accent.opacity(scheme == .dark ? 0.20 : 0.16), Theme.accent.opacity(0)],
                    center: UnitPoint(x: 0.95, y: -0.05),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.75
                )
                RadialGradient(
                    colors: [Theme.accent.opacity(scheme == .dark ? 0.06 : 0.05), Theme.accent.opacity(0)],
                    center: UnitPoint(x: 0.05, y: 1.05),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.5
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A floating, frosted, rounded panel.
struct PanelModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Theme.panel)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A card: card colour, thin line border, generous corners.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.Space.l
    var radius: CGFloat = Theme.Radius.card
    var fill: Color = Theme.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func panel(radius: CGFloat = Theme.Radius.card) -> some View { modifier(PanelModifier(radius: radius)) }

    func card(padding: CGFloat = Theme.Space.l, radius: CGFloat = Theme.Radius.card, fill: Color = Theme.card) -> some View {
        modifier(CardModifier(padding: padding, radius: radius, fill: fill))
    }

    /// A grouped form on a panel: the system's section cards, no grey page behind them, switches for toggles.
    func themedForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toggleStyle(.switch)
            .buttonStyle(SoftButtonStyle())
    }

    /// Sheet background: the solid panel colour with the glow.
    func sheetBackground() -> some View {
        buttonStyle(SoftButtonStyle())
            .background(ZStack { Theme.panelSolid; GlowBackground().opacity(0.6) }.ignoresSafeArea())
    }
}

// MARK: - Buttons

/// Full-round button. `.primary` is solid blue, `.soft` is a soft blue fill with blue text,
/// `.plain` is a neutral field fill, `.destructive` is red.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, soft, plain, destructive }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind)
    }
}

/// Secondary pill: soft accent fill, accent text.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: .soft)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @State private var hover = false

    var body: some View {
        let small = size == .small || size == .mini
        let height: CGFloat = small ? 26 : (size == .large ? 40 : 32)
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .semibold))
            .padding(.horizontal, small ? 12 : 16)
            .frame(minHeight: height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(kind == .plain ? Theme.line : Color.clear, lineWidth: 1))
            .overlay(Capsule().fill(Color.white.opacity(hover && enabled && !configuration.isPressed ? 0.06 : 0)))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var isDestructiveRole: Bool { configuration.role == .destructive && (kind == .soft || kind == .plain) }

    private var foreground: Color {
        if isDestructiveRole { return Theme.failure }
        switch kind {
        case .primary, .destructive: return .white
        case .soft: return Theme.accentText
        case .plain: return Theme.text
        }
    }

    private var fill: AnyShapeStyle {
        if isDestructiveRole { return AnyShapeStyle(Theme.failureFill.opacity(0.12)) }
        switch kind {
        case .primary: return AnyShapeStyle(Theme.accentGradient)
        case .soft: return AnyShapeStyle(Theme.accentSoft)
        case .plain: return AnyShapeStyle(Theme.field)
        case .destructive: return AnyShapeStyle(Theme.failureFill)
        }
    }
}

/// Round icon button style (labels show their icon only).
struct CircleButtonStyle: ButtonStyle {
    enum Kind { case plain, soft, accent, destructive }
    var kind: Kind = .plain
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        CircleButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct CircleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CircleButtonStyle.Kind
    let size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        CircleIconFace(kind: kind, size: size, hover: hover) {
            configuration.label.labelStyle(.iconOnly)
        }
        .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        .scaleEffect(configuration.isPressed ? 0.95 : 1)
        .onHover { hover = $0 }
    }
}

/// The look of a round icon button, for buttons and menus.
struct CircleIconFace<Label: View>: View {
    var kind: CircleButtonStyle.Kind = .plain
    var size: CGFloat = 32
    var hover = false
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(kind == .plain ? Theme.line : Color.clear, lineWidth: 1))
            .overlay(Circle().fill(Color.white.opacity(hover ? 0.06 : 0)))
            .contentShape(Circle())
    }

    private var foreground: Color {
        switch kind {
        case .plain: return Theme.text
        case .soft: return Theme.accentText
        case .accent, .destructive: return .white
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .plain: return AnyShapeStyle(Theme.field)
        case .soft: return AnyShapeStyle(Theme.accentSoft)
        case .accent: return AnyShapeStyle(Theme.accentGradient)
        case .destructive: return AnyShapeStyle(Theme.failureFill)
        }
    }
}

/// A round icon button.
struct CircleIconButton: View {
    let symbol: String
    var help: String = ""
    var kind: CircleButtonStyle.Kind = .plain
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(help.isEmpty ? symbol : help, systemImage: symbol)
        }
        .buttonStyle(CircleButtonStyle(kind: kind, size: size))
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
    }
}

/// A menu drawn as a round icon button.
struct CircleMenu<Content: View>: View {
    let symbol: String
    var help: String = ""
    var kind: CircleButtonStyle.Kind = .plain
    var size: CGFloat = 32
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            CircleIconFace(kind: kind, size: size) { Image(systemName: symbol) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
    }
}

// MARK: - Small pieces

/// Pill tabs: the selected one is solid blue.
struct PillTabs<T: Hashable>: View {
    @Binding var selection: T
    let options: [(String, T)]

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options.indices, id: \.self) { i in
                let title = options[i].0, value = options[i].1
                let on = selection == value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 30)
                        .foregroundStyle(on ? Color.white : Theme.secondary)
                        .background(Capsule().fill(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Rounded search field.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Clear")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: focused ? 1.5 : 1))
        .background {
            // ⌘F focuses the search, like the toolbar search field did.
            Button("Search") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Text field style: a filled, rounded field with a blue ring while typing.
struct PillFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A count in a small blue pill.
struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 18)
                .background(Capsule().fill(Theme.accentStrong))
        }
    }
}

/// A small grey tag, e.g. a bot's role next to its name.
struct RoleTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.field))
    }
}

/// Small caps section header, e.g. "WORK".
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A soft round tile with an icon in it (empty states, sheet headers).
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color = Theme.accentText

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.accentSoft))
    }
}

/// Top of a list column: a title and round action buttons.
struct ColumnHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            actions
                .buttonStyle(CircleButtonStyle())
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
    }
}

extension View {
    /// A list column with a title and round action buttons on top.
    func columnHeader<A: View>(_ title: String, @ViewBuilder actions: () -> A) -> some View {
        let header = ColumnHeader(title: title) { actions() }
        return VStack(spacing: 0) {
            header
            self.frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Empty state: a soft icon tile, a title, a line of help and pill actions.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String = ""
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            IconTile(symbol: symbol, size: 64)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.top, Theme.Space.xs)
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String = "") {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// The Launchpad mark: the app icon, small and rounded.
struct BrandMark: View {
    var size: CGFloat = 24

    private static let image: NSImage? = AppResources.url("AppIcon-1024", "png", in: "Brand").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ZStack {
                    Theme.accentGradient
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Selectable rows

private struct RowSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<String?>? = nil
}

private struct RowActivateKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var rowSelection: Binding<String?>? {
        get { self[RowSelectionKey.self] }
        set { self[RowSelectionKey.self] = newValue }
    }

    var rowActivate: (() -> Void)? {
        get { self[RowActivateKey.self] }
        set { self[RowActivateKey.self] = newValue }
    }
}

private struct RowIDsKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// A list of rows on a panel. Rows mark themselves with `.selectableRow(id)`;
/// click to select, ↑ and ↓ move the selection.
struct PanelList<Content: View>: View {
    @Binding var selection: String?
    @ViewBuilder var content: Content
    @State private var ids: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.downArrow) { move(1, proxy) }
        }
        .environment(\.rowSelection, $selection)
        .environment(\.rowActivate, { focused = true })
        .onPreferenceChange(RowIDsKey.self) { ids = $0 }
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let next = min(max(current + step, 0), ids.count - 1)
        selection = ids[next]
        proxy.scrollTo(ids[next])
        return .handled
    }
}

struct SelectableRowModifier: ViewModifier {
    let id: String
    @Environment(\.rowSelection) private var selection
    @Environment(\.rowActivate) private var activate
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    func body(content: Content) -> some View {
        let on = selection?.wrappedValue == id
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        content
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if on {
                    shape.fill(Theme.card)
                        .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 6, y: 2)
                } else if hover {
                    shape.fill(Theme.rowHover)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                selection?.wrappedValue = id
                activate?()
            }
            .onHover { hover = $0 }
            .id(id)
            .preference(key: RowIDsKey.self, value: [id])
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    /// A row in a `PanelList`, selected when the list's selection is `id`.
    func selectableRow(_ id: String) -> some View { modifier(SelectableRowModifier(id: id)) }
}

// MARK: - Time

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
