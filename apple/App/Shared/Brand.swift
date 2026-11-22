import CoreText
import LynxCore
import SwiftUI

/// The Lynx Battery / etherlynx.xyz system (SPEC §8): monochrome Ink on white, the sky stage as the one hero,
/// color only where it means something (list colors, overdue red).
enum Brand {
    static let ink = Color(hex: 0x0E0E10)
    static let ink2 = Color(hex: 0x3A3D45)
    static let muted = Color(hex: 0x6A6F7C)
    static let mist = Color(hex: 0xB3BCCD)
    static let skyTop = Color(hex: 0xA9B3C6)
    static let skyMid = Color(hex: 0xC9D0DC)
    static let skyLow = Color(hex: 0xEEF0F3)

    /// Spacing scale 4/6/10/12/14/18/24 — nothing else is used for gaps and padding.
    enum Space {
        static let xxs: CGFloat = 4, xs: CGFloat = 6, s: CGFloat = 10, m: CGFloat = 12, l: CGFloat = 14, xl: CGFloat = 18, xxl: CGFloat = 24
    }

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// Onest for everything that is read; the display sizes (hero 84, stat 28) are medium and tight.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .custom("Onest", size: size).weight(weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Onest", size: size).weight(weight) }
    /// Geist Mono for times, counts and dates in rows: figures line up and read as data.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .custom("Geist Mono", size: size).weight(weight) }

    // Type scale (SPEC §8)
    static let hero = display(84)
    static let stat = display(28)
    static let title = text(17, .semibold)
    static let row = text(13.5)
    static let caption = text(11)
    static let captionSmall = text(10.5)
}

/// Light and dark tokens (SPEC §8 table).
struct Palette {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var bg: Color { dark ? Color(hex: 0x101012) : .white }
    var panel: Color { dark ? Color(hex: 0x1A1A1D) : .white }
    var sunk: Color { dark ? Color(hex: 0x17171A) : Color(hex: 0xF1F3F7) }
    var fg: Color { dark ? .white : Brand.ink }
    var ink2: Color { dark ? .white.opacity(0.78) : Brand.ink2 }
    var muted: Color { dark ? .white.opacity(0.55) : Brand.muted }
    var line: Color { dark ? .white.opacity(0.10) : Brand.ink.opacity(0.12) }
    var signal: Color { dark ? Color(hex: 0xFF453A) : Color(hex: 0xE8271E) }
    /// Toggle tint: a white track in dark mode would hide the white knob.
    var toggleTint: Color { dark ? Brand.mist : Brand.ink }

    func color(_ c: ListColor) -> Color {
        switch c {
        case .ink: return fg
        case .slate: return Color(hex: 0x5E6B85)
        case .blue: return Color(hex: 0x2F7CF6)
        case .green: return Color(hex: 0x30D158)
        case .yellow: return Color(hex: 0xF5B400)
        case .orange: return Color(hex: 0xF07C2A)
        case .red: return Color(hex: 0xE8271E)
        case .pink: return Color(hex: 0xE0559A)
        case .brown: return Color(hex: 0x9A7B5B)
        }
    }

    /// Text on top of a list color: ink on the light ones (yellow, green), white otherwise — WCAG AA either way.
    func onColor(_ c: ListColor) -> Color {
        switch c {
        case .yellow, .green: return Brand.ink
        case .ink: return dark ? Brand.ink : .white
        default: return .white
        }
    }

    /// The stage: the one gradient in the app. Sky in light mode, a dark radial glow from below in dark mode.
    @ViewBuilder var stage: some View {
        if dark {
            RadialGradient(colors: [Color(hex: 0x2A2D35), Color(hex: 0x0E0E10)], center: .bottom, startRadius: 0, endRadius: 420)
        } else {
            LinearGradient(stops: [.init(color: Brand.skyTop, location: 0), .init(color: Brand.skyMid, location: 0.45),
                                   .init(color: Brand.skyLow, location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette(scheme: .light) }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Sets the palette from the color scheme for everything below.
struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let pal = Palette(scheme: scheme)
        content.environment(\.palette, pal).foregroundStyle(pal.fg).tint(pal.fg)
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension ListIcon {
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .cart: return "cart"
        case .house: return "house"
        case .briefcase: return "briefcase"
        case .book: return "book"
        case .heart: return "heart"
        case .star: return "star"
        case .flag: return "flag"
        case .gift: return "gift"
        case .plane: return "airplane"
        case .leaf: return "leaf"
        case .bolt: return "bolt"
        }
    }
}

// MARK: - Surfaces

/// Panel: r20, hairline `line` border, no shadow. Rows inside are separated by hairlines.
struct Panel<Content: View>: View {
    @Environment(\.palette) private var pal
    var padding: CGFloat = Brand.Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(pal.panel)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(pal.line))
    }
}

/// Stage: r28 with the sky gradient — one per screen, for the hero.
struct Stage<Content: View>: View {
    @Environment(\.palette) private var pal
    var padding: CGFloat = Brand.Space.xl
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(pal.stage.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
    }
}

struct Hairline: View {
    @Environment(\.palette) private var pal
    var body: some View { Rectangle().fill(pal.line).frame(height: 1) }
}

struct VHairline: View {
    @Environment(\.palette) private var pal
    var body: some View { Rectangle().fill(pal.line).frame(width: 1) }
}

/// Ink pill: the primary action. Ink capsule, white text, a white circle with a glyph on the right.
/// Inverts on dark backgrounds.
struct InkPill: View {
    let title: String
    var symbol: String = "arrow.right"
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let fill: Color = scheme == .dark ? .white : Brand.ink
        let ink: Color = scheme == .dark ? Brand.ink : .white
        Button(action: action) {
            HStack(spacing: Brand.Space.s) {
                Text(title).font(Brand.text(13, .medium))
                ZStack {
                    Circle().fill(ink)
                    if busy {
                        ProgressView().controlSize(.mini).tint(fill)
                    } else {
                        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(fill)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.leading, Brand.Space.l).padding(.trailing, Brand.Space.xxs).padding(.vertical, Brand.Space.xxs)
            .background(fill, in: Capsule())
            .foregroundStyle(ink)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Round icon button: a 30 pt Ink circle with a white SF Symbol.
struct RoundIconButton: View {
    let symbol: String
    let label: String
    var filled = true
    let action: () -> Void
    @Environment(\.palette) private var pal
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(filled ? pal.fg : pal.sunk)
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(filled ? pal.bg : pal.fg)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Capsule tabs: the selected one is an Ink capsule with white text, the others muted text.
struct CapsuleTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let on = selection == item.0
                Button { selection = item.0 } label: {
                    Text(item.1)
                        .font(Brand.text(12.5, .medium))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(on ? pal.fg : .clear, in: Capsule())
                        .foregroundStyle(on ? pal.bg : pal.muted)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Text link in muted ink, for secondary actions ("Continue without account").
struct LinkButton: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.palette) private var pal
    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(Brand.text(13, .medium))
                .foregroundStyle(role == .destructive ? pal.signal : pal.ink2)
                .underline(role != .destructive, color: pal.line)
        }
        .buttonStyle(.plain)
    }
}

/// Small secondary button: sunk capsule.
struct SoftButton: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.palette) private var pal
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Brand.Space.xs) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(Brand.text(12.5, .medium))
            }
            .padding(.horizontal, Brand.Space.m).padding(.vertical, 7)
            .background(pal.sunk, in: Capsule())
            .foregroundStyle(role == .destructive ? pal.signal : pal.fg)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reminder components

