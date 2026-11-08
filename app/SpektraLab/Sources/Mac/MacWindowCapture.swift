//  MacWindowCapture.swift — the Mac's real window, written to a PNG from inside the app.
//
//      SpektraLab --capture-window <dir>
//      notifyutil -p com.spektralab.mac.capture        # one more capture, now
//
//  Not the snapshot harness (a page drawn in a window that is never shown) and not
//  the tour (the router walked by a script): the window as it stands on the Mac,
//  whatever was clicked, at the moment it is asked for. Each capture is
//  <dir>/NN.png (key window), plus NN+k.png for every other window of the app —
//  a sheet under Catalyst is a window of its own. It is drawn by the app itself
//  (drawHierarchy), so it needs no Screen Recording permission.

import UIKit
import notify

@MainActor
enum MacWindowCapture {
    private static var directory: URL?
    private static var count = 0
    private static var token: Int32 = 0

    static func startIfAsked(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--capture-window"), i + 1 < arguments.count else { return }
        let dir = URL(fileURLWithPath: arguments[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        notify_register_dispatch("com.spektralab.mac.capture" + notifyTag(arguments), &token, .main) { _ in
            MainActor.assumeIsolated { capture() }
        }
        // The first, once the window has drawn its first page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { capture() }
    }

    /// `--notify-tag <t>`: this instance listens on `….capture.<t>` and `….drive.<t>.<step>`
    /// instead, so two debug builds driven at once (parallel worktrees) do not answer each
    /// other's notifications — Darwin notifications are system-wide. Empty without it.
    static func notifyTag(_ arguments: [String] = CommandLine.arguments) -> String {
        guard let i = arguments.firstIndex(of: "--notify-tag"), i + 1 < arguments.count else { return "" }
        return "." + arguments[i + 1]
    }

    static func capture() {
        guard let directory else { return }
        count += 1
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 0 }
        let key = windows.first(where: \.isKeyWindow) ?? windows.first
        var others = 0
        for w in windows {
            // A window on another Space or behind others is not redrawn by the display link: what changed
            // since is laid out now, so the capture is the window's state, not its last frame (2026-10-23).
            w.setNeedsLayout()
            w.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in
                w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
            }
            let name: String
            if w === key { name = String(format: "%02d.png", count) } else { others += 1; name = String(format: "%02d+%d.png", count, others) }
            try? image.pngData()?.write(to: directory.appendingPathComponent(name))
        }
        print("capture \(count): \(windows.count) window(s), key \(key.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-")")
    }
}
