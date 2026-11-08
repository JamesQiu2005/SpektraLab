//  InterfaceScale.swift — Settings › Appearance's 80, 100, 120 and 150 % interface sizes.
//
//  A page lays out in 1/f of the window's room and draws at f, with displayScale raised by f so
//  pictures request enough pixels. Text, controls, filmstrips and split handles scale together.
//  Mac-point pages and scene-point pages have separate base factors; PAGES.md describes both.
//  The Light Table keeps the window's own points so Actual Size remains a physical measurement.
//  The choice is stored under ui.scale and applied immediately.

import SwiftUI
import UIKit

enum InterfaceScale: Int, CaseIterable, Identifiable {
    case p80 = 80, p100 = 100, p120 = 120, p150 = 150

    static let key = "ui.scale"
    static let standard: InterfaceScale = .p100
    var id: Int { rawValue }

    /// "100 %", in the app's language's way of writing a percentage.
    var title: String { (Double(rawValue) / 100).formatted(.percent.locale(Language.shared.current.locale)) }

    /// The kept choice (a value from elsewhere reads as 100 %).
    static func stored(_ defaults: UserDefaults = .standard) -> InterfaceScale {
        InterfaceScale(rawValue: defaults.integer(forKey: key)) ?? standard
    }

    /// What a page is drawn in: Mac points (the Mac library, Settings, Import, Export: `MacMetric`) or the
    /// scene points (the develop page, the crop page, the film-edge flow).
    enum Page { case macPoints, padPoints }

    /// The chosen scale times the page's base factor. In scaled Catalyst mode a scene point
    /// occupies 0.77 Mac points; the Develop layout targets 0.9625 Mac points at 100 %.
    @MainActor func factor(_ page: Page) -> CGFloat {
        let choice = CGFloat(rawValue) / 100
        switch page {
        case .macPoints: return choice * 10 / 9
        case .padPoints: return choice * Self.padTarget / MacMetric.scale
        }
    }

    /// Mac points a scene point stands at on the Mac at 100 %: the old develop page's 0.77 × 100/80.
    static let padTarget: CGFloat = 0.77 * 100 / 80

    /// The factor the kept choice gives `page`, for code outside a view (`MacWindow`, `followsWindow`).
    @MainActor static func current(_ page: Page) -> CGFloat { stored().factor(page) }
}

private struct InterfaceFactorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The factor the page around this view is drawn at (`interfaceScaled`): window points per page point.
    /// A view that measures in the window's points (`.global`) and pads in its own divides by it.
    var interfaceFactor: CGFloat {
        get { self[InterfaceFactorKey.self] }
        set { self[InterfaceFactorKey.self] = newValue }
    }
}

extension View {
    /// A page tree drawn at the kept interface scale (`InterfaceScale`): laid out in `1/f` of its room and
    /// drawn `f` times larger, crisp.
    func interfaceScaled(_ page: InterfaceScale.Page) -> some View {
        modifier(InterfaceScaled(page: page))
    }
}

private struct InterfaceScaled: ViewModifier {
    let page: InterfaceScale.Page
    @AppStorage(InterfaceScale.key) private var raw = InterfaceScale.standard.rawValue
    @Environment(\.displayScale) private var displayScale
    @Environment(\.interfaceFactor) private var outer

    func body(content: Content) -> some View {
        let f = (InterfaceScale(rawValue: raw) ?? .standard).factor(page)
        // Each page tree is scaled once, at its host's root: a page, a cover. A cover may inherit the
        // presenting page's environment, its raised `displayScale` with it, so the screen's own is that
        // over the factor it was raised by.
        let screen = displayScale / max(outer, 0.01)
        // One shape at every factor, 1 included, so a change of scale keeps every view's state.
        GeometryReader { geo in
            content
                .environment(\.interfaceFactor, f)
                .environment(\.displayScale, screen * f)
                .frame(width: geo.size.width / f, height: geo.size.height / f)
                .scaleEffect(f, anchor: .topLeading)
        }
    }
}
