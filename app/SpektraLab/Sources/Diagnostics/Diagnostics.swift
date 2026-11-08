//  Diagnostics.swift — the log as the app keeps it: who may have it, and sending it.
//
//  The owner, 2026-10-10, for the first build other people use: "a log
//  record system, that asks for user to collect
//  analytical data"; and "in case Cloudflare worker is not available in
//  certain region, a log zip in settings is there".
//
//  So three things, and only the second needs anyone's leave:
//
//  1. **The log is kept on the host**, in every build with a library of its
//     own, whatever was answered: `Application Support/SpektraLab/Logs`, 7
//     days of it (`LogStore`). Nothing has left the host by its being kept.
//  2. **It is sent only on the user's word.** The app asks once, the first
//     time it is opened (`shouldAsk`, an alert over the Library), saying what
//     the log holds and what it never does; Settings › Diagnostics has the
//     switch afterwards, and the page that says it in full. With the word, the
//     log goes to `logs.spektralab.app` under a number made up for this
//     installation (`install`: not the host's, not the person's; a new one
//     if sharing is turned off and on again) — the sessions before this one
//     when the app is opened, this one when it is left.
//  3. **The zip is always there**: *Export Log Zip* hands the same files to
//     the system's share sheet, for wherever the server cannot be reached and
//     for a build that was given no server (`endpoint` nil).
//
//  What the log holds is `LogRecords.swift`'s to say; what it may not hold is
//  `LogStore`'s rule.
//
//  **The sending is compiled only where a build has a server.** 2. is under
//  `SPK_LOG_UPLOAD`, which `gen_project.py` sets for a debug build
//  (`tools/logs_receiver.py` is a stand-in server) and for a release build only where
//  the checkout holds `logs.local` (the address and its key, never in the
//  repository). A release build without it has no shipper, no ask, no switch,
//  no server's name, no key, no installation number. 1. and 3. are every build's. the operating system's own reports
//  (`MetricReports`) stay too: MetricKit hands them to the app on the device,
//  and they go into the kept log and its zip, nowhere else.

import Foundation
import MetricKit
import Observation
import UIKit

/// The log, from anywhere in the app: a record noted here is in the session's
/// file. Nothing where no log is kept (the drawings' own library, the
/// snapshot harness).
enum Log {
    nonisolated(unsafe) private(set) static var store: LogStore?

    /// Set once, at launch, before anything is noted. A kept file set aside unread is told here too
    /// (`KeptFileAside`, which has no log of its own).
    static func open(_ store: LogStore?) {
        self.store = store
        KeptFileAside.report = { message, fields in Log.warn(.library, message, fields) }
    }

    static func note(_ category: LogCategory, _ message: String, _ fields: [String: Any] = [:], level: LogLevel = .info) {
        store?.write(level, category, message, fields)
    }

    static func warn(_ category: LogCategory, _ message: String, _ fields: [String: Any] = [:]) {
        store?.write(.warn, category, message, fields)
    }

    static func error(_ category: LogCategory, _ message: String, _ fields: [String: Any] = [:]) {
        store?.write(.error, category, message, fields)
    }

    /// An error as the log says it: its domain and number, and for one that
    /// is not the system's its own words (scrubbed where they are written).
    static func words(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }
}

/// What this build is.
struct BuildFacts: Equatable, Sendable {
    var version: String
    var build: String
    /// The sources it was made from ("e8c2763"; with a "+" where they had changes not committed).
    var commit: String
    /// "a debug build" or "a release build".
    var configuration: String

    /// "0.1 (7)".
    var text: String { "\(version) (\(build))" }

    static let current: BuildFacts = {
        let info = Bundle.main.infoDictionary
        #if DEBUG
        let configuration = "a debug build"
        #else
        let configuration = "a release build"
        #endif
        return BuildFacts(version: info?["CFBundleShortVersionString"] as? String ?? "?",
                          build: info?["CFBundleVersion"] as? String ?? "?",
                          commit: info?["SPKCommit"] as? String ?? "", configuration: configuration)
    }()
}

@MainActor
@Observable
final class Diagnostics {
    #if SPK_LOG_UPLOAD
    enum Consent: String, Sendable { case unasked = "unasked", shared = "shared", declined = "declined" }

    /// A sending that did not go: when, and why in the log's words.
    struct Trouble: Equatable, Sendable {
        var at: Date
        var why: String
    }

