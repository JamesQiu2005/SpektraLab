//  Sheets.swift — a sheet over the black app.
//
//  The drawings' sheet (`sheet_top` in gen_flow.py): the plot colour, 26 pt top
//  corners, a grabber, a 19 pt title with an optional line under it, a close
//  button — over a 0.62 black scrim. On the host it is a real `.sheet`, so it
//  drags, dismisses and avoids the keyboard as the operating system sheets do; `spkSheet`
//  dresses it. `SheetStage` draws the same content the way the drawing shows
//  it, over a page and a scrim, for the snapshot harness and nothing else.

import SwiftUI

/// The top of a sheet: grabber, title, and a close button or a word at the
/// trailing edge — each where `sheet_top` puts it, measured from the sheet's
/// top edge: the title's baseline at 44, the line under it at 64, the close
/// button's centre at 38 and 34 in from the trailing edge.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    /// A word at the trailing edge in place of the close button ("1 of 1").
    var trailing: String? = nil
    var onClose: (() -> Void)? = nil

    /// What the header takes in a stack. The drawings give no such number — a
    /// sheet's parts are all placed from its top edge — so this is the height
    /// the pages that stack under it are measured with.
    static func height(subtitle: Bool) -> CGFloat { subtitle ? 67 : 63 }

    var body: some View {
        DrawnBand(height: Self.height(subtitle: subtitle != nil)) {
            Capsule().fill(Theme.text.opacity(0.28)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity).top(7)
            // A file's name can be any length: it is set smaller before it is
            // cut, and cut in the middle so its ending stays.
            DrawnText(title, 19, .bold, fit: true)
                .truncationMode(.middle)
                .spanning(leading: 20, trailing: onClose == nil ? 84 : 64)
                .baseline(44)
            if let subtitle {
                DrawnText(subtitle, 12.5, .medium, Theme.dim, fit: true)
                    .spanning(leading: 20, trailing: 64)
                    .baseline(64)
            }
            if let onClose {
                // The disc is 30 in a 44 pt target: its centre 34 from the edge.
                CloseButton(action: onClose).trailingInset(12).centreY(38)
            } else if let trailing {
                DrawnText(trailing, 13, .medium, Theme.dim).trailingInset(20).baseline(44)
            }
        }
    }
}

private struct SpkSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let detents: Set<PresentationDetent>
    @ViewBuilder var sheet: (Item) -> SheetContent

    func body(content: Content) -> some View {
        content.sheet(item: $item) { item in
            sheet(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .presentationDetents(detents)
                .presentationDragIndicator(.hidden)          // `SheetHeader` draws the drawing's own
                .presentationCornerRadius(Theme.Metric.sheetRadius)
                .presentationBackground(Theme.sheet)
                .appColorScheme()
        }
    }
}

extension View {
    /// Present one of the app's sheets. `detents` is how tall the drawing
    /// draws it; `.large` for the tall ones (Export, Copy Settings).
    func spkSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        detents: Set<PresentationDetent> = [.large],
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(SpkSheetModifier(item: item, detents: detents, sheet: content))
    }
}

/// The drawing's picture of a sheet: a page, the scrim, and the sheet's
/// content from `top` down. **Snapshot harness only** — the running app
/// presents with `spkSheet`.
struct SheetStage<Under: View, SheetContent: View>: View {
    /// Where the sheet's top edge sits on the drawing's 852 pt page, measured
    /// from the screen's top edge.
    let top: CGFloat
    @ViewBuilder var under: () -> Under
    @ViewBuilder var sheet: () -> SheetContent

    var body: some View {
        ZStack(alignment: .top) {
            under()
            Color.black.opacity(Theme.scrimOpacity).ignoresSafeArea()
                .scrimsChrome(Theme.scrimOpacity)
            sheet()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.sheet)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Metric.sheetRadius,
                                                  topTrailingRadius: Theme.Metric.sheetRadius,
                                                  style: .continuous))
                .padding(.top, top)
                .ignoresSafeArea()
        }
    }
}

// MARK: - what a scrim does to the status bar, for the snapshot harness

/// How much of the stand-in status bar and home indicator a page's scrims let
/// through: 1 is undimmed. The drawings draw the status bar under a sheet's
/// scrim and under a menu's; on a host the bar is the system's and nothing
/// reads this.
struct ChromeTransmission: Equatable {
    var statusBar = 1.0
    var homeIndicator = 1.0
}

struct ChromeTransmissionKey: PreferenceKey {
    static let defaultValue = ChromeTransmission()
    static func reduce(value: inout ChromeTransmission, nextValue: () -> ChromeTransmission) {
        let next = nextValue()
        value.statusBar *= next.statusBar
        value.homeIndicator *= next.homeIndicator
    }
}

extension View {
    /// Says a scrim this dark lies over the status bar (and, for a menu, over
    /// the home indicator too): the snapshot harness dims its stand-ins to match.
    func scrimsChrome(_ opacity: Double, homeIndicator: Bool = false) -> some View {
        preference(key: ChromeTransmissionKey.self,
                   value: ChromeTransmission(statusBar: 1 - opacity, homeIndicator: homeIndicator ? 1 - opacity : 1))
    }
}
