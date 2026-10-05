import AppKit
import SwiftUI

/// Shared design tokens for the hub — the single source of truth the hub shell and the
/// Settings / Journal / Dictionary panes draw from. Values match the
/// current `JournalStyle` (gold #E0A42E, layered neutral surfaces, Mulish).
///
/// NOTE: `JournalStyle` in JournalWindow.swift still carries its own copy of these tokens; when the
/// Journal pane moves into the hub it folds into this type so there is one palette, not two.
enum RhemionStyle {
    static let gold = Color(rhemionHex: 0xE0A42E)
    /// THE one danger red for every destructive action and warning (Delete, Uninstall, "can't be undone"):
    /// the system red, so it adapts to light/dark (#FF3B30 / #FF453A) and matches native destructive UI.
    static let danger = Color(nsColor: .systemRed)

    static func text(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0xE8E8EC : 0x1D1D1F) }
    static func secondary(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0xA8A8AE : 0x5F5F66) }
    static func tertiary(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x909098 : 0x9A9AA1) }

    /// The rail / sidebar ground (recessed relative to content).
    static func rail(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x242426 : 0xF5F5F7) }
    /// The main content ground.
    static func content(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x1E1E20 : 0xFFFFFF) }
    /// A raised neutral surface — the "on/active" language (never an accent fill).
    static func win(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x232326 : 0xFFFFFF) }
    static func line(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x37373B : 0xE5E5E9) }
    static func hover(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x2C2C30 : 0xEFEFF2) }
    /// The surface of an "on" control (segment, rail item, toolbar toggle). In dark it is lifted ABOVE the
    /// track (#343438 over #242426) — `win` there is a hair darker than the rail, so the tile read as sunken.
    static func activeSurface(_ dark: Bool) -> Color { Color(rhemionHex: dark ? 0x343438 : 0xFFFFFF) }

    /// A selected destination in the rail (gold-tinted, matching the Journal list selection).
    static func selected(_ dark: Bool) -> Color { dark ? gold.opacity(0.20) : Color(rhemionHex: 0xF6DD84) }

    /// The exact bundled Mulish face per weight (no SwiftUI weight synthesis, which renders heavier than
    /// the design). Falls back to the native system font if the face isn't registered.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .heavy, .black: face = "Mulish-ExtraBold"
        case .bold: face = "Mulish-Bold"
        case .semibold: face = "Mulish-SemiBold"
        case .medium: face = "Mulish-Medium"
        case .light, .ultraLight, .thin: face = "Mulish-Light"
        default: face = "Mulish-Regular"
        }
        return NSFont(name: face, size: size) == nil ? .system(size: size, weight: weight) : .custom(face, size: size)
    }
}

extension View {
    /// The app-wide "on" state of a control family — segmented pills, the hub rail, toolbar toggles: a raised
    /// neutral tile (never gold) with a hairline edge and a soft shadow, drawn BEHIND the content so the shadow
    /// falls on the tile, not on the glyph. One recipe: light #FFFFFF,
    /// edge black 12%, shadow 14% r2 y1; dark #343438, edge white 16%, shadow 28% r2 y1.
    func activeTile(_ on: Bool, dark: Bool, radius: CGFloat) -> some View {
        background {
            if on {
                RoundedRectangle(cornerRadius: radius)
                    .fill(RhemionStyle.activeSurface(dark))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(dark ? 0.28 : 0.14), radius: 2, y: 1)
            }
        }
    }
}

extension Color {
    init(rhemionHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

/// THE text link (DESIGN.md) — one style app-wide: gold text like "Restore defaults" (Mulish 12.5
/// regular), an optional SF icon, no background, border or underline; hover dims it (0.75); disabled
/// reads tertiary. `danger: true` swaps the ink to `RhemionStyle.danger` (Uninstall, Delete exported
/// transcripts…).
struct TextLink: View {
    let title: String
    var systemImage: String? = nil
    var danger = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .regular)) }
                Text(title).font(RhemionStyle.font(12.5, .regular))
            }
            .foregroundStyle(!isEnabled ? RhemionStyle.tertiary(scheme == .dark) : danger ? RhemionStyle.danger : RhemionStyle.gold)
            .opacity(isEnabled && hover ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

// MARK: - Window layout

/// THE layout standard of every two-column app window (DESIGN.md "Window layout"): taken from the
/// Uninstall (farewell) window and reused by Clear Data — a recessed side column (logo, title, subtitle,
/// optional figures, a quiet hint pinned to the bottom) and a main column with the same margins on every
/// screen. Welcome is the hero exception (bigger logo/title, see DESIGN.md). Plain sheets (export deletion)
/// use the main-column margins only.
enum WindowLayout {
    /// Side column width.
    static let sideWidth: CGFloat = 236
    /// Side column padding: top / sides / bottom.
    static let sidePadding = EdgeInsets(top: 26, leading: 22, bottom: 22, trailing: 22)
    /// The logo's size, and its optical shift left (its outer ring is soft, so it reads aligned with the title).
    static let logoSize: CGFloat = 104
    static let logoInset: CGFloat = -4
    /// The side column's vertical rhythm: logo → title → subtitle → figures.
    static let sideSpacing: CGFloat = 12
    /// The minimum room between the side column's content and its bottom hint.
    static let sideHintGap: CGFloat = 12
    static var titleFont: Font { RhemionStyle.font(20, .heavy) }
    static var subtitleFont: Font { RhemionStyle.font(13) }
    static let subtitleLineSpacing: CGFloat = 3
    static var hintFont: Font { RhemionStyle.font(11) }
    /// Main column padding: top / sides / bottom (the bottom is the button row's bottom margin, the
    /// trailing side its right margin).
    static let mainPadding = EdgeInsets(top: 26, leading: 26, bottom: 22, trailing: 26)
    /// Between the blocks of a choosing screen (options → notes → button row).
    static let blockGap: CGFloat = 18
    /// Between the pieces of a step / result screen (title → text → list → button row).
    static let stepGap: CGFloat = 12
    /// Title of a step / result screen in the main column.
    static var stepTitleFont: Font { RhemionStyle.font(15, .semibold) }
    /// Between the buttons of a button row (right-aligned; Raised R1 buttons are 30 pt tall).
    static let buttonSpacing: CGFloat = 8
    /// The window is never shorter than this — the side column always has room for its content.
    static let minHeight: CGFloat = 330

    // The operation pop-up (DESIGN.md "Operation pop-up"): a compact borderless panel over its window.
    /// Pop-up width; its height is its content.
    static let popupWidth: CGFloat = 400
    /// Pop-up padding: top / sides / bottom (the button row's bottom and right margins).
    static let popupPadding = EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24)
    /// Between the pop-up's pieces (title → rows → notes → button row).
    static let popupGap: CGFloat = 14
    /// The pop-up card's corner radius.
    static let popupRadius: CGFloat = 12
}

