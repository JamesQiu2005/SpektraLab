//  RootView.swift — the Library as home, and everything presented from it.

import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppServices.self) private var model
    @Environment(\.scenePhase) private var phase
    @AppStorage(InterfaceScale.key) private var interfaceScale = InterfaceScale.standard.rawValue

    var body: some View {
        @Bindable var router = model.router
        stack(router)
        #if DEBUG
        // The window's windows (2026-10-20): every push and pop, for `log show … "[navtrace]"`.
        .onChange(of: router.path) { old, new in NSLog("[navtrace] path %@ -> %@", String(describing: old), String(describing: new)) }
        #endif
        .modifier(SheetHost(level: 0, active: router.cover == nil))
        .fullScreenCover(item: $router.cover) { cover in
            CoverContent(route: cover)
                .modifier(SheetHost(level: 0))
                .appEnvironment(model)
                .appColorScheme()
        }
        .background(Theme.background.ignoresSafeArea())
        // window: the room the window's controls take, for the top bars to clear (WindowLayout.swift).
        .background(WindowControlsProbe(shape: model.window).ignoresSafeArea())
        // the appearance Settings chose, Dark
        // or Light, where every page, cover and sheet asked for dark (an reference device's is always dark).
        .appColorScheme()
        .tint(Theme.accent)
        .followsWindow(model.window)                                      // window: the window's shape picks the layout (WindowLayout.swift)
        // `--tour <dir>`: walk every presentation in this real window (Tour.swift).
        .onAppear { Tour.startIfAsked(model: model) }
        .onAppear { MacWindow.applyMinimumSize() }                       // the Mac: no narrow window (Sources/Mac/MacWindow.swift)
        .onAppear { MacWindow.hideTitle() }                              // …and no "SpektraLab" over it
        .onChange(of: interfaceScale) { _, _ in MacWindow.applyMinimumSize() }   // …for the page's scale (InterfaceScale.swift)
        #if DEBUG
        .onAppear { MacDriver.startIfAsked(model: model) }               // the Mac: `--mac-drive` (Sources/Mac)
        .onAppear { MacLibraryCheck.startIfAsked(model: model) }         // the Mac: `--library-check <dir>` (Sources/Mac/Library)
        .onAppear { MacLibraryEntryCheck.startIfAsked(model: model) }    // --library-entry-check: picker dispatch and metadata persistence
        .onAppear { MacImportCheck.startIfAsked(model: model) }          // the Mac: `--import-check <dir>` (Sources/Mac/Import)
        .onAppear { MacImportDropCheck.startIfAsked(model: model) }      // the Mac: `--drop-check <dir>` (Sources/Mac/Import)
        .onAppear { MacExportCheck.startIfAsked(model: model) }          // the Mac: `--export-check <dir>` (Sources/Mac/Export)
        .onAppear { MacRenderCheck.startIfAsked(model: model) }          // the Mac: `--render-check <dir>` (Sources/Mac/Render)
        .onAppear { MacSettingsCheck.startIfAsked(model: model) }        // the Mac: `--settings-check <dir>` (Sources/Mac/Settings)
        .onAppear { MacLightTableCheck.startIfAsked(model: model) }      // the Mac: `--lighttable-check <dir>` (Sources/Mac/LightTable)
        #endif
        #if SPK_LOG_UPLOAD
        .modifier(ShareLogAsk())                                          // the log: may it be shared? (a testers' build's)
        #endif
        .modifier(UpdateAnnounce())                                       // Check for Updates at launch (Settings › General)
        // GPU work is refused in the background: the scheduler holds every job
        // until the app is in front again (RFC-036 §6.7).
        .onChange(of: phase, initial: true) { _, new in
            switch new {
            case .active: model.scheduler.frontend.scene = .active
            case .inactive: model.scheduler.frontend.scene = .inactive
            case .background: model.scheduler.frontend.scene = .background
            @unknown default: model.scheduler.frontend.scene = .inactive
            }
        }
    }
}

extension RootView {
    /// The window's pages. On the Mac (the owner, 2026-10-27) the root is the persistent window shell —
    /// the bar, the browser and the mode's content, 图库 or 冲洗/编辑 — and the stack carries only the
    /// full-window pages above the last develop (`MacShellPath`), so a mode change is no push. The window and
    /// the reference device push every page, as they did.
    @ViewBuilder func stack(_ router: AppRouter) -> some View {
        NavigationStack(path: MacShellPath.binding(router)) {
            MainWindowLayout()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    RouteContent(route: route).toolbar(.hidden, for: .navigationBar)
                }
        }
    }
}

/// The first time the app is opened, a moment after the Library is on the screen: may the log be
/// shared? Asked once; Settings › Diagnostics has the switch from then on. A build with the sending
/// compiled alone (`SPK_LOG_UPLOAD`): any other sends nothing, and asks nothing.
#if SPK_LOG_UPLOAD
private struct ShareLogAsk: ViewModifier {
    @Environment(AppServices.self) private var model
    /// The app asks, once, whether its log may be shared (`Diagnostics`).
    @State private var asks = false

    func body(content: Content) -> some View {
        content
            .task {
                try? await Task.sleep(for: .seconds(1))
                asks = model.diagnostics.shouldAsk
            }
            .alert(DiagnosticsPage.askTitle, isPresented: $asks) {
                Button(L("Share")) { model.diagnostics.answer(share: true) }
                Button(L("Don't Share"), role: .cancel) { model.diagnostics.answer(share: false) }
            } message: {
                Text(DiagnosticsPage.ask)
            }
    }
}
#endif

/// The pages draw their own top bars, so the system's is hidden — and a hidden
/// bar switches the edge swipe off with it. This keeps the swipe: from
/// Develop, a swipe from the leading edge goes back to the Library.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
