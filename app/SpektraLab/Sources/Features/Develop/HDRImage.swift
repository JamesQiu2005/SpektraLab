//  HDRImage.swift — a page's picture in HDR, where its frame's Enable HDR is on (2026-11-03).
//
//  The one view of the app's one HDR structure (`HDRRendition`): a page says what HDR its pictures have by
//  `.environment(\.hdrLook, HDRLook.of(edit))`, and every picture drawn under it — the develop as decoded
//  (`FramePicture`), Edit's live layer (`Layer2Picture`), the render at full size past the preview
//  (`DevelopCanvas`) — is drawn through `HDRImage`, which shows the SDR picture at once and, on a screen
//  with headroom, its rendition with `.allowedDynamicRange(.high)` as soon as it is made. Without a look,
//  or on an SDR screen, it is `Image` as before, and nothing is made.
//
//  - **What the export's file shows**: the same gain a pixel, the same weight Photos gives a map on a screen
//    with this headroom. Toggling Enable HDR is seen on the canvas at once.
//  - **Never a flash of SDR**: while the next rendition is made (a zoom step's decode, a slider's new layer)
//    the last one stays; at most one is being made at a time for a view, and the latest picture wins.
//  - **The screen** (`HDRScreen`): its headroom, read again on brightness, Low Power, heat and every second while
//    a rendition is on screen. Low Power Mode, serious heat and the system's HDR limit show SDR.
//
//  2026-11-06, D6. On the Mac:
//  - **The screen is the window's own** (D5): the AppKit screen the front window is on (`HDRDisplays.reading(for:)`,
//    through `MacDisplay.nsWindow`), its *potential* headroom (never the moment's: it ramps while EDR comes on
//    and falls with brightness), read again when the window moves to another display. A
//    window on an SDR monitor beside an XDR panel draws SDR; moved onto the panel, HDR. Where AppKit cannot be
//    reached, UIKit's `UIScreen` of the scene. No Light Table HDR this round, so the system reading (Low Power,
//    heat) is inlined here.
//    **Since PRD-B (2026-11-09)** the potential until the screen grants EDR, then no more than it grants
//    (`HDRScreen.read`), and a screen or headroom change re-runs only the display pass (`HDRShowing`), eased.
//  - **Never in a `Canvas`**: the perspective path of `FrameView` (`GeometryPicture` drawn with
//    `GraphicsContext.draw`) cannot carry EDR, and stays SDR.
//  - The log's `hdr picture` line names the screen it was read from.
//  - **The last rendition stays through a change of curve too** (`HDRLook.keeps`), not only of picture: a curve that
//    is a file per film and paper makes a new look a new pair; the Mac's is the session's and moves with
//    the edit (a Couplers step, a film format), and holding the latch to look equality dropped the canvas to SDR —
//    and the zoomed tile to nothing — on every such step (the 2026-11-06 review).

import ImageIO
import SwiftUI
import UIKit

private struct HDRLookKey: EnvironmentKey { static let defaultValue: HDRLook? = nil }

extension EnvironmentValues {
    /// The HDR of the pictures drawn here (`HDRImage`); nil draws them SDR.
    var hdrLook: HDRLook? {
        get { self[HDRLookKey.self] }
        set { self[HDRLookKey.self] = newValue }
    }
}

/// The screen's headroom, for the pages' HDR pictures.
///
/// **The display pass and the screen (PRD-B, 2026-11-09).** Image processing and display output are decoupled: a
/// page's picture is the engine's SDR develop and its gain (`HDRRendition.prepare`, once a picture and a look);
/// what the screen changes is only the share of that gain shown (`HDRRendition.show`, the light pass). A window
/// moving between an HDR and an SDR screen, or the headroom moving, re-runs that pass alone — no engine job, no
/// edit, no new curve — and the headroom **eases** there over `easeSeconds` (`shown`), so the picture never jumps,
/// flashes white or goes black.
///
/// - **Which headroom** (`HeadroomSource`): see `read()` for what was measured on this Mac's XDR panel.
/// - **On SDR** (headroom ≤ 1) the share is 0: the SDR develop, whose highlights the print has already rolled off
///   (the paper's own shoulder). Nothing is clipped at 1.0, because nothing in it is over 1.0.
/// - **Who owns the roll-off**: the curve (the engine's family-A shoulder up to H, and the kernels' clamped base).
///   The display pass is ISO 21496-1's weight — the gain scaled, in log, by log2 headroom / log2 H — never a second
///   compression of the same highlights, and its peak H^w is never over the headroom it was weighted for, so the
///   system's own tone mapper has nothing to do.
@MainActor @Observable
final class HDRScreen {
    static let shared = HDRScreen()

