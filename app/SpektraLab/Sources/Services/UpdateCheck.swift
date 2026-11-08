//  UpdateCheck.swift — Check for Updates (自动更新, 2.2.1): is there a newer SpektraLab for the Mac.
//
//  The owner, 2026-11-08: "a check for update system, in the settings, that can check the latest release
//  (mac only), and it can be toggled on / off for checking automatically at start or not"; and "base
//  address should be a variable in case of switching CDNs, not always wired to github releases".
//
//  - **Where it reads**: one small JSON manifest at the address the build put in `Info.plist`
//    (`SPKUpdateFeedURL`, from `gen_project.py --update-feed`; https://spektralab.app/updates/mac.json by
//    default, published with the website). The manifest says where the download is, so the DMG can live
//    on GitHub, a CDN or anywhere else without the app knowing:
//
//        {"version": "2.2.1", "build": "202611090000",
//         "url": "https://…/SpektraLab-2.2.1-universal.dmg",
//         "notes": "https://…/releases/tag/spektralab-v2.2.1",
//         "sha256": "…", "minimum_macos": "15.0"}
//
//  - **Mac only**: the manifest is the Mac's; the Windows and Linux builds publish their own.
//  - **What is sent**: a plain GET of that address, nothing about the person, the Mac or the library.
//  - **Newer** is the version compared number by number (2.10.0 > 2.9.9); the same version with a higher
//    build is newer too. The app never downloads or installs anything itself: it says so and opens the
//    manifest's link.
//  - **At launch** (`AppSettings.checksForUpdates`, on unless turned off in Settings › General): once, a few
//    seconds after the window is up, never for a launch with arguments (a check's, a harness's).

import Foundation
import Observation

@MainActor
@Observable
final class UpdateCheck {
    static let shared = UpdateCheck()

    struct Release: Equatable, Sendable {
        var version: String
        var build: String?
        var url: URL
        var notes: URL?
        var sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case failed(String)
    }

    private(set) var state = State.idle
    /// A newer release found by the launch's own check, for the window to say once.
    var announced: Release?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The manifest's address, as the build wrote it; nil where the build has none.
    nonisolated static var feedURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SPKUpdateFeedURL") as? String,
              !s.isEmpty, !s.contains("$("), let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }

    nonisolated static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    nonisolated static var runningBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Check now. `announce`: a newer release is also put up for the window (the launch's check).
    func check(announce: Bool = false) {
        guard state != .checking else { return }
        guard let feed = Self.feedURL else { state = .failed(L("This build has no address to check for updates.")); return }
        state = .checking
        task = Task { [weak self] in
            let result = await Self.fetch(feed)
            guard let self else { return }
            switch result {
            case .success(let release):
                if Self.isNewer(release, than: Self.runningVersion, build: Self.runningBuild) {
                    state = .available(release)
                    if announce { announced = release }
                } else {
                    state = .upToDate(checkedAt: Date())
                }
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// The launch's check: once, a little after the window is up, and only for a plain launch.
    func checkAtLaunch(enabled: Bool, arguments: [String] = CommandLine.arguments) {
        guard enabled, arguments.count <= 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.check(announce: true)
        }
    }

    // MARK: the manifest

    nonisolated static func fetch(_ feed: URL) async -> Result<Release, Error> {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.status(http.statusCode)
            }
            return .success(try parse(data))
        } catch {
            return .failure(error)
        }
    }

    enum UpdateError: LocalizedError {
        case status(Int)
        case malformed
        var errorDescription: String? {
            switch self {
            case .status(let code): L("The update server answered \(code).")
            case .malformed: L("The update server's answer could not be read.")
            }
        }
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = o["version"] as? String, !version.isEmpty,
              let link = o["url"] as? String, let url = URL(string: link), url.scheme == "https" else {
            throw UpdateError.malformed
        }
        let notes = (o["notes"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return Release(version: version, build: o["build"] as? String, url: url, notes: notes, sha256: o["sha256"] as? String)
    }

    /// Number by number; a missing part is 0. The same version with a higher (numeric) build is newer.
    nonisolated static func isNewer(_ release: Release, than version: String, build: String) -> Bool {
        let a = parts(release.version), b = parts(version)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        guard let rb = release.build.flatMap(Int.init), let ob = Int(build) else { return false }
        return rb > ob
    }

    nonisolated static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
