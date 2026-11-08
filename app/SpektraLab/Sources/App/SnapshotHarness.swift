//  SnapshotHarness.swift — page-layout PNGs in a controlled Mac window.
//  SpektraLab --snapshot <dir> [--only A1,B2] [--size 1440x900] [--scale 2]
//  The harness cannot prove the Metal canvas draws. Use MacWindowCapture for that.

import SwiftUI
import UIKit

/// One page in one state, and the drawing it is held against.
struct SnapshotPage: Identifiable {
    /// The flow map's id: "A1", "B2", "C3". A second state of a page takes a
    /// suffix: "A2-shutter".
    let id: String
    let title: String
    var scenario: DemoLibrary.Scenario = .home
    /// Drawn in a window this tall, whatever `--size` says: a page that
    /// scrolls, shown whole (the picker's papers are under twenty-four films).
    var tall: CGFloat? = nil
    let view: @MainActor (AppServices) -> AnyView

    init<V: View>(_ id: String, _ title: String, scenario: DemoLibrary.Scenario = .home,
                  @ViewBuilder view: @escaping @MainActor (AppServices) -> V) {
        self.id = id; self.title = title; self.scenario = scenario
        self.view = { AnyView(view($0)) }
    }
}

struct SnapshotRequest {
    var directory: URL
    var only: Set<String>?
    var size = CGSize(width: 1440, height: 900)
    var scale: CGFloat = 2
    /// `--insets top,left,bottom,right`: an explicit safe area for a layout check.
    var insets: UIEdgeInsets?
    /// `--switch-to zh-Hans`: each page is put up in the language of the launch, the language is
    /// then changed as Settings changes it, and the page is drawn as it stands a moment later —
    /// without being made again. Held against the same pages launched in that language
    /// (`tools/snapshot.sh --language`), it is the check that a change of language reaches every
    /// page at once.
    var switchTo: AppLanguage?

    init?(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count else { return nil }
        directory = URL(fileURLWithPath: arguments[i + 1])
        func value(_ flag: String) -> String? {
            guard let j = arguments.firstIndex(of: flag), j + 1 < arguments.count else { return nil }
            return arguments[j + 1]
        }
        if let ids = value("--only") { only = Set(ids.split(separator: ",").map(String.init)) }
        if let s = value("--size") {
            let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        if let s = value("--scale"), let v = Double(s) { scale = CGFloat(v) }
        if let s = value("--switch-to") { switchTo = AppLanguage(rawValue: s) }
        if let s = value("--insets") {
            let parts = s.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 { insets = UIEdgeInsets(top: parts[0], left: parts[1], bottom: parts[2], right: parts[3]) }
        }
    }
}

@MainActor
enum SnapshotHarness {
    /// Every page the app has, in the flow map's order.
    static var pages: [SnapshotPage] {
        WorkspaceSnapshots.pages + LibrarySideSnapshots.pages + DarkroomSnapshots.pages + Layer2Snapshots.pages + FilmEdgeSnapshots.pages + PairEntrySnapshots.pages + PairSnapshots.pages
            + BlackAndWhiteSnapshots.pages
            + DesignGallerySnapshots.pages
            + StripProbeSnapshots.pages
            + LightTableSnapshots.pages
    }

    /// The drawings' own day: 30 September 2026, or 1 October once the card is in.
    static func clock(for scenario: DemoLibrary.Scenario) -> Date {
        scenario == .home || scenario == .empty ? DemoLibrary.date(2026, 9, 30, 12, 0) : DemoLibrary.date(2026, 10, 1, 18, 0)
    }

    static func run(_ request: SnapshotRequest) {
        try? FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        UIView.setAnimationsEnabled(false)
        var index: [[String: String]] = []
        for page in pages where request.only?.contains(page.id) ?? true {
            var size = request.size
            if let tall = page.tall { size.height = max(size.height, tall) }
            let insets = request.insets ?? .zero
            let model = AppServices(scenario: page.scenario, pinnedNow: clock(for: page.scenario), persists: false,
                                 isSnapshot: true, engineSpeed: 50)
            // The window's shape, so the page draws the Mac's column.
            #if DEBUG
            model.window.harnessSize = size
            #endif
            let root = page.view(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .appEnvironment(model)
                .environment(\.displayScale, request.scale)
                .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
                .preferredColorScheme(.dark)
                .transaction { $0.disablesAnimations = true }
            let host = StageHost(rootView: root)
            host.wanted = insets
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.backgroundColor = .black
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // Let `.task` and `.onAppear` run, and layout settle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            let launched = Language.shared.current
            if let to = request.switchTo {
                Language.shared.choose(to)
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            }
            defer { Language.shared.choose(launched) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = request.scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                if !host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                    window.layer.render(in: context.cgContext)
                }
            }
            let drawn = host.view.safeAreaInsets
            if drawn.top != insets.top || drawn.bottom != insets.bottom || drawn.left != insets.left || drawn.right != insets.right {
                print("snapshot \(page.id): drawn with the safe area \(drawn), not the one asked for (\(insets))")
            }
            let url = request.directory.appendingPathComponent("\(page.id).png")
            do {
                try image.pngData()?.write(to: url)
                print("snapshot \(page.id)  \(page.title)  ->  \(url.lastPathComponent)")
            } catch {
                print("snapshot \(page.id) FAILED: \(error)")
            }
            index.append(["id": page.id, "title": page.title])
            window.isHidden = true
            window.rootViewController = nil
        }
        if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted]) {
            try? data.write(to: request.directory.appendingPathComponent("index.json"))
        }
        print("snapshots: \(index.count) pages -> \(request.directory.path)")
    }
}

/// Hosts a page with the requested safe area, compensating for any system insets.
private final class StageHost<Content: View>: UIHostingController<Content> {
    var wanted = UIEdgeInsets.zero { didSet { settle() } }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        settle()
    }

    // A page that ignores the safe area never hears that it changed.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        settle()
    }

    private func settle() {
        guard isViewLoaded else { return }
        let now = view.safeAreaInsets, added = additionalSafeAreaInsets
        let fix = UIEdgeInsets(top: wanted.top - (now.top - added.top), left: wanted.left - (now.left - added.left),
                               bottom: wanted.bottom - (now.bottom - added.bottom),
                               right: wanted.right - (now.right - added.right))
        if fix != added { additionalSafeAreaInsets = fix }
    }
}
