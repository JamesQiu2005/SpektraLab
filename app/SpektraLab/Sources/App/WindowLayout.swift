//  WindowLayout.swift — the window's shape, as it stands, for the pages that read it.
//
//  Every Mac window is the column (WindowLayoutRule.swift): the picture and its filmstrip at one side,
//  one column of controls at the other. `WindowShape` is the root window's size as it stands; a page that
//  needs its own room (a sheet, a pane) measures that.

import SwiftUI
import UIKit

/// The root window's size, as it stands. Owned by `AppServices`, handed to every page and
/// sheet with the app's other objects (`appEnvironment`), set by `RootView` from its geometry.
@MainActor @Observable
final class WindowShape {
    private(set) var size: CGSize = .zero

    /// The window is now `size`.
    func follow(_ size: CGSize) {
        #if DEBUG
        let size = harnessSize ?? size
        #endif
        guard size != self.size else { return }
        self.size = size
        #if DEBUG
        NSLog("[window] size %@", String(describing: size))
        #endif
    }

    /// How far a top bar's leading content moves to clear the window's controls (close, minimise and tile at the leading corner); 0 where
    /// there are none — full screen, Split View without them. Measured by
    /// `WindowControlsProbe` from UIKit's corner-adapted safe area (where the SDK provides it).
    private(set) var controlsLeading: CGFloat = 0
    /// The controls' depth from the window's top, for a bar that cannot move sideways.
    private(set) var controlsTop: CGFloat = 0

    func followControls(leading: CGFloat, top: CGFloat) {
        if leading != controlsLeading { controlsLeading = leading }
        if top != controlsTop { controlsTop = top }
    }

    /// The window's own top safe area, in the points of a page drawn in scene points (the title bar
    /// kept out of the page: 41 pt on a windowed Mac window, measured 2026-10-26), and **0 in full
    /// screen**, where the window's top edge is the display's. The page is laid out below it, so a bar
    /// that wants a margin of its own from the window's top has to ask. Nil until the window has been
    /// measured, so the first frame draws as it always did rather than jumping when the inset arrives.
    private(set) var safeTop: CGFloat?
    func followSafeTop(_ top: CGFloat) { if top != safeTop { safeTop = top } }

    #if DEBUG
    /// The snapshot harness's window, which is the window whatever the root measures inside it.
    var harnessSize: CGSize? {
        didSet { if let harnessSize { follow(harnessSize) } }
    }
    #endif
}

extension View {
    /// The root's: follows the window's size into `shape`.
    func followsWindow(_ shape: WindowShape) -> some View {
        modifier(FollowsWindow(shape: shape))
        #if DEBUG
        // `log show … "[window]"`: what the window gives the app.
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { i in
            NSLog("[window] size %@ safe area top %.1f leading %.1f bottom %.1f trailing %.1f",
                  String(describing: shape.size), i.top, i.leading, i.bottom, i.trailing)
        }
        #endif
    }
}

/// The window measured in the page's scene points — the window's size over their interface scale (InterfaceScale.swift) — so a page and the shape
/// agree on its room (at 150 % the room of a window 1/1.5 the size).
private struct FollowsWindow: ViewModifier {
    let shape: WindowShape
    @AppStorage(InterfaceScale.key) private var scale = InterfaceScale.standard.rawValue
    @State private var whole: CGSize = .zero
    /// The window's top inset as the window gives it (41 pt on a windowed Mac window, 0 in full
    /// screen), kept so a change of interface scale re-divides it as it re-divides `whole`.
    @State private var top: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                // The whole window, safe areas included: the layout is the window's, not the page's.
                let i = proxy.safeAreaInsets
                return CGSize(width: proxy.size.width + i.leading + i.trailing,
                              height: proxy.size.height + i.top + i.bottom)
            } action: { whole = $0; follow() }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0; followSafeTop() }
            .onChange(of: scale) { _, _ in follow(); followSafeTop() }
    }

    private var factor: CGFloat { (InterfaceScale(rawValue: scale) ?? .standard).factor(.padPoints) }

    private func follow() {
        let f = factor
        shape.follow(f == 1 ? whole : CGSize(width: whole.width / f, height: whole.height / f))
    }

    /// The page is laid out below the window's top inset; `safeTop` says how much of it there is, in the
    /// page's own points, so a bar can keep a margin of its own where the window's top is the display's.
    private func followSafeTop() {
        let f = factor
        shape.followSafeTop(f == 1 ? top : top / f)
    }
}

/// Reads the room the window's controls take at the top leading corner: the safe area adapted to
/// the window's corners, less the plain safe area. `UIView.edgeInsets(for:)`; SwiftUI has
/// no word for it. It sits behind the root, over the whole window.
struct WindowControlsProbe: UIViewRepresentable {
    let shape: WindowShape

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.shape = shape
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.shape = shape; view.measure() }

    final class ProbeView: UIView {
        weak var shape: WindowShape?

        override func layoutSubviews() { super.layoutSubviews(); measure() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measure() }

        func measure() {
            guard #available(iOS 26.0, *), let shape else { return }
            let plain = directionalEdgeInsets(for: .safeArea())
            let across = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
            let down = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .vertical))
            let leading = max(0, across.leading - plain.leading)
            let top = max(0, down.top - plain.top)
            #if DEBUG
            if leading != shape.controlsLeading || top != shape.controlsTop { NSLog("[window] controls leading %.1f top %.1f plain %@ size %@", leading, top, String(describing: plain), String(describing: bounds.size)) }
            #endif
            DispatchQueue.main.async { shape.followControls(leading: leading, top: top) }
        }
    }
}

extension View {
    /// A top bar that may sit at the window's top leading corner: when it does, and the window has
    /// controls there, its content moves clear of them — sideways (`.leading`, as the system's own
    /// toolbars do) or down (`.down`, for a page whose top is a title). A bar anywhere else, or a
    /// window without controls, is left exactly as it was.
    func clearsWindowControls(_ way: WindowControlsWay = .leading) -> some View { modifier(ClearsWindowControls(way: way)) }
}

enum WindowControlsWay { case leading, down }

private struct ClearsWindowControls: ViewModifier {
    @Environment(WindowShape.self) private var window
    /// The page's interface scale (InterfaceScale.swift): the controls and `place` are in the window's
    /// points, the padding in the page's.
    @Environment(\.interfaceFactor) private var factor
    let way: WindowControlsWay
    /// Where the bar is in the window, padding included (its leading and top edges do not move with it).
    @State private var place: CGRect = .zero

    private var overlaps: Bool {
        window.controlsLeading > 0 && place.minX < window.controlsLeading && place.minY < max(window.controlsTop, 1)
    }

    func body(content: Content) -> some View {
        content
            .padding(.leading, way == .leading && overlaps ? (window.controlsLeading - max(0, place.minX)) / factor : 0)
            .padding(.top, way == .down && overlaps ? (window.controlsTop - max(0, place.minY)) / factor : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place = $0 }
            .animation(.easeOut(duration: 0.2), value: overlaps)
    }
}