    /// EDR units over SDR white that a rendition may use, settled (in tenth-of-a-stop steps): 1 = none (SDR). What
    /// the histogram and the curve's HDR line count with.
    private(set) var headroom: Double = 1
    /// The headroom the pictures are drawn at now: `headroom`, eased into over `easeSeconds` after it moves.
    private(set) var shown: Double = 1
    /// The window's screen as last read: what its panel can do, and what it gives now (1 until something on it
    /// asks for EDR, then rising to what the brightness leaves).
    /// Not observed: no view reads them, and `current` moves at the display's refresh while EDR ramps (410 readings in
    /// 39 s on 2026-11-10), which would redraw every reader for nothing. `headroom` and `shown` are what views read.
    @ObservationIgnored private(set) var potential: Double = 1
    @ObservationIgnored private(set) var current: Double = 1
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ease: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// How long a headroom change takes on screen.
    static let easeSeconds = 0.3

    /// Which reading the share is taken from.
    enum HeadroomSource: String { case auto, potential, current }
    /// `--hdr-headroom-from auto|potential|current` (debug builds) chooses for a measurement; see `read()` for the default.
    static let source: HeadroomSource = {
        #if DEBUG
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--hdr-headroom-from"), i + 1 < a.count, let s = HeadroomSource(rawValue: a[i + 1]) { return s }
        #endif
        return .potential
    }()

    private init() {}

