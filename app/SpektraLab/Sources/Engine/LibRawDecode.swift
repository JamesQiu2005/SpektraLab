//  LibRawDecode.swift — a RAW decoded by LibRaw, in its own process (Settings › Develop › RAW decoder, 2.4.2).
//
//  The helper is `Contents/Helpers/spkraw-host` (engine/raw-helper: its build, its protocol), the Windows/Linux line's
//  decoder on the same pinned LibRaw. It is run once per decode — never linked, never kept running — so a file that
//  crashes LibRaw costs one decode, and LibRaw's memory goes back with its process. It writes the frame as linear
//  ProPhoto RGBA float32, top row first, its orientation applied: what `RawExposure.prepare` hands on from Core Image,
//  so everything after the decode (the app's lens step, the scale, the bands, the proxy, the engine) is the same code.
//
//  What LibRaw's picture has that Apple's has not, and the reverse:
//  - its own camera matrices, demosaic (AHD) and highlight clip (`compatible16`: values in [0, 1]), so the colour is
//    another decoder's, by design;
//  - the same exposure: LibRaw applies no baseline exposure of its own, so the file's (as Core Image reads it) and the
//    treatment's offset (`sourceOffsetEV`, the +1 EV of `source-reference.2`) are applied as one gain — within 0.5 EV
//    of Core Image's on every file of RAW_decode_tests, most within 0.15 (`tools/libraw_decode_check.sh`);
//  - no Core Image lens correction: the app's own step (a database lens, a file's own parameters) still applies;
//  - no black repair (`RawBlack` repairs Core Image's clamp, which LibRaw does not have).
//
//  A file LibRaw cannot read, a helper that is missing or fails: the decode is Apple's, and the log says why
//  (`report`). The choice is deterministic for a file, so a picture kept under LibRaw's key is always the same one.

import CoreImage
import Darwin
import Foundation

enum LibRawDecode {
    /// Where the log is told of a decode that fell back (the app sets it to `Log.warn` at launch; a self-test has none).
    nonisolated(unsafe) static var report: (String, [String: String]) -> Void = { _, _ in }

    /// `Contents/Helpers/spkraw-host`, where the app's build phase puts it, unless `SPEKTRALAB_RAW_HOST` names another.
    static var executable: URL {
        if let path = ProcessInfo.processInfo.environment["SPEKTRALAB_RAW_HOST"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spkraw-host")
    }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// The helper's LibRaw ("0.23.0-Snapshot202611"), asked once; nil when there is no helper that answers.
    static let version: String? = {
        guard isAvailable, let reply = try? run(["version"]), reply["ok"] as? Bool == true else { return nil }
        return reply["libraw"] as? String
    }()

    /// What a LibRaw decode learned that a neutral pick needs back (the helper's `calibration`), and the scale it was
    /// written at.
    struct Calibration: @unchecked Sendable {
        var json: [String: Any]
        var scale: Double
    }

    struct Decoded {
        var image: CIImage
        var asShot: (temperature: Double, tint: Double)
        var camera: [String: Any]
        var calibration: Calibration
        var version: String
        var width: Int
        var height: Int
        /// The file's baseline exposure applied (EV), as Core Image reads it.
        var baseline: Double
    }

    /// Calibrated D50, gamma 1, ProPhoto's primaries: the helper's output, as `FrameDecoder` renders into.
    static let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0, 0.1351917, 0.7118741, 0.0, 0.0313534, 0.0000857, 0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
    }()

    /// The white balance the helper is asked for: nil for the camera's own on both axes. A preset or custom 色温 with
    /// an As Shot 色调 (or the reverse) needs the camera's number for the other axis, which a `probe` reads.
    static func whiteBalance(_ url: URL, settings: DecodeSettings) -> (temperature: Double, tint: Double)? {
        guard !settings.isAsShot else { return nil }
        let temperature = settings.temperatureAsShot ? nil : (settings.whiteBalance.kelvin.map { Double($0) } ?? settings.temperature)
        let tint = settings.appliesTint ? settings.tint : nil
        if let temperature, let tint { return (temperature, tint) }
        guard let probe = try? run(["probe", url.path]), let camera = probe["camera"] as? [String: Any],
              let shot = camera["as_shot"] as? [String: Any],
              let t = shot["temperature"] as? Double, let g = shot["tint"] as? Double else {
            return (temperature ?? 5500, tint ?? 0)
        }
        return (temperature ?? t, tint ?? g)
    }