    private(set) var consent: Consent = .unasked
    private(set) var lastSent: Date?
    private(set) var trouble: Trouble?
    #endif
    /// The zip is being made.
    private(set) var isPacking = false

    /// Nil where no log is kept.
    @ObservationIgnored let store: LogStore?
    #if SPK_LOG_UPLOAD
    /// Nil in a build that was given no server: it sends nothing.
    @ObservationIgnored let endpoint: LogEndpoint?
    /// False under a harness or a launch with arguments: the ask is the user's to see, not a check's.
    @ObservationIgnored var asksByItself = true
    #endif
    let build = BuildFacts.current
    /// What the zip's summary says of the app as it stands; the app's model fills it.
    @ObservationIgnored var summary: @MainActor () -> [String: Any] = { [:] }
    /// Run as the app is left, before its last record of the visit: what the
    /// app's model wants said by then (the library, if it is another).
    @ObservationIgnored var beforeLeaving: @MainActor () -> Void = {}

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reports: MetricReports?
    #if SPK_LOG_UPLOAD
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let shipper: LogShipper?
    @ObservationIgnored private var install: String?
    /// The number the log last went under before sharing was turned off: kept
    /// in sight, so that what was sent can be asked to be deleted by it.
    @ObservationIgnored private var before: String?
    @ObservationIgnored private var currentSent: Date?
    @ObservationIgnored private var sending: Task<Void, Never>?

    private enum Key {
        static let consent = "diagnostics.consent"
        static let install = "diagnostics.install"
        static let before = "diagnostics.installBefore"
        static let lastSent = "diagnostics.lastSent"
    }
    #endif

    /// Where the privacy policy is published (`legal/`, served by `site/`):
    /// the Chinese page for the app in Chinese (either script), the English one otherwise.
    /// Japanese is sent to the English page: there is no Japanese policy (2026-10-22).
    static var policyURL: URL { Language.shared.current.privacyPolicyURL }

    #if SPK_LOG_UPLOAD
    /// The least time between two sendings of the session being written as
    /// the app is left: the whole file goes each time, and an app left twenty
    /// times in an hour should not send it twenty times. Between leavings
    /// only (`send`): what is noted after the last one sent stays on the host
    /// until the app is opened again, and goes then with the session whole.
    static let currentEvery: TimeInterval = 300

    /// `folder` nil keeps no log (the drawings' own library, the snapshot
    /// harness); `defaults` nil remembers no answer.
    init(folder: URL?, endpoint: LogEndpoint? = .bundled(), defaults: UserDefaults? = .standard,
         transport: LogShipper.Transport? = nil) {
        self.defaults = defaults
        self.endpoint = endpoint
        store = folder.map { LogStore(folder: $0) }
        shipper = folder.flatMap { folder in
            endpoint.map { LogShipper(folder: folder, endpoint: $0, build: BuildFacts.current.text, transport: transport) }
        }
        consent = defaults?.string(forKey: Key.consent).flatMap(Consent.init(rawValue:)) ?? .unasked
        install = defaults?.string(forKey: Key.install)
        before = defaults?.string(forKey: Key.before)
        let sent = defaults?.double(forKey: Key.lastSent) ?? 0
        lastSent = sent > 0 ? Date(timeIntervalSince1970: sent) : nil
        Log.open(store)
    }

    /// Whether this build can send at all: it keeps a log and was given a server.
    var canSend: Bool { staged ? stagedSends : (store != nil && endpoint != nil) }

    /// The server's name, where this build has one.
    var serverHost: String? { staged ? (stagedSends ? "logs.example.invalid" : nil) : endpoint?.base.host }

    /// For the snapshot harness only: Settings as a build with a server shows
    /// it, in the state given. Nothing is kept and nothing is sent.
    func stageForDemo(_ consent: Consent, lastSent: Date? = nil, trouble: Trouble? = nil, install: String? = nil, before: String? = nil) {
        staged = true
        stagedSends = true
        self.consent = consent
        self.lastSent = lastSent
        self.trouble = trouble
        self.install = install
        self.before = before
    }
    @ObservationIgnored private var stagedSends = false

    /// The app has yet to ask, and may: over the Library, once.
    var shouldAsk: Bool { !staged && canSend && consent == .unasked && asksByItself }
    #else
    /// `folder` nil keeps no log (the drawings' own library, the snapshot harness).
    init(folder: URL?) {
        store = folder.map { LogStore(folder: $0) }
        Log.open(store)
    }

    /// A build with no server compiled in sends nothing: it has no way to.
    var canSend: Bool { false }
    #endif