/// Checkbox: 20 pt circle, 1.5 pt stroke in the list color; completed = filled with a white check.
/// `pulse` marks a goal whose subtasks are all done.
struct Checkbox: View {
    let checked: Bool
    let color: ListColor
    var pulse = false
    let action: () -> Void
    @Environment(\.palette) private var pal
    @State private var pulsing = false
    var body: some View {
        let c = pal.color(color)
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(c, lineWidth: 1.5)
                if checked {
                    Circle().fill(c)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.onColor(color))
                } else if pulse {
                    Circle().fill(c.opacity(pulsing ? 0.28 : 0.08))
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? "Mark as not done" : "Mark as done")
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .onChange(of: pulse) { _, on in
            pulsing = false
            if on { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulsing = true } }
        }
    }
}

/// Goal ring: track = line, progress = list color. 22 pt in rows (2.5 pt stroke), 64 pt in the detail with the fraction inside.
struct GoalRing: View {
    let done: Int
    let total: Int
    let color: ListColor
    var size: CGFloat = 22
    var showFraction = false
    @Environment(\.palette) private var pal
    var body: some View {
        let lw: CGFloat = size >= 40 ? 5 : 2.5
        let p = total == 0 ? 0 : CGFloat(done) / CGFloat(total)
        ZStack {
            Circle().stroke(pal.line, lineWidth: lw)
            Circle().trim(from: 0, to: p)
                .stroke(pal.color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showFraction {
                Text("\(done)/\(total)").font(Brand.mono(13)).monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: done)
        .accessibilityLabel("\(done) of \(total) subtasks done")
    }
}

/// Avatar chip: initials on sunk, for assignees and members. No gradients.
struct Avatar: View {
    let profile: Profile
    var size: CGFloat = 20
    @Environment(\.palette) private var pal
    var body: some View {
        Text(profile.initials)
            .font(Brand.text(size * 0.42, .semibold))
            .frame(width: size, height: size)
            .background(pal.sunk, in: Circle())
            .overlay(Circle().strokeBorder(pal.line))
            .foregroundStyle(pal.ink2)
            .help(profile.email ?? profile.name)
            .accessibilityLabel(profile.name)
    }
}

/// List icon in a filled circle of the list color.
struct ListBadge: View {
    let list: LynxList
    var size: CGFloat = 22
    @Environment(\.palette) private var pal
    var body: some View {
        ZStack {
            Circle().fill(pal.color(list.listColor))
            Image(systemName: list.listIcon.symbol).font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(pal.onColor(list.listColor))
        }
        .frame(width: size, height: size)
    }
}

/// A field on `sunk` with no border, like the site's inputs.
struct SunkField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false
    /// Email keyboard, no auto-capitalization or autocorrect.
    var email = false
    @Environment(\.palette) private var pal
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Brand.mono(15) : Brand.text(13.5))
        .autocorrectionDisabled(email)
        #if os(iOS)
        .textInputAutocapitalization(email ? .never : nil)
        .keyboardType(email ? .emailAddress : .default)
        #endif
        .textContentType(email ? .emailAddress : nil)
        .focused($focused)
        .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.s)
        .background(pal.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusOnTap($focused, RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    /// A tap anywhere in the field's box (its padding too, not just the text line) focuses the field.
    func focusOnTap(_ focus: FocusState<Bool>.Binding, _ shape: some Shape = Rectangle()) -> some View {
        contentShape(shape).onTapGesture { focus.wrappedValue = true }
    }
}

/// The Etherlynx Studio griffin (shared/marks/etherlynx-griffin.svg), as a template so it follows the ink color.
struct EtherlynxMark: View {
    var body: some View {
        Image("EtherlynxMark").renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// Section caption in the sidebar and forms: muted, 11 pt, sentence case (no uppercase labels).
struct Caption: View {
    let text: String
    @Environment(\.palette) private var pal
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.text(11, .medium)).foregroundStyle(pal.muted)
    }
}
