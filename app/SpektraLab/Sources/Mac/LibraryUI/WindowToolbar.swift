//  WindowToolbar.swift — the window's one top bar, and the floating browser it collapses (the owner,
//  2026-10-27).
//
//  "Always have those buttons at the very right, and treat the library as something collapsible and
//  below it, somewhat floating, but no liquid glass effects." One bar runs the window's whole width in
//  every mode — 图库, 冲洗 and 编辑 alike: the shared controls (column, split, loupe, 裁剪, sort,
//  direction) at its leading edge, the picture's actions (undo, redo, ⋯, paste, compare, Export) pinned
//  to the window's trailing edge, and the browser's toggle last. Nothing the browser's width does can
//  clip or move them, and nothing moves when the mode row is pressed.
//
//  The browser is a panel below that bar, inset from the window's edges, its own rounded solid ground
//  with a hairline and a soft shadow — no material, no blur. Its header (the count and what is chosen,
//  the thumbnails' size, the search) is inside it, at its top. Its leading edge is dragged for its
//  width (kept, `MacLibraryBrowser.browserWidth`); ⌥⌘B or the bar's toggle puts it away, and the
//  picture takes the room.

import SwiftUI

/// The window's top bar: `controls` at the leading edge, `actions` at the trailing one, then the
/// browser's toggle.
struct WindowToolbar<Controls: View, Mode: View, Actions: View>: View {
    let browser: MacLibraryBrowser
    @ViewBuilder var controls: Controls
    /// 图库 · 冲洗 · 编辑 (`MacModeSwitch`, the owner, 2026-10-27): centred in the window where the window
    /// is at least `centreFrom` Mac points wide, else right after the shared controls.
    @ViewBuilder var mode: Mode
    @ViewBuilder var actions: Actions

    @Environment(WindowShape.self) private var window: WindowShape?
    @AppStorage(InterfaceScale.key) private var scaleChoice = InterfaceScale.standard.rawValue

    /// The bar's height, one in every mode.
    static var height: CGFloat { MacMetric.pt(44) }
    /// The window width (Mac points, at 100 %) from which the mode row stands in the window's centre
    /// (decided 2026-10-27). At a larger interface scale everything is larger, so the threshold is too.
    static var centreFrom: CGFloat { 1200 }
    /// The mode row's width in the bar.
    static var modeWidth: CGFloat { MacMetric.pt(216) }

    private var centred: Bool {
        guard let window, window.size.width > 0 else { return true }
        let choice = CGFloat(InterfaceScale(rawValue: scaleChoice)?.rawValue ?? 100) / 100
        return window.size.width * MacMetric.scale >= Self.centreFrom * choice
    }

    var body: some View {
        let centred = centred
        ZStack {
            HStack(spacing: MacMetric.pt(10)) {
                controls
                if !centred { mode.frame(width: Self.modeWidth) }
                Spacer(minLength: MacMetric.pt(8))
                actions
                browserToggle
            }
            if centred { mode.frame(width: Self.modeWidth) }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.wall).frame(height: 1) }
    }

    /// The browser, there or not: its icon mirrors the column's (`sidebar.right`, as the old column
    /// toggle had it). ⌘B, with ⌥⌘B retained as an alias; ⌘T folds the column.
    private var browserToggle: some View {
        Button { withAnimation(.smooth(duration: 0.2)) { browser.viewerShown.toggle() } } label: {
            Image(systemName: browser.viewerShown ? "sidebar.right" : "sidebar.squares.right")
                .font(MacMetric.font(14))
                .foregroundStyle(browser.viewerShown ? Theme.text : Theme.secondaryText)
                .frame(width: MacMetric.pt(26), height: MacMetric.pt(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(browser.viewerShown ? L("Hide the browser") : L("Show the browser"))
        .accessibilityLabel(L("Browser"))
        .accessibilityIdentifier("mac.bar.browser")
        // The shell registers Browser once, alongside its menu command (MacShortcuts).
        .padding(.leading, MacMetric.pt(4))
    }
}

/// The browser as the window draws it: a floating card at the trailing edge, under the top bar.
struct FloatingBrowser<Content: View>: View {
    let browser: MacLibraryBrowser
    /// The most the panel may take, in this page's points: the window less the column and the least the
    /// picture keeps (`FloatingBrowser.limit`). A kept width wider than this is drawn at this, unchanged
    /// in the defaults — a narrower window never pushes the page off its edges (2026-10-27: at 900 Mac
    /// points the row overflowed the window both ways).
    var limit: CGFloat = .infinity
    /// The grid has the window (`MacLibraryBrowser.fullGrid`): the card fills what it is given, no grip.
    var full = false
    @ViewBuilder var content: Content

    @State private var drag: CGFloat?

    /// The panel's room in a window `width` wide beside a column `column` wide (both this page's points).
    static func limit(width: CGFloat, column: CGFloat) -> CGFloat {
        max(width - column - MacMetric.pt(320) - 8, MacMetric.pt(MacMetric.browserRange.lowerBound))
    }

    var body: some View {
        content
            .frame(width: full ? nil : min(MacMetric.pt(browser.browserWidth), limit))
            .frame(maxWidth: full ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.wall, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
            .overlay(alignment: .leading) { if !full { grip } }
            .padding(.trailing, 8)
            .padding(.bottom, 8)
    }

    /// The panel's leading edge, dragged for its width (a drag to the left makes it wider), 240 to 900
    /// Mac points, the same as the wall it replaces.
    private var grip: some View {
        Color.clear
            .frame(width: MacMetric.pt(9))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // Measured in the window: the grip rides the edge it drags, so its own space moves under the
            // pointer and the width shook back and forth (the owner, 2026-10-27).
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if drag == nil { drag = min(browser.browserWidth, limit * MacMetric.scale) }
                    let start = drag ?? browser.browserWidth
                    let w = start - v.translation.width * MacMetric.scale
                    let most = min(MacMetric.browserRange.upperBound, limit * MacMetric.scale)
                    browser.browserWidth = min(max(w, MacMetric.browserRange.lowerBound), max(most, MacMetric.browserRange.lowerBound))
                }
                .onEnded { _ in
                    drag = nil
                    browser.saveWidths()
                })
            .accessibilityLabel(L("Browser width"))
    }
}
