//  Diagnostics.swift — the settings model, and the app's two entry points.
//
//  RFC-016 §6 is the Settings page's diagnostics column, and this is the model
//  that column binds to: log level, per-node GPU timings, the three retention
//  numbers, the log destination, and the live memory readout. The page itself
//  is somebody else's file — everything it needs to draw, and everything it
//  needs to call, is here.
//
//  The two lines the app delegate needs:
//
//      Diagnostics.shared.start()    // applicationDidFinishLaunching
//      Diagnostics.shared.finish()   // applicationWillTerminate
//
//  `start()` writes the launch record, cleans the log directory (§4) and opens
//  this session's file; `finish()` writes the session-end record the next
//  launch looks for (§1.7) and closes it. Both are cheap and neither blocks on
//  anything: the cleaning and the file work happen on the log's own queue.
//
//  §11.5 is the other half of this file — the app must be *auditable and
//  traceable, and must not crash silently or blow up memory without telling
//  the user*. `projection(pixels:)` is the memory half: a forecast of what a
//  frame will cost, measured against what is free, with a warning the user can
//  override rather than a render that silently starts swapping.

import AppKit
import Foundation
import Metal
import Observation

@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics(sampler: MemorySampler(arena: .shared))

    // MARK: - the pieces

    /// The app's log. Exposed rather than hidden: `Session` and `EngineClient`
    /// write to it directly, and a page that wants to show the tail of a
    /// session reads it through `records()`.
    let log: Log
    let sampler: MemorySampler
    /// The accounting arena beside the sampler; neither performs kernel reads.
    var arena: MemoryArena { sampler.arena }

    private let defaults: UserDefaults

    // MARK: - settings (§6)

    /// Normal / Detailed / Verbose.
    ///
    /// Detailed and Verbose are **persisted but expire**: the stored value is
    /// written so a crash mid-session still leaves a trace of what the user had
    /// asked for, and `init` puts it straight back to Normal, so nobody runs at
    /// `trace` forever because of one afternoon's hunt.
    var level: LogLevelSetting {
        didSet {
            guard level != oldValue else { return }
            defaults.set(level.rawValue, forKey: Keys.level)
            log.level = level.level
        }
    }

    /// Per-node GPU timings (§5.2). Off by default and it must stay off by
    /// default: `Progress.detailed` makes every node flush before its timer
    /// stops (`pipeline.hpp`), which gives up the batching the whole engine
    /// depends on. The note under the checkbox says so in the same sentence.
    var perNodeGPUTimings: Bool {
        didSet {
            guard perNodeGPUTimings != oldValue else { return }
            defaults.set(perNodeGPUTimings, forKey: Keys.perNodeGPUTimings)
            applyPerNodeTimings()
            log.info(.engine, "per-node GPU timings \(perNodeGPUTimings ? "on" : "off")")
        }
    }

    // The four numbers below are **computed properties over private stored
    // ones**, and that is not style. `@Observable` rewrites a stored property
    // into a computed one, and the compiler's rule that assigning to a
    // property inside its own `didSet` does not re-enter the observer does
    // **not** survive that rewriting. A clamp written the obvious way —
    //
    //     var days: Int { didSet { days = days.clamped(to: 0...365) } }
    //
    // — recurses until the stack runs out: measured 2026-09-12, it took the
    // test process down with SIGSEGV inside Swift's metadata cache rather than
    // failing an assertion, and it was one Settings-page edit away from doing
    // the same to the app. The clamp belongs in the setter, and the setter
    // writes a *different* property, so there is nothing to re-enter.
    //
    // (`Session.comparePosition` self-assigns the same way and is fine, because
    // its guard makes the second pass a no-op. The rule of thumb: an observer
    // that writes to itself must be able to reach a fixed point.)

    var retentionDays: Int {
        get { storedRetentionDays }
        set {
            let clamped = newValue.clamped(to: 0...365)
            guard clamped != storedRetentionDays else { return }
            storedRetentionDays = clamped
            defaults.set(clamped, forKey: Keys.retentionDays)
        }
    }
    private var storedRetentionDays: Int

    var retentionMegabytes: Int {
        get { storedRetentionMegabytes }
        set {
            let clamped = newValue.clamped(to: 1...100_000)
            guard clamped != storedRetentionMegabytes else { return }
            storedRetentionMegabytes = clamped
            defaults.set(clamped, forKey: Keys.retentionMegabytes)
        }
    }
    private var storedRetentionMegabytes: Int

    var retentionFiles: Int {
        get { storedRetentionFiles }
        set {
            let clamped = newValue.clamped(to: 1...10_000)
            guard clamped != storedRetentionFiles else { return }
            storedRetentionFiles = clamped
            defaults.set(clamped, forKey: Keys.retentionFiles)
        }
    }
    private var storedRetentionFiles: Int

    /// How much memory the app leaves for everything else (§3's "memory
    /// reserve", §11.5's "the Settings reserve").
    ///
    /// It is what the projection is measured against, and it is **read on every
    /// forecast** — a persisted number nothing consulted would be the
    /// guard-that-cannot-fire shape with a settings row on top. 0 means the
    /// forecast is compared against the free pool alone, which is the right
    /// answer for a machine that is doing nothing else and the wrong one for
    /// every other machine.
    var memoryReserveMegabytes: Int {
        get { storedMemoryReserveMegabytes }
        set {
            let clamped = newValue.clamped(to: Diagnostics.memoryReserveRange)
            guard clamped != storedMemoryReserveMegabytes else { return }
            storedMemoryReserveMegabytes = clamped
            defaults.set(clamped, forKey: Keys.memoryReserveMegabytes)
            applyMemoryLimits()
        }
    }
    private var storedMemoryReserveMegabytes: Int

    /// 0 … 32 GB. The floor is "reserve nothing" rather than a small positive
    /// number: a user who wants the forecast to ignore headroom is asking a
    /// coherent question, and the page can say what it costs. The ceiling is
    /// past any Mac this app runs on, so a typo cannot silently disable the
    /// warning.
    nonisolated static let memoryReserveRange = 0...32_768
    nonisolated static let defaultMemoryReserveMB = 2_000

    /// The caption under the control, in the same idiom as the other two.
    nonisolated static let memoryReserveNote =
        "Memory SpektraLab leaves free for everything else. A frame whose forecast peak does not fit "
        + "under it gets a warning you can dismiss — never a refusal. The override below suppresses "
        + "the warning, not eviction."

    /// How much memory SpektraLab may hold in its caches. 0 is the explicit
    /// Unlimited state: finite values are clamped to the published range, while
    /// 0 means the cap is not enforced.
    var memoryCapMegabytes: Int {
        get { storedMemoryCapMegabytes }
        set {
            let clamped: Int
            if newValue == Diagnostics.memoryCapUnlimited {
                clamped = newValue
            } else {
                clamped = newValue.clamped(to: Diagnostics.memoryCapRange)
            }
            guard clamped != storedMemoryCapMegabytes else { return }
            storedMemoryCapMegabytes = clamped
            defaults.set(clamped, forKey: Keys.memoryCapMegabytes)
            applyMemoryLimits()
        }
    }
    private var storedMemoryCapMegabytes: Int

    var memoryCapIsUnlimited: Bool {
        get { storedMemoryCapMegabytes == Diagnostics.memoryCapUnlimited }
        set {
            if newValue {
                memoryCapMegabytes = Diagnostics.memoryCapUnlimited
            } else if memoryCapIsUnlimited {
                memoryCapMegabytes = Diagnostics.defaultMemoryCapMB
            }
        }
    }

    /// 2 GB … 128 GB, plus an explicit Unlimited state. The cap bounds what the
    /// arena may keep in evictable caches; pinned work is accounted but is not
    /// eligible for eviction.
    nonisolated static let memoryCapRange = 2_048...131_072
    nonisolated static let memoryCapUnlimited = 0
    nonisolated static var defaultMemoryCapMB: Int {
        let physicalRAMMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000
        return min(8_192, Int(0.4 * physicalRAMMB))
    }

    /// The caption under the cap control. The first sentence says which
    /// holdings the number actually governs; the rest separates the two
    /// independent budgets so the reserve cannot be read as a cap.
    nonisolated static let memoryCapNote =
        "How much SpektraLab may hold in caches and scratch buffers. The frame you are looking at is "
        + "never evicted, whatever this says. Free memory is set by the other applications on the "
        + "machine; this is the part SpektraLab decides."

    /// How much disk the shared decode/print cache may hold (`DiskCacheStore`).
    ///
    /// It existed before this setting did — as a constant 16 GB inside the
    /// store, which nothing displayed, nothing could change, and no record
    /// mentioned. That is the "unmanaged" state RFC-020 §8 names when it says
    /// the disk cache's *layer* is a real question deferred to another RFC:
    /// this row is not that question. It is the budget, and RFC-021 needs a
    /// budget to exist before it can choose anything against one.
    ///
    /// Unlike the working-set cap there is deliberately **no Unlimited state**.
    /// An unbounded on-disk cache is the condition this row was added to end.
    var diskCacheCapMegabytes: Int {
        get { storedDiskCacheCapMegabytes }
        set {
            let clamped = newValue.clamped(to: Diagnostics.diskCacheCapRange)
            guard clamped != storedDiskCacheCapMegabytes else { return }
            storedDiskCacheCapMegabytes = clamped
            defaults.set(clamped, forKey: Keys.diskCacheCapMegabytes)
            onDiskCacheCapChanged?(diskCacheCapBytes)
        }
    }
    private var storedDiskCacheCapMegabytes: Int

    var diskCacheCapBytes: UInt64 { UInt64(storedDiskCacheCapMegabytes) * 1_000_000 }

    /// Set by `Session`, which owns the store. `Diagnostics` holds the setting
    /// and not the cache, for the same reason it holds the memory cap and not
    /// the arena: one place the value lives, one place it is applied.
    var onDiskCacheCapChanged: ((UInt64) -> Void)?

    /// 1 GB … 512 GB, stored in MB to match every other size on this page and
    /// in the session record. The floor is not zero: zero would mean "cache
    /// nothing", which is a different feature — it would make every reopen pay
    /// a full decode — and this row is a budget, not a switch. The ceiling is
    /// past any realistic library and exists only so a typo cannot re-create
    /// the unbounded state this setting was added to end.
    nonisolated static let diskCacheCapRange = 1_000...512_000
    /// The page shows and steps whole gigabytes; the stored unit stays MB.
    nonisolated static let diskCacheCapGigabyteRange =
        (diskCacheCapRange.lowerBound / 1_000)...(diskCacheCapRange.upperBound / 1_000)

    /// 8 GB, against the 16 GB the store used to assume. Halving it is the
    /// point: the old number was chosen by nobody, and a decode cache that can
    /// quietly reach 16 GB on a 256 GB laptop is the complaint this answers.
    nonisolated static let defaultDiskCacheCapMB = 8_000

    /// The caption under the control. It says what is cached and what losing
    /// it costs, because "clear the cache" is only a safe-sounding button if
    /// the page says what it throws away.
    nonisolated static let diskCacheCapNote =
        "Disk SpektraLab may use for decoded frames and finished prints, so reopening a photo does not "
        + "decode it again. Nothing here is your work — every entry can be remade from the original "
        + "file, so the only cost of emptying it is the wait the next time you open those frames. "
        + "Least-valuable entries are evicted first, by how often each is used against what it cost "
        + "to make."

    /// Where sessions are written (§11.4). Default `~/Library/Logs/SpektraLab/`.
    var logDirectory: URL {
        didSet {
            guard logDirectory != oldValue else { return }
            defaults.set(logDirectory.path, forKey: Keys.logDirectory)
        }
    }

    /// Whether the diagnostic bundle carries the user's file names (§11.3).
    var includeFileNamesInBundle: Bool {
        didSet {
            guard includeFileNamesInBundle != oldValue else { return }
            defaults.set(includeFileNamesInBundle, forKey: Keys.includeFileNames)
        }
    }

    /// "The user has already said yes to a frame that does not fit." Set by the
    /// warning's own button (§11.5); it suppresses the warning for the rest of
    /// the session, which is what an override is.
    var allowOverReserve: Bool {
        didSet {
            guard allowOverReserve != oldValue else { return }
            defaults.set(allowOverReserve, forKey: Keys.allowOverReserve)
            log.info(.memory, "memory warning override \(allowOverReserve ? "granted" : "cleared")")
        }
    }

    // MARK: - what the page shows but does not set

    /// The three limits as one value, for the cleaner.
    var retention: LogRetention {
        LogRetention(days: retentionDays,
                     maxBytes: retentionMegabytes * 1_000_000,
                     maxFiles: retentionFiles)
    }

    /// The last sample the sampler took. **Reading this does not take one**
    /// (§8.5): the log's records and this readout cite the same `seq`, so the
    /// page cannot drift from the record, and a test can prove it.
    var memory: MemorySample? { sampler.current }

    /// The latest signed arena/footprint gap, or nil before the first sample.
    var arenaFootprintGapMB: Double? {
        memory.map { $0.arenaFootprintGapMB(arenaBytes: arena.totalBytes) }
    }

    var currentLogFile: URL? { log.sessionFile }

    /// A failure the page must show rather than hide: a directory that has been
    /// moved, made read-only, or filled (§4). Nil means the last attempt was
    /// clean.
    private(set) var cleanupFailure: String?

    /// The file sink's own error — a disk that filled, a folder the app cannot
    /// write to. The ring still has the records; the page says so.
    var writeFailure: String? { log.fileError }

    /// The last user-facing error, kept for the bundle (§7).
    private(set) var lastError: String?
    /// The engine's `capabilities` block as the engine wrote it, for the
    /// bundle's `capabilities.json`.
    private(set) var capabilitiesJSON: String?
    private(set) var engineVersion: String?
    /// The previous session's file, if the launch found one that did not end
    /// with a session-end record (§1.7). The page can say so; the log already
    /// has a `warn` record about it.
    private(set) var previousSession: PreviousSessionReport?
    /// True once the launch's scan of the previous session has finished —
    /// whether or not it found anything. Nil-report is also an answer.
    private(set) var previousSessionChecked = false

    // MARK: - init

    init(defaults: UserDefaults = .standard, log: Log = .shared, sampler: MemorySampler? = nil) {
        self.defaults = defaults
        self.log = log
        self.sampler = sampler ?? MemorySampler(log: log)

        // §6: Detailed and Verbose revert to Normal on the next launch, so the
        // stored value is read and then written back as Normal. It is stored at
        // all — rather than dropped — so a crash mid-session still leaves the
        // session file it produced traceable to the level it was captured at.
        let stored = defaults.string(forKey: Keys.level).flatMap(LogLevelSetting.init(rawValue:))
        level = .normal
        if stored != nil, stored != .normal {
            defaults.set(LogLevelSetting.normal.rawValue, forKey: Keys.level)
        }
        perNodeGPUTimings = defaults.bool(forKey: Keys.perNodeGPUTimings)
        storedRetentionDays = ((defaults.object(forKey: Keys.retentionDays) as? Int)
            ?? LogRetention.default.days).clamped(to: 0...365)
        storedRetentionMegabytes = ((defaults.object(forKey: Keys.retentionMegabytes) as? Int)
            ?? 100).clamped(to: 1...100_000)
        storedRetentionFiles = ((defaults.object(forKey: Keys.retentionFiles) as? Int)
            ?? LogRetention.default.maxFiles).clamped(to: 1...10_000)
        storedMemoryReserveMegabytes = ((defaults.object(forKey: Keys.memoryReserveMegabytes) as? Int)
            ?? Diagnostics.defaultMemoryReserveMB).clamped(to: Diagnostics.memoryReserveRange)
        let storedCap = (defaults.object(forKey: Keys.memoryCapMegabytes) as? Int)
            ?? Diagnostics.defaultMemoryCapMB
        storedMemoryCapMegabytes = storedCap == Diagnostics.memoryCapUnlimited
            ? storedCap : storedCap.clamped(to: Diagnostics.memoryCapRange)
        storedDiskCacheCapMegabytes = ((defaults.object(forKey: Keys.diskCacheCapMegabytes) as? Int)
            ?? Diagnostics.defaultDiskCacheCapMB).clamped(to: Diagnostics.diskCacheCapRange)
        logDirectory = defaults.string(forKey: Keys.logDirectory)
            .map { URL(fileURLWithPath: $0) } ?? Diagnostics.defaultLogDirectory
        includeFileNamesInBundle = defaults.object(forKey: Keys.includeFileNames) as? Bool ?? true
        allowOverReserve = defaults.bool(forKey: Keys.allowOverReserve)
        applyMemoryLimits()
    }

    /// `~/Library/Logs/SpektraLab/` (§11.4). Created by `start()`, not here: a
    /// model built in a test must not make a directory in the user's home.
    nonisolated static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/SpektraLab")
    }

    private enum Keys {
        static let level = "diag.level"
        static let perNodeGPUTimings = "diag.perNodeGPUTimings"
        static let retentionDays = "diag.retentionDays"
        static let retentionMegabytes = "diag.retentionMegabytes"
        static let retentionFiles = "diag.retentionFiles"
        static let logDirectory = "diag.logDirectory"
        static let memoryReserveMegabytes = "diag.memoryReserveMB"
        static let memoryCapMegabytes = "diag.memoryCapMB"
        static let diskCacheCapMegabytes = "diag.diskCacheCapMB"
        static let includeFileNames = "diag.includeFileNamesInBundle"
        static let allowOverReserve = "diag.allowOverReserve"
    }

    // MARK: - the app's two lines

    /// Launch: clean, open this session's file, and write down what the app is
    /// running as (§1.1, §1.8).
    func start() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        applyPerNodeTimings()
        previousSession = nil
        previousSessionChecked = false
        log.startSession(destination: logDirectory, retention: retention, level: level.level,
                         onPreviousSession: { [weak self] report in
            // On the log's queue, off the main thread: the scan is I/O, and
            // this is only a hop to say what it found.
            Task { @MainActor in
                guard let self else { return }
                self.previousSession = report
                self.previousSessionChecked = true
            }
        })
        log.info(.app, "launch", launchFields())
        sampler.sample("launch")
    }

    /// Clean exit: the record whose *absence* is the finding (§1.7).
    func finish() {
        sampler.sample("exit")
        log.info(.app, "exit", [
            .init("marker", "session_end"),
            .init("uptime_s", log.sessionStartedAt.map { Date().timeIntervalSince($0) } ?? -1),
            .init("peak_mb", Double(sampler.peak) / 1_000_000),
        ])
        log.flushNow()
        log.endSession()
    }

    /// What the app is, and what it will render with. One record, at launch,
    /// because "which engine am I actually running?" cost a day once
    /// (`HANDOFF-GPU-WIRING` §0).
    private func launchFields() -> [LogField] {
        var fields: [LogField] = []
        let info = Diagnostics.bundleInfo
        fields.append(.init("app", info.version))
        fields.append(.init("build", info.build))
        fields.append(.init("os", ProcessInfo.processInfo.operatingSystemVersionString))
        fields.append(.init("model", Diagnostics.sysctlString("hw.model") ?? "unknown"))
        fields.append(.init("ram_gb", Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000))
        fields.append(.init("pid", Int(ProcessInfo.processInfo.processIdentifier)))
        for (key, value) in Diagnostics.machineBlock() { fields.append(.init(key, value)) }
        // The settings that change what a render costs. The preview resolution
        // is the session's own (Session.previewEdgeKey): read from defaults
        // because the model is built before the session is.
        let previewEdge = (UserDefaults.standard.object(forKey: Session.previewEdgeKey) as? Int)
            ?? Session.defaultPreviewEdge
        fields.append(.init("preview_edge", previewEdge))
        fields.append(.init("memory_reserve_mb", memoryReserveMegabytes))
        fields.append(.init("memory_cap_mb", memoryCapIsUnlimited ? "unlimited" : String(memoryCapMegabytes)))
        fields.append(.init("disk_cache_cap_mb", diskCacheCapMegabytes))
        fields.append(.init("log_level", level.rawValue))
        fields.append(.init("log_file", log.sessionFile?.lastPathComponent ?? "none"))
        return fields
    }

    // MARK: - the machine, in one block (§1.8)

    nonisolated static func machineBlock() -> [String: String] {
        var out: [String: String] = [:]
        if let device = MTLCreateSystemDefaultDevice() {
            out["gpu"] = device.name
            out["gpu_family"] = highestFamily(device)
            out["gpu_working_set_gb"] = String(format: "%.1f",
                                               Double(device.recommendedMaxWorkingSetSize) / 1_000_000_000)
        } else {
            out["gpu"] = "none"
        }
        return out
    }

    private nonisolated static func highestFamily(_ device: MTLDevice) -> String {
        let families: [(String, MTLGPUFamily)] = [
            ("apple9", .apple9), ("apple8", .apple8), ("apple7", .apple7), ("metal3", .metal3),
        ]
        return families.first { device.supportsFamily($0.1) }?.0 ?? "unknown"
    }

    private nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private final class BundleToken {}
    nonisolated static var bundle: Bundle { Bundle(for: BundleToken.self) }

    nonisolated static var bundleInfo: (version: String, build: String) {
        let info = bundle.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "unknown",
                info?["CFBundleVersion"] as? String ?? "unknown")
    }

    // MARK: - the memory projection (§11.5)

    /// How much memory this app has been measured to need per pixel.
    ///
    /// From the RFC's own points (§1.5): 7.6 GB at the 45.44 MP Z7 II frame is
    /// **167 bytes a pixel**, 9.7 GB at 60.2 MP is 161, and the 151 MP
    /// measurement comes in at 75 — the pipeline's peak is not linear in
    /// pixels, and it is not this app's to re-derive. The constant errs high on
    /// purpose: a forecast that under-predicts is the failure this exists to
    /// catch, and the frames where it over-predicts (past the engine's 60 MP
    /// cap) are frames the app refuses anyway.
    nonisolated static let forecastBytesPerPixel: Double = 167


    struct MemoryProjection: Sendable, Equatable {
        var pixels: Int
        var forecastBytes: UInt64
        var freeBytes: UInt64
        var reserveBytes: UInt64
        /// False means "this will probably not fit" — and that is a warning,
        /// never a refusal (§11.5: no chunking, no strip rendering, and no
        /// silent swap storm either).
        var fits: Bool
        var message: String?

        var forecastMB: Double { Double(forecastBytes) / 1_000_000 }
        var freeMB: Double { Double(freeBytes) / 1_000_000 }
        var reserveMB: Double { Double(reserveBytes) / 1_000_000 }
    }

    /// Forecast a frame's peak from its pixel count, and say whether it fits.
    ///
    /// The free pool is read live rather than from the last sample: this is a
    /// decision about right now, not a readout of the last boundary.
    func projection(pixels: Int) -> MemoryProjection {
        let forecast = UInt64(Double(max(0, pixels)) * Diagnostics.forecastBytesPerPixel)
        let free = sampler.freeBytes
        let reserve = UInt64(memoryReserveMegabytes) * 1_000_000
        let fits = allowOverReserve || forecast + reserve <= free
        return MemoryProjection(pixels: pixels, forecastBytes: forecast, freeBytes: free,
                                reserveBytes: reserve, fits: fits,
                                message: fits ? nil : format(forecastMB: Double(forecast) / 1_000_000,
                                                             freeMB: Double(free) / 1_000_000,
                                                             megapixels: Double(pixels) / 1_000_000))
    }

    private func format(forecastMB: Double, freeMB: Double, megapixels: Double) -> String {
        String(format: "This %.0f MP frame is expected to need about %.1f GB of memory, and this Mac "
                       + "has about %.1f GB free. Rendering it may start swapping; close other "
                       + "applications, crop the frame smaller, or proceed anyway.",
               megapixels, forecastMB / 1000, freeMB / 1000)
    }

    /// A forecast for the frame on screen, recorded either way (§11.5: "and a
    /// log record either way"). Returns the projection so the caller can put
    /// the message in the window.
    @discardableResult
    func noteProjection(pixels: Int, operation: String, frame: String?) -> MemoryProjection {
        let projection = projection(pixels: pixels)
        var fields: [LogField] = [
            .init("op", operation),
            .init("px", pixels),
            .init("forecast_mb", projection.forecastMB),
            .init("free_mb", projection.freeMB),
            .init("reserve_mb", projection.reserveMB),
            .init("fits", projection.fits),
        ]
        if let frame { fields.append(.init("frame", frame)) }
        if projection.fits {
            log.debug(.memory, "projected peak fits", fields)
        } else {
            log.warn(.memory, "projected peak does not fit", fields)
        }
        return projection
    }

    // MARK: - from the rest of the app

    /// The engine told us what it is (§1.1). Kept for the bundle, and the log
    /// record itself is written by `Session` where the rest of the block is
    /// known.
    func noteCapabilities(json: String?, version: String?) {
        capabilitiesJSON = json
        engineVersion = version
    }

    /// The last thing the user was told went wrong, for the bundle (§7).
    func noteError(_ userFacing: String) { lastError = userFacing }

    // MARK: - the page's actions (§6)

    /// Take a sample for the live readout. Records at `debug`: at Normal this
    /// reaches the ring and not the file, which is what a once-a-second readout
    /// should cost.
    func refreshMemory() {
        sampler.sample("readout", level: .debug)
    }

    /// "Clear logs now": everything except the file this session is writing.
    func clearLogsNow() {
        log.clearLogs { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.cleanupFailure = outcome.failure
                if let last = outcome.deleted.last {
                    self.log.info(.app, "logs cleared", [
                        .init("deleted", outcome.deleted.count),
                        .init("last", last),
                    ])
                }
            }
        }
    }

    func revealLogsInFinder() {
        let target = log.sessionFile ?? logDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Save the diagnostic bundle (§7). Off the main actor: it reads up to five
    /// log files and writes an archive, which is not work for a UI thread.
    @discardableResult
    func saveDiagnosticBundle(to destination: URL) async throws -> URL {
        let inputs = DiagnosticBundle.Inputs(
            logDirectory: logDirectory,
            appVersion: Diagnostics.bundleInfo.version,
            buildNumber: Diagnostics.bundleInfo.build,
            engineVersion: engineVersion,
            capabilitiesJSON: capabilitiesJSON,
            lastError: lastError,
            machine: Diagnostics.machineBlock(),
            settings: settingsSnapshot(),
            previousSession: previousSession)
        let includeNames = includeFileNamesInBundle
        log.info(.app, "saving a diagnostic bundle", [
            .init("destination", destination.path), .init("file_names", includeNames),
        ])
        let url = try await Task.detached(priority: .userInitiated) {
            try DiagnosticBundle.assemble(to: destination, includeFileNames: includeNames, inputs: inputs)
        }.value
        log.info(.app, "diagnostic bundle saved", [.init("path", url.path)])
        return url
    }

    /// Everything the app will render with, as plain strings — the bundle's
    /// `settings` block. User-defaults values that are not the app's own
    /// (the UI's) are left out: §5.6, a record nobody has a question about.
    private func settingsSnapshot() -> [String: String] {
        [
            "log_level": level.rawValue,
            "per_node_gpu_timings": perNodeGPUTimings ? "on" : "off",
            "retention_days": String(retentionDays),
            "retention_mb": String(retentionMegabytes),
            "retention_files": String(retentionFiles),
            "log_directory": logDirectory.path,
            "bundle_includes_file_names": includeFileNamesInBundle ? "on" : "off",
            "memory_reserve_mb": String(memoryReserveMegabytes),
            "memory_cap_mb": memoryCapIsUnlimited ? "unlimited" : String(memoryCapMegabytes),
            "disk_cache_cap_mb": String(diskCacheCapMegabytes),
            "preview_edge": String((UserDefaults.standard.object(forKey: Session.previewEdgeKey) as? Int)
                                   ?? Session.defaultPreviewEdge),
        ]
    }

    private var memoryCapBytes: UInt64 {
        memoryCapIsUnlimited ? .max : UInt64(memoryCapMegabytes) * 1_000_000
    }

    /// Settings changes take effect at the next sample. Sampling remains the
    /// only place that reads `phys_footprint`/free memory.
    private func applyMemoryLimits() {
        sampler.setLimits(reserveBytes: UInt64(memoryReserveMegabytes) * 1_000_000,
                          capBytes: memoryCapBytes)
    }

    // MARK: - per-node timings, and the environment the engine reads

    /// `Progress.detailed` is read from the environment **at the start of every
    /// render** (`engine.cpp`), so the toggle can be a toggle rather than a
    /// relaunch: setting the variable before the next render is enough, and the
    /// engine needs no change for it (RFC-016's scope note).
    ///
    /// The race is real and benign. `setenv` is not safe against a concurrent
    /// `getenv`, and the engine's render thread is calling one — but the engine
    /// only asks `std::getenv(...) != nullptr`, and a pointer to a freed string
    /// is still not null, so the worst case is one render keeping the setting
    /// it had. Nothing is dereferenced, so nothing can be read after the free.
    private func applyPerNodeTimings() {
        if perNodeGPUTimings {
            setenv("SPEKTRAFILM_NODE_TIMINGS", "1", 1)
        } else {
            unsetenv("SPEKTRAFILM_NODE_TIMINGS")
        }
    }

    /// The caption under the checkbox (§5.2: "the Settings toggle must say so
    /// in the same sentence").
    nonisolated static let perNodeTimingsNote =
        "Asks the engine for a time per pipeline node. Each node must flush before its timer stops, "
        + "which gives up the batching the engine depends on — renders get markedly slower. It is a "
        + "diagnosis mode, never a default."

    /// The caption under the destination picker (§11.4).
    nonisolated static let logDirectoryNote =
        "Where sessions are written. A change takes effect at the next launch; this session keeps "
        + "writing to the file it opened."
}
