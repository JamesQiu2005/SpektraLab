//  SpektraLabApp.swift — the Mac app's entry point and menu commands.
//  `AppServices` owns the library, scheduler and engine host; the target links the engine when
//  `SPK_ENGINE` is set by gen_project.py after tools/build_engine_mac.sh.

import SwiftUI
import UIKit

/// The executable's entry: an agent's client (`SpektraLab cli …`, `SpektraLab mcp`; ARCHITECTURE.md
/// §7.16), else the app. Decided from the first argument before anything of UIKit's is touched: a client
/// is a short conversation with the running app over its socket (`AgentClient`), never a second app — a
/// catalog's database is the running app's helper's alone.
@main
enum SpektraLabMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "cli" || arguments[1] == "mcp" {
            exit(AgentClient.run(Array(arguments.dropFirst())))
        }
        SpektraLabApp.main()
    }
}

struct SpektraLabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppServices.launch()

    var body: some Scene {
        WindowGroup {
            RootView().appEnvironment(model)
        }
        // the operating system's menu bar: the app's places and their keys (AppMenuCommands.swift).
        .commands {
            AppMenuCommands(model: model)
            // The develop page's Undo and Redo in the Edit menu (DevelopMenuCommands.swift): the operating system 26's
            // menu bar takes ⌘Z before any button on a page.
            DevelopMenuCommands()
            // The Mac's Edit menu: ⌘C and ⌘V are Copy and Paste Settings where no field has the keys
            // (MacEditCommands.swift).
            MacEditCommands()
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        if builder.system == .main { MacShortcutRegistry.shared.buildMenu(builder) }
    }
    override var keyCommands: [UIKeyCommand]? { MacShortcutRegistry.shared.keyCommands }
    @objc func spkShortcut(_ command: UIKeyCommand) { MacShortcutRegistry.shared.perform(command) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(spkShortcut(_:)), let c = sender as? UIKeyCommand { return MacShortcutRegistry.shared.canPerform(c) }
        return super.canPerformAction(action, withSender: sender)
    }
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // `--snapshot <dir>`: draw every page to a PNG and leave, before any
        // window is shown (tools/snapshot.sh).
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            SnapshotHarness.run(request)
            exit(0)
        }
        MacWindowCapture.startIfAsked()      // `--capture-window <dir>` (Sources/Mac)
        return true
    }
}