    /// Whether a log is kept here at all.
    var keepsLog: Bool { staged || store != nil }

    /// For the snapshot harness only: Settings as a build that keeps a log
    /// and sends nothing shows it — a release build's without a server. Nothing is kept.
    func stageKeptForDemo() {
        staged = true
        #if SPK_LOG_UPLOAD
        stagedSends = false
        #endif
    }
    @ObservationIgnored private var staged = false

    #if SPK_LOG_UPLOAD

    /// The number this installation's logs go under, while sharing is on.
    var installText: String? { install }

    /// The number they went under until sharing was last turned off. It stays
    /// shown (the owner, 2026-10-10: "keep the installation number visible
    /// after sharing is turned off"): turning sharing off deletes nothing
    /// that was sent, and without the number nobody can say which logs to
    /// delete. A later yes makes a new number, and this one stays beside it.
    var numberBefore: String? { before }
    #endif

    // MARK: the session's own course

    /// The app's course from here on, noted: in front, left, ended; memory
    /// warnings; the operating system's own reports. And what the host kept from before is
    /// sent, if it may be.
    func begin() {
        guard store != nil, observers.isEmpty else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ run: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { run() }
            })
        }
        on(UIApplication.didBecomeActiveNotification) { Log.note(.app, "active") }
        on(UIApplication.willResignActiveNotification) { Log.note(.app, "inactive") }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.left() }
        on(UIApplication.willTerminateNotification) { [weak self] in
            Log.note(.app, "terminate")
            self?.store?.flush()
        }
        on(UIApplication.didReceiveMemoryWarningNotification) {
            let reading = MemoryProbe.read()
            Log.warn(.app, "memory warning", ["footprint_mb": reading.footprint.megabytes, "allowance_mb": reading.appAvailable.megabytes,
                                              "phone_free_mb": reading.free.megabytes])
        }
        on(ProcessInfo.thermalStateDidChangeNotification) {
            Log.note(.app, "thermal", ["state": Self.thermal])
        }
        let reports = MetricReports()
        MXMetricManager.shared.add(reports)
        self.reports = reports
        #if SPK_LOG_UPLOAD
        // A moment after launch, so it competes with nothing the launch does.
        sending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.send(leaving: false)
        }
        #endif
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// The app has been left: the file is whole on disk, and it is sent while
    /// the operating system still lets the app run.
    private func left() {
        beforeLeaving()
        Log.note(.app, "background")
        store?.flush()
        #if SPK_LOG_UPLOAD
        guard consent == .shared, canSend else { return }
        let hold = BackgroundHold()
        hold.id = UIApplication.shared.beginBackgroundTask(withName: "log") {
            MainActor.assumeIsolated { hold.end() }
        }
        Task { [weak self] in
            await self?.send(leaving: true)
            hold.end()
        }
        #endif
    }

    #if SPK_LOG_UPLOAD

    /// the operating system's leave to go on for a moment after the app is left, given back once.
    @MainActor
    private final class BackgroundHold {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // MARK: the user's word

    /// The answer to the ask, or Settings' switch.
    func answer(share: Bool) {
        consent = share ? .shared : .declined
        defaults?.set(consent.rawValue, forKey: Key.consent)
        Log.note(.upload, "consent", ["shared": share])
        if share {
            if install == nil {
                install = UUID().uuidString.lowercased()
                defaults?.set(install, forKey: Key.install)
            }
            // What the host has kept goes now, this session with it.
            Task { [weak self] in await self?.send(leaving: true, now: true) }
        } else {
            // A later yes is a new number. It is not a clean break: each session's file names the
            // one before it, and a session still being written goes again under the new number.
            // The number it went under is kept, and shown: it is what a request to delete names.
            if let install {
                before = install
                defaults?.set(install, forKey: Key.before)
            }
            install = nil
            defaults?.removeObject(forKey: Key.install)
            trouble = nil
        }
    }

    #if DEBUG
    /// A debug build's launch with `--ask-diagnostics`: the answer is
    /// forgotten, so the ask is there to be seen again.
    func forgetAnswer() {
        consent = .unasked
        install = nil
        before = nil
        defaults?.removeObject(forKey: Key.consent)
        defaults?.removeObject(forKey: Key.install)
        defaults?.removeObject(forKey: Key.before)
    }
    #endif

    // MARK: sending

    /// Send what is due. `leaving` sends the session being written too, though
    /// no more often than `currentEvery` unless it is asked for `now`.
    ///
    /// **The five minutes run from one leaving to the next, and a sending
    /// asked for `now` — the Share answer's — is not a leaving.** Until
    /// 2026-10-12 it started the clock: the session went at the answer, a
    /// second or two into a first visit, and whoever then left within five
    /// minutes and did not come back had sent nothing of what they did. That
    /// was 12 of the 45 hosts that shared a log on the beta's first day. The
    /// privacy policy's sentence is of leavings ("the current one when you
    /// leave it, at most every five minutes") and still holds; the sending at
    /// the answer is its own line there ("at once, everything the host still
    /// holds").
    func send(leaving: Bool, now: Bool = false) async {
        guard consent == .shared, let store, let shipper, let install else { return }
        var withCurrent = leaving
        if withCurrent, !now, let last = currentSent, Date().timeIntervalSince(last) < Self.currentEvery { withCurrent = false }
        store.flush()
        let outcome = await shipper.ship(install: install, current: store.current, includingCurrent: withCurrent)
        switch outcome {
        case .sent(let files, let bytes):
            trouble = nil
            if withCurrent, !now { currentSent = Date() }
            guard files > 0 else { return }
            lastSent = Date()
            defaults?.set(lastSent?.timeIntervalSince1970, forKey: Key.lastSent)
            Log.note(.upload, "sent", ["files": files, "bytes": bytes])
        case .refused(let status):
            trouble = Trouble(at: Date(), why: "the server refused this build (\(status))")
            Log.warn(.upload, "refused", ["status": status])
        case .later(let why):
            trouble = Trouble(at: Date(), why: why)
            Log.warn(.upload, "not sent", ["why": why])
        }
    }
    #endif

    // MARK: the zip

    /// The log as one zip in the app's temporary files, for the share sheet.
    /// Nil where no log is kept, or it could not be written.
    func makeZip() async -> URL? {
        guard let store, !isPacking else { return nil }
        isPacking = true
        defer { isPacking = false }
        Log.note(.upload, "zip")
        store.flush()
        let summary = summaryData()
        let folder = store.folder
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("LogZip", isDirectory: true)
        let destination = place.appendingPathComponent(LogBundle.fileName(Date()))
        return await Task.detached(priority: .userInitiated) {
            // The zip before this one: it has been handed on, or was not wanted.
            try? FileManager.default.removeItem(at: place)
            return try? LogBundle.write(to: destination, logs: folder, summary: summary)
        }.value
    }

    /// `summary.json`: the app as it stands, written to be read by a person.
    private func summaryData() -> Data {
        var all = summary()
        all["made"] = Date()
        #if SPK_LOG_UPLOAD
        all["sharing"] = consent.rawValue
        all["install"] = install
        all["install_before"] = before
        all["server"] = endpoint?.base.host ?? "none in this build"
        all["last_sent"] = lastSent
        if let trouble { all["last_trouble"] = ["at": trouble.at, "why": trouble.why] as [String: Any] }
        #endif
        // Through the log's own writer (no NaN, nothing it would not write), then laid out.
        let line = LogJSON.write(all) ?? "{}"
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return Data(line.utf8) }
        return pretty
    }
}

