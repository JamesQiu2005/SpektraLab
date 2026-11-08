//  AppearancePage.swift — Settings › Appearance (外观) on a Mac: the mode, the background and
//  the interface scale.
//
//  Mac change , drawn after ChatGPT's own Appearance page:
//  a large title; a heading, *Visual style*; a rounded group whose row *Mode* is three drawn windows side by
//  side — System (half light, half dark), Light, Dark — the chosen one in an accent-coloured frame; then a
//  second group, its rows split by hairlines, the words at the left and the control at the right. ChatGPT's
//  second group has theme, accent, background, foreground and font; ours **only the background** ("customizable
//  background color only") and the interface scale:
//  - **Background** (背景): a capsule of the ground's swatch and its hex; a click opens the picker under the
//    row (a colour well, a few grounds, the hex typed, and the way back to the default). One ground for Dark and one for
//    Light; the row sets the one on screen. The other surfaces follow it (`AppBackground`).
//  - **Interface scale** (界面缩放): 80 · 100 · 120 · 150 %, at once (`InterfaceScale`).
//  One view for both: the Mac's Settings page shows it as its Appearance section at Mac sizes (`.mac`), the
//  window's Settings pushes it as a page (`AppearancePage`). The reference device never shows it: its pages are always
//  dark, at their own size.

import SwiftUI
import UIKit

/// The page's figures at each size: the Mac's in Mac points (`MacMetric`), the window's in its own.
@MainActor
struct AppearanceStyle {
    let pt: (CGFloat) -> CGFloat
    let font: (CGFloat, Font.Weight) -> Font
    /// The large title, drawn by the view (the Mac's section) or not (the window's page header has it).
    var title: CGFloat?
    var heading: CGFloat
    var label: CGFloat
    var caption: CGFloat
    var card = CGSize(width: 116, height: 72)
    var gap: CGFloat = 12
    var row: CGFloat
    var inset: CGFloat = 14
    var corner: CGFloat
    var control: CGFloat
    var segment: CGFloat
    var controlText: CGFloat
    /// The group's fill: the Mac page's panels, the window's cards.
    var fill: Color

    static var mac: AppearanceStyle {
        AppearanceStyle(pt: { MacMetric.pt($0) }, font: { MacMetric.font($0, $1) }, title: 26, heading: 13, label: 13, caption: 11,
                        row: 40, corner: 10, control: 24, segment: 52, controlText: 12, fill: Theme.panel)
    }
}

/// The page's groups, at either size.
struct AppearanceSettings: View {
    let style: AppearanceStyle
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.standard.rawValue
    @AppStorage(InterfaceScale.key) private var scale = InterfaceScale.standard.rawValue
    @AppStorage(AppBackground.darkKey) private var darkGround = ""
    @AppStorage(AppBackground.lightKey) private var lightGround = ""
    @Environment(\.colorScheme) private var scheme
    @State private var picking = false

    /// The ground the Background row sets: the one on screen.
    private var light: Bool { scheme == .light }