    /// A picture that may be HDR is on screen / gone.
    func watch(_ on: Bool) {
        viewers = max(0, viewers + (on ? 1 : -1))
        if viewers > 0, timer == nil {
            read()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in HDRScreen.shared.read() } }
            observers = HDRScreen.changes.map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in Task { @MainActor in HDRScreen.shared.read() } }
            }
        } else if viewers == 0, let t = timer {
            t.invalidate(); timer = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
        }
    }

    /// The front scene's key window: whose screen the canvas is drawn on.
    private var window: UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    /// Which screen the last reading was of, for the log.
    @ObservationIgnored private(set) var sourceName = "none"
    @ObservationIgnored private var lastSaid = ""

    func read() {
        // No scene in front (the app going inactive, another app in front): nothing to read, so nothing
        // changes. 2026-11-03, the log: each return to the front read no screen, then 3.2, 1.9, 1.4 and
        // only then 16 — the canvas was remade weaker each time ("falls back to the old setting").
        guard let window else { return }
        var potential: Double, current: Double
        #if targetEnvironment(macCatalyst)
        // A window across two screens is AppKit's `window.screen`: the one with the larger part of it (v1; no
        // per-display presentation).
        if let r = HDRDisplays.reading(for: window) {
            potential = r.potential; current = r.current
            sourceName = r.name + " (" + r.by + ")"
        } else {
            potential = max(1, Double(window.screen.potentialEDRHeadroom)); current = max(1, Double(window.screen.currentEDRHeadroom))
            sourceName = "UIScreen (UIKit)"
        }
        #else
        potential = max(1, Double(window.screen.potentialEDRHeadroom)); current = max(1, Double(window.screen.currentEDRHeadroom))
        sourceName = "UIScreen (UIKit)"
        if let f = HDRDisplays.forced { potential = f; current = f }
        #endif
        if potential != self.potential { self.potential = potential }
        if current != self.current { self.current = current }
        let p = ProcessInfo.processInfo
        let hot = p.thermalState == .serious || p.thermalState == .critical
        var limited = false
        if #available(iOS 26.0, macCatalyst 26.0, *) { limited = window.traitCollection.hdrHeadroomUsageLimit == .active }
        // **Which headroom** (PRD-B, measured 2026-11-09 on this Mac's built-in XDR panel, an LG HDR 5K beside it
        // reporting no EDR): the XDR's potential reads 16 at every moment. Its current is **not** what the panel could
        // give: it follows what is on it. 1.0 until a layer asks for EDR, it ramped to 1.2 under the canvas, and when
        // the share was taken from it (`--hdr-headroom-from auto`: the potential until EDR is granted, the smaller of
        // the two after) it fell with the share it had set — 1.23 → 1.15 → 1.07 → 1.0 in 1.5 s, the picture weaker
        // each step — until it read 1 again and the share jumped back to the potential's: a loop
        // (`HDRScreen.read`), seen on a Mac. So the share is the potential's; the picture is
        // marked with its peak H^w (`HDRRendition.show`), so where the moment's headroom is under it the system maps
        // the top of it into what the panel has. That is the only place a second roll-off can happen, and only where
        // the panel cannot show the curve's own. `--hdr-headroom-from current|auto` keep the two others for a
        // measurement.
        let from: Double
        switch Self.source {
        case .potential: from = potential
        case .current: from = min(potential, max(current, 1))
        case .auto: from = current > 1.01 ? min(potential, current) : potential   // measured to loop: see above
        }
        var now = (p.isLowPowerModeEnabled || hot || limited || potential <= 1.01 || !FeatureFlags.screenShowsHDR) ? 1 : from
        // In steps of a tenth of a stop, so brightness drift does not remake the picture.
        now = exp2((log2(max(now, 1)) * 10).rounded() / 10)
        let sig = "\(sourceName)|\(potential)|\((current * 100).rounded() / 100)|\(now)"
        if sig != lastSaid {
            lastSaid = sig
            Log.note(.develop, "hdr screen", ["screen": sourceName, "potential": potential, "current": (current * 1000).rounded() / 1000,
                                              "headroom": now, "from": Self.source.rawValue])
        }
        if now != headroom { headroom = now; easeTo(now) }
    }

    /// `shown` moves to `target` over `easeSeconds`, in log2, at 30 steps a second (each step a display pass).
    private func easeTo(_ target: Double) {
        ease?.invalidate()
        let from = log2(max(shown, 1)), to = log2(max(target, 1)), start = Date()
        guard abs(to - from) > 1e-6 else { shown = target; return }
        ease = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { t in
            Task { @MainActor in
                let s = HDRScreen.shared
                let f = min(1, Date().timeIntervalSince(start) / HDRScreen.easeSeconds)
                let k = f * f * (3 - 2 * f)
                s.shown = exp2(from + (to - from) * k)
                if f >= 1 { s.shown = target; t.invalidate(); if s.ease === t { s.ease = nil } }
            }
        }
    }

    /// After these, the headroom is read again: the window on another display, a display changed or its colour
    /// profile, the power state.
    static let changes: [Notification.Name] = {
        var n: [Notification.Name] = [UIScreen.brightnessDidChangeNotification, UIApplication.didBecomeActiveNotification,
                                      Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        #if targetEnvironment(macCatalyst)
        n += ["NSWindowDidChangeScreenNotification", "NSApplicationDidChangeScreenParametersNotification",
              "NSWindowDidChangeScreenProfileNotification", "NSScreenColorSpaceDidChangeNotification"].map { Notification.Name($0) }
        #endif
        return n
    }()
}

/// A page picture's gain, made ready once a picture and a look, and its display passes (PRD-B): what `HDRImage` and
/// `HDRPlacedImage` share.
@MainActor @Observable
final class HDRShowing {
    private(set) var image: CGImage?
    private(set) var look: HDRLook?
    /// Where the shown rendition sits (a full-size part's rect); nil for a whole picture.
    private(set) var place: CGRect?
    @ObservationIgnored private var prepared: HDRRendition.Prepared?
    @ObservationIgnored private var preparedFor: (ObjectIdentifier, HDRLook)?
    @ObservationIgnored private var preparedPlace: CGRect?
    @ObservationIgnored private var showing = false
    @ObservationIgnored private var wanted: Double?
    /// One prepare at a time; while one is out only the newest picture waits, and the one out is never thrown
    /// away (2026-11-10). Before, each new picture — every part a zoom or a pan asked, every peak step — cancelled
    /// the view's task, so the finished gain was dropped and a new one queued on `HDRRendition.gate`: during a
    /// gesture nothing new ever reached the screen (a zoomed part "never shown before its HDR is made" stayed the
    /// old one), and the queue grew. Now each one that finishes is shown, at its own place, and the next is the
    /// newest asked: the canvas follows a gesture at the rate the GPU makes renditions (~25–100 ms).
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var next: (sdr: CGImage, look: HDRLook, place: CGRect?)?
    @ObservationIgnored private var epoch = 0