#if SPK_LOG_UPLOAD
extension LogEndpoint {
    /// The build's own server — or, in a debug build, the one its launch
    /// names (`--logs-endpoint <url> <key>`): a check's stand-in on this Mac
    /// (`tools/logs_receiver.py`).
    static func launch(_ arguments: [String] = CommandLine.arguments) -> LogEndpoint? {
        #if DEBUG
        if let i = arguments.firstIndex(of: "--logs-endpoint"), i + 2 < arguments.count, let url = URL(string: arguments[i + 1]) {
            return LogEndpoint(base: url, key: arguments[i + 2])
        }
        #endif
        return bundled()
    }
}
#endif

extension ImportService {
    /// Where the log is kept: beside the library, and no part of it.
    nonisolated static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
}

/// the operating system's own reports for this app, as they are handed over: once a day what it
/// measured (launches, hangs, memory, how often and why the app was ended),
/// and after a crash or a hang what it caught. Each is one record.
private final class MetricReports: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { note("metrics", payload.jsonRepresentation(), level: .info) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { note("diagnostics", payload.jsonRepresentation(), level: .warn) }
    }

    private func note(_ what: String, _ data: Data, level: LogLevel) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            Log.note(.system, what, ["bytes": data.count], level: level)
            return
        }
        Log.note(.system, what, ["payload": object], level: level)
    }
}
