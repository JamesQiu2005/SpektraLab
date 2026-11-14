// exit_render_check.swift -- a quit while the engine renders, against the engine `engine/build.sh dylib` leaves in
// engine/build (tools/exit_render_check.sh builds and runs it, many times).
//
// Why: a quit ends in `exit()`, which runs the C++ statics' destructors (`__cxa_finalize`) while the app's render
// threads are still inside the engine. history_check.sh once exited 139 after its green report: SIGSEGV in
// `spk::Colour::known_cctf` (a function-local `static const std::unordered_map`, destroyed) under
// `Pipeline::build` → `spk_open_device`, on a render thread, as the main thread was in `exit()` (2026-11-13). A
// person who quits during a develop would see "SpektraLab quit unexpectedly".
//
// One run: the engine on this Mac's GPU, `threads` threads (one, as the app's scheduler runs one job at a time; more
// than one on one engine trips Metal's own encoder assertions, a misuse and not this check's question) each opening a small frame, developing it at the live
// tier and releasing it, over and over (every open builds a pipeline, which reads the engine's tables); after a
// delay the main thread calls `exit(0)` with them in flight. Exit 0 is the run's whole verdict; a crash is the
// signal's status.
//
//   exit_render_check <resources dir> <delay ms> [threads, default 1: the app renders one job at a time]

import Foundation
import Metal

@main
enum ExitRenderCheck {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3, let delay = Int(args[2]) else { print("usage: exit_render_check <resources dir> <delay ms> [threads]"); exit(2) }
        let threads = args.count >= 4 ? Int(args[3]) ?? 1 : 1
        // What the app's `exit()` does that a bare tool's does not: CoreAnalytics' exit handler waits on its barrier
        // (`sendExitBarrierWithTimeoutSync`, thread 0 of the 2026-11-13 crash report). It was registered before the
        // engine's statics were first used, so it runs after their destructors, and the render thread goes on
        // meanwhile. An `atexit` handler registered here, before the engine is made, holds the exit the same way.
        atexit { usleep(250_000) }
        guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(2) }
        guard let engine = spk_engine_create(args[1], Unmanaged.passUnretained(device as AnyObject).toOpaque()) else {
            print("engine: " + String(cString: spk_last_error(nil))); exit(2)
        }
        let w = 384, h = 256
        guard let frame = device.makeBuffer(length: w * h * 16, options: .storageModeShared) else { print("no buffer"); exit(2) }
        let p = frame.contents().bindMemory(to: Float.self, capacity: w * h * 4)
        for i in 0..<(w * h) { p[i * 4] = 0.18; p[i * 4 + 1] = 0.2 * Float(i % w) / Float(w); p[i * 4 + 2] = 0.1; p[i * 4 + 3] = 1 }
        // Colour spaces whose transfer functions the build reads by name (`known_cctf`).
        let wires = [#"{"input_color_space":"sRGB"}"#, #"{"input_color_space":"Display P3"}"#, #"{"input_color_space":"ProPhoto RGB"}"#]
        let rendered = Atomic()
        for t in 0..<threads {
            Thread.detachNewThread {
                var k = t
                while true {
                    autoreleasepool {
                        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame as AnyObject).toOpaque(),
                                                     width: UInt32(w), height: UInt32(h), channels: 4)
                        var reply: UnsafeMutablePointer<CChar>?
                        guard let s = spk_open_device(engine, &image, wires[k % wires.count], &reply) else { return }
                        if let reply { spk_string_free(reply) }
                        var out = spk_result()
                        if spk_reprint(s, "live", &out) == SPK_OK {
                            if let texture = out.texture { Unmanaged<AnyObject>.fromOpaque(texture).release() }
                        }
                        spk_session_release(s)
                        rendered.add()
                        k += 1
                    }
                }
            }
        }
        usleep(useconds_t(delay * 1000))
        print("exit after \(delay) ms, \(rendered.value) renders done, \(threads) threads in flight")
        exit(0)
    }
}

final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