    /// Ask for the rendition of `sdr` under `look` (at `place`), shown when made. Returns at once when another is
    /// being made: that one's loop takes this one next.
    func request(_ sdr: CGImage, look: HDRLook, place: CGRect? = nil) async {
        if let p = preparedFor, p.0 == ObjectIdentifier(sdr), p.1 == look, p.1.tables == look.tables, prepared != nil {
            if place != preparedPlace { preparedPlace = place }
            await show(weight: look.weight(headroom: HDRScreen.shared.shown))
            return
        }
        next = (sdr, look, place)
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        while let job = next {
            next = nil
            let mine = epoch, started = Date()
            let made: HDRRendition.Prepared
            do {
                made = try await Task.detached(priority: .userInitiated) { try HDRRendition.prepare(job.sdr, look: job.look) }.value
            } catch {
                Log.warn(.develop, "hdr picture failed", ["curve": job.look.curve.name, "error": Log.words(error)])
                continue
            }
            guard mine == epoch else { continue }
            prepared = made; preparedFor = (ObjectIdentifier(job.sdr), job.look); preparedPlace = job.place; self.look = job.look
            HDRImage.say("hdr picture prepared", ["curve": job.look.curve.name, "px": [job.sdr.width, job.sdr.height],
                                                   "ms": Int(Date().timeIntervalSince(started) * 1000), "parts": HDRRendition.lastTimes,
                                                   "page_makes": HDRRendition.pageMakes, "waiting": next != nil])
            await show(weight: job.look.weight(headroom: HDRScreen.shared.shown))
        }
    }

    /// The display pass at `weight`; the latest asked wins, one at a time.
    func show(weight: Double) async {
        wanted = weight
        guard !showing else { return }
        showing = true; defer { showing = false }
        while let w = wanted, let p = prepared {
            wanted = nil
            let at = preparedPlace
            let started = Date()
            let made = await Task.detached(priority: .userInitiated) { try? HDRRendition.show(p, weight: w) }.value
            guard let made, prepared === p else { continue }
            image = made
            place = at
            HDRImage.say("hdr display pass", ["weight": (w * 1000).rounded() / 1000, "px": [p.width, p.height],
                                              "ms": Int(Date().timeIntervalSince(started) * 1000), "headroom": HDRScreen.shared.shown,
                                              "content_headroom": pow(p.headroom, w)])
        }
    }

    /// Let go of everything: the picture is SDR again.
    func clear() {
        epoch &+= 1
        image = nil; look = nil; place = nil; prepared = nil; preparedFor = nil; preparedPlace = nil; wanted = nil; next = nil
    }
}

/// A picture, in HDR where the page gives it a look and the screen has headroom (see the header).
struct HDRImage: View {
    let image: CGImage
    /// Nil stretches the picture to the frame it is given.
    var contentMode: ContentMode? = .fit

    @Environment(\.hdrLook) private var look
    @State private var screen = HDRScreen.shared
    @State private var showing = HDRShowing()
    @State private var watching = false

    /// The screen is read only while a picture with a look is on it.
    private func watch(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        screen.watch(on)
    }

    private struct Key: Equatable { var image: ObjectIdentifier; var look: HDRLook?; var tables: HDRGrainGain.Tables? }

    var body: some View {
        let weight = look?.weight(headroom: screen.shown) ?? 0
        Group {
            if let look, weight > 0.001, let shown = showing.image, HDRLook.keeps(showing.look, for: look) {
                fitted(Image(decorative: shown, scale: 1).resizable()).allowedDynamicRange(.high)
            } else {
                fitted(Image(decorative: image, scale: 1).resizable())
            }
        }
        // The heavy part, once a picture and a look: never for a screen or a headroom.
        .task(id: Key(image: ObjectIdentifier(image), look: look, tables: look?.tables)) {
            guard let look else { showing.clear(); return }
            guard FeatureFlags.screenShowsHDR else { showing.clear(); return }
            #if DEBUG
            if !(showing.image != nil && HDRLook.keeps(showing.look, for: look)) {
                Log.note(.develop, "hdr picture gap", ["curve": look.curve.name, "px": [image.width, image.height]])
            }
            #endif
            await showing.request(image, look: look)
        }
        // The light part: the screen's share, eased (`HDRScreen.shown`).
        .onChange(of: (weight * 1000).rounded()) { _, _ in
            guard look != nil else { return }
            Task { await showing.show(weight: weight) }
        }
        .onChange(of: look != nil, initial: true) { _, on in watch(on) }
        .onAppear { watch(look != nil) }
        .onDisappear { watch(false) }
    }
}