    /// The whole frame, decoded by the helper. Nil, with the log told, when it cannot be.
    static func decode(_ url: URL, settings: DecodeSettings) -> Decoded? {
        guard isAvailable else { report("LibRaw decoder missing", ["file": url.lastPathComponent]); return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("spkraw-\(UUID().uuidString).f32")
        defer { unlink(out.path) }
        // The decoder's exposure, as Core Image's: the file's own baseline exposure (a DNG's BaselineExposure, the maker's
        // for other files, as Core Image reads it) and the treatment's offset (`RawExposure.recipe`). LibRaw applies no
        // baseline of its own; without it a frame sat 0.35 EV (most Nikons, Sonys) to 1.3 EV (the GFX 100RF, the Z6III)
        // under Core Image's, and the E-300 0.5 over (measured 2026-11-18, `tools/libraw_decode_check.sh`).
        let frame = appleFrame(url)
        let baseline = frame?.baseline ?? 0
        let scale = exp2(settings.rawExposureTreatment.sourceOffsetEV + baseline)
        var args = ["decode", url.path, out.path, "--rgba", "--scale", String(scale), "--crop", "camera"]
        if let wb = whiteBalance(url, settings: settings) {
            args += ["--temperature", String(wb.temperature), "--tint", String(wb.tint)]
        }
        let reply: [String: Any]
        do { reply = try run(args) } catch {
            report("LibRaw decode failed", ["file": url.lastPathComponent, "why": "\(error)"]); return nil
        }
        guard reply["ok"] as? Bool == true, let w = (reply["width"] as? Double).map(Int.init),
              let h = (reply["height"] as? Double).map(Int.init), w > 0, h > 0,
              (reply["channels"] as? Double) == 4 else {
            report("LibRaw decode refused", ["file": url.lastPathComponent,
                                            "why": (reply["message"] as? String) ?? "no reply"])
            return nil
        }
        // Mapped, not read: the file's pages are the picture's until Core Image has rendered it. Unlinked at once (the
        // `defer`); the mapping holds the pages until the last image made from it is gone.
        guard let data = try? Data(contentsOf: out, options: .alwaysMapped), data.count == w * h * 16 else {
            report("LibRaw decode short", ["file": url.lastPathComponent]); return nil
        }
        var image = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                            format: .RGBAf, colorSpace: linearProPhoto)
        // The frame the library planned for: the helper cut the camera's own crop (`--crop camera`), which is Core
        // Image's frame to a pixel or two (measured 2026-11-18 over RAW_decode_tests: equal on 9 of 11 bodies, one row
        // or column short on the GFX 100RF and the E-300). Every size the app planned — an export's pixels, a crop's
        // fractions, the priced open (`ImportService.rawSize`, `ExportPlan`) — is Core Image's, so the last pixels are
        // made Core Image's: cut, or the edge row repeated. A frame further off than that is left as LibRaw made it.
        var size = (width: w, height: h)
        if let apple = frame.map({ (width: $0.width, height: $0.height) }), apple != size,
           abs(apple.width - w) <= 4, abs(apple.height - h) <= 4 {
            image = image.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: apple.width, height: apple.height))
            size = apple
        }
        let camera = reply["camera"] as? [String: Any] ?? [:]
        let shot = camera["as_shot"] as? [String: Any]
        let asShot = ((shot?["temperature"] as? Double) ?? 5500, (shot?["tint"] as? Double) ?? 0)
        let calibration = Calibration(json: reply["calibration"] as? [String: Any] ?? [:], scale: scale)
        return Decoded(image: image, asShot: asShot, camera: camera, calibration: calibration,
                       version: "libraw " + ((reply["libraw"] as? String) ?? "?"), width: size.width, height: size.height,
                       baseline: baseline)
    }

    /// Core Image's frame of `url` (its output's extent: no pixels are decoded) and its baseline exposure, kept by path;
    /// nil where Core Image cannot open it.
    static func appleFrame(_ url: URL) -> (width: Int, height: Int, baseline: Double)? {
        let key = url.standardizedFileURL.path
        if let kept = appleFrames.withLock({ $0[key] }) { return kept }
        guard let filter = CIRAWFilter(imageURL: url), let extent = filter.outputImage?.extent.integral, extent.width > 0
        else { return nil }
        let baseline = Double(filter.baselineExposure)
        let frame = (width: Int(extent.width), height: Int(extent.height), baseline: baseline.isFinite ? baseline : 0)
        appleFrames.withLock { $0[key] = frame }
        return frame
    }
    static func appleSize(_ url: URL) -> (width: Int, height: Int)? { appleFrame(url).map { ($0.width, $0.height) } }
    private static let appleFrames = Locked<[String: (width: Int, height: Int, baseline: Double)]>([:])

    /// `RawExposure.prepare`'s answer from LibRaw's pixels: the same `Prepared`, the app's lens step on it where the frame
    /// has one (`LensResolution`), scaled to `longEdge` the same way.
    static func prepare(_ url: URL, settings: DecodeSettings, longEdge: Int?, lens: LensResolution?) -> RawExposure.Prepared? {
        guard let decoded = decode(url, settings: settings) else { return nil }
        var image = decoded.image
        let resolution = lens ?? LensResolver.current(url, decode: settings)
        LensCorrection.applied.withLock { $0[url.standardizedFileURL.path] = resolution.word }
        if resolution.on, let profile = resolution.base.profile ?? LensCorrection.profile(url),
           let step = LensResolution.step(profile, resolution.amounts) {
            let filter = LensProfileFilter()
            filter.profile = step
            filter.distortionAmount = resolution.amounts.distortion
            filter.vignettingAmount = resolution.amounts.vignetting
            filter.chromaticAberration = resolution.amounts.chromaticAberration
            filter.hideDistortedAreas = resolution.amounts.hideDistortedAreas
            filter.inputImage = image
            image = filter.outputImage ?? image
        }
        let offset = settings.rawExposureTreatment.sourceOffsetEV
        let facts = RawExposureFacts(sourcePath: url.standardizedFileURL.path, treatment: settings.rawExposureTreatment,
            decoderVersion: decoded.version, baselineExposureEV: decoded.baseline, initialExposureEV: offset, initialShadowBias: 0,
            appliedExposureEV: offset, appliedShadowBias: 0, captureBiasEV: nil,
            captureISO: (decoded.camera["iso"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            captureSeconds: (decoded.camera["shutter_s"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            captureFNumber: (decoded.camera["aperture"] as? Double).flatMap { $0 > 0 ? $0 : nil })
        var prepared = RawExposure.Prepared(image: RawExposure.scaled(image, toLongEdge: longEdge), asShot: decoded.asShot,
                                            facts: facts, sourcePixels: Double(decoded.width * decoded.height))
        prepared.calibration = decoded.calibration
        return prepared
    }

    /// The white balance that makes linear ProPhoto `rgb` (as the decode under `calibration` rendered it) grey: LibRaw's
    /// own camera calibration inverted in closed form (`spkhost::neutral_temperature_tint`, the Windows line's pick).
    static func neutral(_ rgb: SIMD3<Double>, calibration: Calibration) -> (temperature: Double, tint: Double)? {
        let s = calibration.scale
        let body: [String: Any] = ["calibration": calibration.json, "rgb": [rgb.x / s, rgb.y / s, rgb.z / s]]
        guard let input = try? JSONSerialization.data(withJSONObject: body),
              let reply = try? run(["neutral"], stdin: input), reply["ok"] as? Bool == true,
              let t = reply["temperature"] as? Double, let g = reply["tint"] as? Double else { return nil }
        return (t, g)
    }

    // MARK: the process

    enum Failure: Error, CustomStringConvertible {
        case spawn(Int32), signalled(Int32), unreadable(String)
        var description: String {
            switch self {
            case .spawn(let rc): "could not start the helper (\(rc))"
            case .signalled(let s): "the helper stopped on signal \(s)"
            case .unreadable(let text): "unreadable reply: \(text.prefix(200))"
            }
        }
    }

    /// Runs the helper with `arguments` to its end and returns its one JSON line. An error reply (exit 2) is returned as
    /// it is (`ok` false); a crash or no JSON throws.
    static func run(_ arguments: [String], stdin: Data? = nil) throws -> [String: Any] {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw Failure.spawn(errno) }
        if stdin != nil, pipe(&inPipe) != 0 { close(outPipe[0]); close(outPipe[1]); throw Failure.spawn(errno) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        if stdin != nil { posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0) }
        else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors above reach the helper (`HelperProcess` says why).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = [executable.path] + arguments
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable.path, &actions, &attributes, &cargs, environ)
        close(outPipe[1])
        if stdin != nil { close(inPipe[0]) }
        guard rc == 0 else {
            close(outPipe[0]); if stdin != nil { close(inPipe[1]) }
            throw Failure.spawn(rc)
        }
        if let stdin {
            // A few hundred bytes: under a pipe's buffer, so writing before reading cannot deadlock.
            _ = stdin.withUnsafeBytes { write(inPipe[1], $0.baseAddress, $0.count) }
            close(inPipe[1])
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(outPipe[0], &buffer, buffer.count)
            if n > 0 { output.append(buffer, count: n) } else if n < 0, errno == EINTR { continue } else { break }
        }
        close(outPipe[0])
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7f
        if signal != 0 { throw Failure.signalled(signal) }
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw Failure.unreadable(String(decoding: output, as: UTF8.self))
        }
        return object
    }
}