/// The two columns of a standard window: the side column sized to `WindowLayout.sideWidth`, the main column
/// filling the rest with the standard padding, both as tall as the taller of them (never below
/// `minHeight`). The window's height is exactly that — no empty field, and the side column can never be cut.
struct StandardWindow<Side: View, Main: View>: View {
    let width: CGFloat
    var minHeight: CGFloat = WindowLayout.minHeight
    @ViewBuilder let side: () -> Side
    @ViewBuilder let main: () -> Main
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        StandardWindowLayout(sideWidth: WindowLayout.sideWidth, minHeight: minHeight) {
            side()
            main()
                .padding(WindowLayout.mainPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .background(RhemionStyle.content(dark))
        .foregroundStyle(RhemionStyle.text(dark))
    }
}

/// Measures both columns at their widths with no height limit, takes the taller (or `minHeight`), and
/// places both at that height.
private struct StandardWindowLayout: Layout {
    let sideWidth: CGFloat
    let minHeight: CGFloat

    private func height(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        guard subviews.count == 2 else { return minHeight }
        let side = subviews[0].sizeThatFits(ProposedViewSize(width: sideWidth, height: nil)).height
        let main = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - sideWidth), height: nil)).height
        return max(minHeight, side, main).rounded(.up)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (sideWidth + 500)
        return CGSize(width: width, height: height(width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: sideWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + sideWidth, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width - sideWidth, height: bounds.height))
    }
}

/// The standard side column: the logo, the title, an optional subtitle, optional figures (`extra`), and a
/// quiet hint pinned to the bottom — on the `rail` ground with a hairline edge.
struct WindowSideColumn<Extra: View>: View {
    @ObservedObject var clock: WelcomeLogoClock
    var farewell = false
    let title: String
    var subtitle: String? = nil
    var hint: String? = nil
    @ViewBuilder var extra: () -> Extra
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: WindowLayout.sideSpacing) {
            WelcomeLogo(clock: clock, size: WindowLayout.logoSize, farewell: farewell)
                .padding(.leading, WindowLayout.logoInset)
            Text(title).font(WindowLayout.titleFont)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(WindowLayout.subtitleFont).lineSpacing(WindowLayout.subtitleLineSpacing)
                    .foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            extra()
            Spacer(minLength: WindowLayout.sideHintGap)
            if let hint {
                Text(hint)
                    .font(WindowLayout.hintFont).foregroundStyle(RhemionStyle.tertiary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(WindowLayout.sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RhemionStyle.rail(dark))
        .overlay(alignment: .trailing) { Rectangle().fill(RhemionStyle.line(dark)).frame(width: 1) }
    }
}

extension WindowSideColumn where Extra == EmptyView {
    init(clock: WelcomeLogoClock, farewell: Bool = false, title: String, subtitle: String? = nil, hint: String? = nil) {
        self.init(clock: clock, farewell: farewell, title: title, subtitle: subtitle, hint: hint) { EmptyView() }
    }
}

/// A right-aligned button row with the standard spacing; `leading` holds notes on the left (optional).
struct WindowButtonRow<Leading: View, Buttons: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var buttons: () -> Buttons
    var body: some View {
        HStack(spacing: WindowLayout.buttonSpacing) {
            leading()
            Spacer(minLength: 8)
            buttons()
        }
    }
}

extension WindowButtonRow where Leading == EmptyView {
    init(@ViewBuilder buttons: @escaping () -> Buttons) {
        self.init(leading: { EmptyView() }, buttons: buttons)
    }
}

/// Every standard window opens in the true middle of the screen under the pointer, after its SwiftUI
/// content has settled the size (NSWindow.center() sits deliberately above the middle).
@MainActor
func centerOnPointerScreen(_ window: NSWindow) {
    if let view = window.contentViewController?.view {
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        if fit.width > 0, fit.height > 0 { window.setContentSize(fit) }
    }
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
        window.center(); return
    }
    let area = screen.visibleFrame, size = window.frame.size
    window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                  y: (area.midY - size.height / 2).rounded()))
}