extension HDRImage {
    #if DEBUG
    /// `--hdr-dump`: each page picture's SDR source (16-bit PNG) and its HDR rendition (raw half floats, RGBA,
    /// linear extended P3) into Documents/hdr-dump, to hold the canvas against the export on a Mac.
    static func dump(sdr: CGImage, edr: CGImage) {
        guard CommandLine.arguments.contains("--hdr-dump"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("hdr-dump")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = "\(sdr.width)x\(sdr.height)-\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)"
        if let data = edr.dataProvider?.data as Data? { try? data.write(to: dir.appendingPathComponent(tag + ".edr.rgba16f")) }
        if let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(tag + ".sdr.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, sdr, nil); CGImageDestinationFinalize(dest)
        }
    }
    #endif

    /// One line a change of picture size, curve or headroom — never one a slider's step.
    @MainActor private static var lastSaid = ""
    @MainActor static func say(_ message: String, _ fields: [String: Any]) {
        let sig = message + "\(fields["curve"] ?? "")\(fields["px"] ?? "")\(fields["headroom"] ?? "")\(fields["weight"] ?? "")"
        guard sig != lastSaid else { return }
        lastSaid = sig
        Log.note(.develop, message, fields)
    }

    @ViewBuilder fileprivate func fitted(_ i: Image) -> some View {
        if let contentMode { i.aspectRatio(contentMode: contentMode) } else { i }
    }

    init(_ image: UIImage, contentMode: ContentMode = .fit) {
        self.init(image: image.cgImage ?? HDRImage.blank, contentMode: contentMode)
    }
    private static let blank: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}

/// A part of a picture placed on it — the canvas's render at full size past the preview (`DevelopCanvas`) — in
/// HDR where the page gives it a look. **Never shown before its HDR is made**: a new part (a pan, a zoom) keeps
/// the last one, at the last one's place, until its own rendition lands; the first one shows nothing until then
/// (the picture under it, already HDR, stays). 2026-11-03, the owner: zoomed to full size the canvas
/// "would sometimes black out, refresh and go back" — the part came in SDR over the HDR picture, a quarter of
/// its highlights' light, then its rendition. Without a look it is the part as before, at once. Its display pass
/// follows the same eased headroom as the picture under it (`HDRScreen.shown`), so the two never part.
struct HDRPlacedImage: View {
    let image: CGImage
    /// Where it is on the picture: normalised, top-left origin.
    let rect: CGRect

    @Environment(\.hdrLook) private var look
    @State private var screen = HDRScreen.shared
    @State private var showing = HDRShowing()
    @State private var watching = false

    private struct Key: Equatable { var image: ObjectIdentifier; var look: HDRLook?; var tables: HDRGrainGain.Tables? }

    private func watch(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        screen.watch(on)
    }

    var body: some View {
        let weight = look?.weight(headroom: screen.shown) ?? 0
        GeometryReader { g in
            if let look, FeatureFlags.screenShowsHDR, weight > 0.001 {
                if let shown = showing.image, let r = showing.place, HDRLook.keeps(showing.look, for: look) {
                    Image(decorative: shown, scale: 1).resizable().allowedDynamicRange(.high)
                        .frame(width: r.width * g.size.width, height: r.height * g.size.height)
                        .position(x: r.midX * g.size.width, y: r.midY * g.size.height)
                }
            } else {
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: rect.width * g.size.width, height: rect.height * g.size.height)
                    .position(x: rect.midX * g.size.width, y: rect.midY * g.size.height)
            }
        }
        .task(id: Key(image: ObjectIdentifier(image), look: look, tables: look?.tables)) {
            guard let look, FeatureFlags.screenShowsHDR else { showing.clear(); return }
            await showing.request(image, look: look, place: rect)
        }
        .onChange(of: (weight * 1000).rounded()) { _, _ in
            guard look != nil else { return }
            Task { await showing.show(weight: weight) }
        }
        .onChange(of: look != nil, initial: true) { _, on in watch(on) }
        .onAppear { watch(look != nil) }
        .onDisappear { watch(false) }
    }
}
