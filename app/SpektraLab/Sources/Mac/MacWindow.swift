//  MacWindow.swift — the Mac window's least size (the owner, 2026-10-23): no upright or narrow layout on
//  the Mac **at all**. The window cannot be made narrower than the column needs, and `WindowLayout`
//  answers `.column` for any Mac window (WindowLayoutRule.swift), so a tall window is the column too —
//  never the window's stack, never the host's pages.

import UIKit

enum MacWindow {
    /// In the scene's points (scene points, drawn at 0.77 of a Mac point): 1,100 × 700 is 847 × 539 Mac
    /// points. The picture side keeps room for the bar's way back, the frame count and its ten controls
    /// beside the 393 pt column; the Library its 260 Mac pt sidebar and a grid five pictures wide.
    static let minimumSize = CGSize(width: 1100, height: 700)

    /// The owner, 2026-10-24: no "SpektraLab" at the top of the window, in either mode (bold white on the Light
    /// ground, it was all but unreadable). The title bar's title is hidden; the window keeps its name for the
    /// Window menu and Mission Control (`UIWindowScene.title` is not touched), and its buttons.
    @MainActor static func hideTitle() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
        }
    }

    /// Every window of the app, as it appears and as the interface scale changes (`RootView`). From 2026-10-24
    /// the least size grows with the develop page's scale past the old page's (InterfaceScale.swift: 80 %), so
    /// the page has the room it had; never past nine tenths of the display, where a window must still fit.
    @MainActor static func applyMinimumSize() {
        let f = max(1, InterfaceScale.current(.padPoints))
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let screen = scene.screen.bounds.size
            scene.sizeRestrictions?.minimumSize = CGSize(width: min(minimumSize.width * f, screen.width * 0.9),
                                                         height: min(minimumSize.height * f, screen.height * 0.9))
        }
    }
}