    var body: some View {
        VStack(alignment: .leading, spacing: style.pt(10)) {
            if let title = style.title {
                Text(L("Appearance")).font(style.font(title, .bold)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, style.pt(8))
                    .settingsItem("Appearance")
            }
            Text(L("Visual style")).font(style.font(style.heading, .semibold)).foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, style.pt(4))
                .settingsItem("Visual style")
            group { modeRow }
            group {
                backgroundRow
                if picking {
                    hairline
                    BackgroundPicker(light: light, style: style)
                }
                hairline
                scaleRow
            }
            .padding(.top, style.pt(8))
            Text(L("The interface scale applies to the library, the develop page and every page over them, at once. 100% is a little larger than SpektraLab was; 80% is about its old develop page."))
                .font(style.font(style.caption, .regular)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, style.pt(4))
        }
        .onReceive(NotificationCenter.default.publisher(for: AppearanceSettings.openPicker)) { _ in picking = true }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.rule).frame(height: 1).padding(.leading, style.pt(style.inset))
    }

    /// A rounded group, as the page's other groups.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.fill, in: RoundedRectangle(cornerRadius: style.pt(style.corner), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: style.pt(style.corner), style: .continuous).strokeBorder(Theme.wall, lineWidth: 1))
    }

    // MARK: mode

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: style.pt(12)) {
            Text(L("Mode")).font(style.font(style.label, .regular)).foregroundStyle(Theme.text)
                .settingsItem("Mode")
            HStack(alignment: .top, spacing: style.pt(style.gap)) {
                ForEach(AppAppearance.allCases, id: \.self) { choice in modeCard(choice) }
            }
            .settingsItem("System", "Light", "Dark")
        }
        .padding(style.pt(style.inset))
    }

    private func modeCard(_ choice: AppAppearance) -> some View {
        let on = (AppAppearance(rawValue: mode) ?? .standard) == choice
        let w = style.pt(style.card.width), h = style.pt(style.card.height)
        return Button { mode = choice.rawValue } label: {
            VStack(spacing: style.pt(6)) {
                AppearanceThumbnail(choice: choice, pt: style.pt)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: style.pt(7), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: style.pt(7), style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
                    .padding(style.pt(3))
                    .overlay {
                        RoundedRectangle(cornerRadius: style.pt(9), style: .continuous)
                            .strokeBorder(on ? Theme.accent : .clear, lineWidth: style.pt(2))
                    }
                Text(choice.title).font(style.font(style.controlText, on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("appearance.mode.\(choice.rawValue)")
    }

    // MARK: background

    private var ground: UInt32 {
        _ = light ? lightGround : darkGround     // read, so the row follows a change
        return AppBackground.ground(light: light)
    }

    private var backgroundRow: some View {
        row(label: L("Background"), detail: light ? L("Light", as: "appearance") : L("Dark", as: "appearance")) {
            Button { withAnimation(.easeOut(duration: 0.15)) { picking.toggle() } } label: {
                HStack(spacing: style.pt(6)) {
                    Circle().fill(Color(hex: ground)).frame(width: style.pt(12), height: style.pt(12))
                        .overlay(Circle().strokeBorder(Theme.dim.opacity(0.6), lineWidth: 1))
                    Text(AppBackground.hexString(ground)).font(style.font(style.controlText, .medium)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                    Image(systemName: picking ? "chevron.up" : "chevron.down")
                        .font(style.font(style.controlText - 3, .semibold)).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, style.pt(10))
                .frame(height: style.pt(style.control))
                .background(Capsule().fill(Theme.field))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Background"))
            .accessibilityValue(AppBackground.hexString(ground))
            .accessibilityIdentifier("appearance.background")
        }
        .settingsItem("Background")
    }

    // MARK: scale

    private var scaleRow: some View {
        row(label: L("Interface scale"), detail: nil) {
            SegmentedSwitch(options: InterfaceScale.allCases,
                            selection: Binding(get: { InterfaceScale(rawValue: scale) ?? .standard }, set: { scale = $0.rawValue }),
                            title: \.title, segmentWidth: style.pt(style.segment), height: style.pt(style.control),
                            track: Theme.field, size: style.pt(style.controlText))
                .accessibilityIdentifier("appearance.scale")
        }
        .settingsItem("Interface scale")
    }

    private func row<Control: View>(label: String, detail: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: style.pt(12)) {
            VStack(alignment: .leading, spacing: style.pt(1)) {
                Text(label).font(style.font(style.label, .regular)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(style.font(style.caption, .regular)).foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, style.pt(style.inset))
        .padding(.vertical, style.pt(6))
        .frame(minHeight: style.pt(style.row))
    }

    /// A debug build's way to open the picker (`MacDriver`'s `appearance.picker`).
    static let openPicker = Notification.Name("spk.appearance.picker")
}

/// The picker the Background capsule opens under its row (in the group, not a popover: the same on the
/// Mac and the window, and at the page's own interface scale): a colour well, a few grounds, the hex typed,
/// and the way back to the default.
private struct BackgroundPicker: View {
    let light: Bool
    let style: AppearanceStyle
    @AppStorage(AppBackground.darkKey) private var darkGround = ""
    @AppStorage(AppBackground.lightKey) private var lightGround = ""
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var ground: UInt32 {
        _ = light ? lightGround : darkGround
        return AppBackground.ground(light: light)
    }

    private var grounds: [UInt32] { AppBackground.presets(light: light) }

    var body: some View {
        VStack(alignment: .leading, spacing: style.pt(12)) {
            HStack(spacing: style.pt(8)) {
                ForEach(grounds, id: \.self) { hex in
                    Button { AppBackground.choose(hex, light: light) } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: style.pt(22), height: style.pt(22))
                            .overlay(Circle().strokeBorder(hex == ground ? Theme.accent : Theme.dim.opacity(0.5),
                                                           lineWidth: hex == ground ? style.pt(2) : 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppBackground.hexString(hex))
                }
                Spacer(minLength: style.pt(12))
                // Any other colour: the system's picker (on the Mac, its colour panel).
                ColorPicker(L("Colour"), selection: Binding(get: { Color(hex: ground) },
                                                             set: { AppBackground.choose(AppBackground.hex(of: $0), light: light) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance.background.well")
            }
            HStack(spacing: style.pt(8)) {
                TextField("#1A1D22", text: $typed)
                    .font(style.font(style.controlText, .medium)).monospacedDigit()
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($typing)
                    .onSubmit(commit)
                    .padding(.horizontal, style.pt(8))
                    .frame(width: style.pt(96), height: style.pt(style.control))
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: style.pt(6), style: .continuous))
                Spacer(minLength: 0)
                Button(L("Use Default")) { AppBackground.choose(nil, light: light) }
                    .font(style.font(style.controlText, .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, style.pt(10))
                    .frame(height: style.pt(style.control))
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: style.pt(6), style: .continuous))
                    .buttonStyle(.plain)
                    .disabled(AppBackground.isDefault(light: light))
                    .opacity(AppBackground.isDefault(light: light) ? Theme.disabledOpacity : 1)
            }
            Text(light ? L("Light keeps a light background, so the words stay readable.")
                       : L("Dark keeps a dark background, so the words stay readable."))
                .font(style.font(style.caption, .regular)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(style.pt(style.inset))
        .onAppear { typed = AppBackground.hexString(ground) }
        .onChange(of: ground) { _, now in if !typing { typed = AppBackground.hexString(now) } }
        .onChange(of: typing) { _, now in if !now { commit() } }
    }

    private func commit() {
        guard let hex = AppBackground.hex(from: typed) else { typed = AppBackground.hexString(ground); return }
        let kept = AppBackground.choose(hex, light: light)
        typed = AppBackground.hexString(kept ?? ground)
    }
}

/// A mode's card: a small window drawn in that mode's own grounds — its bar, the column, a picture, the
/// filmstrip — from the tokens themselves, resolved for that mode (System: Light's left half, Dark's right).
private struct AppearanceThumbnail: View {
    let choice: AppAppearance
    let pt: (CGFloat) -> CGFloat
    @AppStorage(AppBackground.darkKey) private var darkGround = ""
    @AppStorage(AppBackground.lightKey) private var lightGround = ""

    var body: some View {
        _ = (darkGround, lightGround)       // read, so the cards follow a chosen ground
        return GeometryReader { geo in
            switch choice {
            case .light: window(light: true, in: geo.size)
            case .dark: window(light: false, in: geo.size)
            case .system:
                ZStack {
                    window(light: true, in: geo.size)
                    window(light: false, in: geo.size)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geo.size.width / 2) }
                }
            }
        }
    }

    /// A token as it is in the mode `light`.
    private func tone(_ c: Color, _ light: Bool) -> Color {
        Color(uiColor: UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: light ? .light : .dark)))
    }

    private func window(light: Bool, in size: CGSize) -> some View {
        let bar = size.height * 0.16
        let column = size.width * 0.34
        let strip = size.height * 0.2
        return ZStack(alignment: .topLeading) {
            tone(Theme.background, light)
            // The column, its card and three lines of words.
            VStack(alignment: .leading, spacing: pt(3)) {
                RoundedRectangle(cornerRadius: pt(2)).fill(tone(Theme.card, light)).frame(height: size.height * 0.16)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(tone(Theme.text, light).opacity(0.5)).frame(width: column * (i == 1 ? 0.45 : 0.62), height: pt(2.5))
                }
            }
            .padding(pt(4))
            .frame(width: column, height: size.height, alignment: .topLeading)
            .background(tone(Theme.panel, light))
            // The bar over the picture side: the way back and the accent's Export.
            HStack(spacing: pt(3)) {
                Capsule().fill(tone(Theme.text, light).opacity(0.5)).frame(width: pt(12), height: pt(2.5))
                Spacer(minLength: 0)
                Capsule().fill(Theme.accent).frame(width: pt(14), height: pt(5))
            }
            .padding(.horizontal, pt(5))
            .frame(width: size.width - column, height: bar)
            .offset(x: column)
            // The picture and the filmstrip under it.
            LinearGradient(colors: [Theme.edgeInk.opacity(0.8), Theme.rebate], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: size.width - column - pt(10), height: size.height - bar - strip - pt(4))
                .offset(x: column + pt(5), y: bar)
            HStack(spacing: pt(2)) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: pt(1)).fill(tone(Theme.card, light)).frame(width: pt(9), height: strip - pt(6))
                }
            }
            .frame(width: size.width - column, height: strip)
            .background(alignment: .top) { tone(Theme.wall, light).frame(height: 1) }
            .offset(x: column, y: size.height - strip)
            Rectangle().fill(tone(Theme.wall, light)).frame(width: 1, height: size.height).offset(x: column)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

extension View {
    /// The window Settings item this view stands for, for the Mac's `--settings-check` (`macSettingsItem`).
    func settingsItem(_ keys: String...) -> some View {
        macSettingsItem(keys)
    }
}
