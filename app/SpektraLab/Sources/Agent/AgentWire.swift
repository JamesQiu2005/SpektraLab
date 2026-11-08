//  AgentWire.swift — the app's agent socket: where it is, how a line crosses it, and the client's end
//  (ARCHITECTURE.md §7.16).
//
//  **A Unix domain socket in the user's own temporary folder**, named with the bundle id, so a Debug build
//  (`com.spektralab.mac.local`) and a release (`com.spektralab.mac`) never answer each other's agents:
//  `NSTemporaryDirectory()` is `/var/folders/…/T/`, already the user's alone (0700), and short — `sun_path`
//  holds 104 bytes, which `~/Library/Application Support/…` under a test's `CFFIXED_USER_HOME` can pass.
//  A run under `CFFIXED_USER_HOME` (a test's isolated home) adds a hash of that home to the name: its
//  agents reach its app, and never the owner's own.
//
//  **Newline-delimited JSON both ways**, one request at a time per connection, as many as the client
//  sends: `{"id":…, "tool": name, "arguments": {…}}` in, `{"id":…, "ok": true, "result": …}` or
//  `{"id":…, "ok": false, "refused": bool, "error": "…"}` out. JSON text never holds a raw line break
//  (the encoder escapes one in a string), so a line is a message.
//
//  Foundation and Darwin only: the client (`AgentClient`) runs before UIKit is touched.

import Darwin
import Foundation

enum AgentWire {
    /// The socket's path for this bundle (and this home, under a test's `CFFIXED_USER_HOME`).
    static func socketPath(bundleID: String? = Bundle.main.bundleIdentifier,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           temporary: String = NSTemporaryDirectory()) -> String {
        let id = bundleID ?? "com.spektralab.mac"
        var name = "spektralab-\(id)"
        if let home = environment["CFFIXED_USER_HOME"], !home.isEmpty { name += "-" + shortHash(home) }
        let folder = temporary.hasSuffix("/") ? temporary : temporary + "/"
        let path = folder + name + ".sock"
        // Never longer than `sun_path` takes: a long bundle id gives way to its hash.
        if path.utf8.count < 104 { return path }
        return folder + "spk-" + shortHash(name) + ".sock"
    }

    /// FNV-1a, 32 bits, as hex: stable from run to run (Swift's own `hashValue` is not).
    static func shortHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%08x", h)
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// A socket that never raises SIGPIPE when the other end has gone: a write fails with EPIPE instead.
    /// (The app is the other end of every agent: a client that quits mid-reply must not end it.)
    static func noSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Every byte of `data`, or false.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                p += n
            }
            return true
        }
    }
}

/// Reads a socket a line at a time.
final class AgentLineReader {
    private let fd: Int32
    private var buffer = Data()
    init(fd: Int32) { self.fd = fd }

    /// The next line without its "\n"; nil at the end of the stream (or an error).
    func next() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                // A last line with no "\n" is still a line.
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// The client's end: one connection to the running app, made on first use, launching the app when nothing
/// answers. Synchronous: the client modes have nothing else to do while a call runs (an export can take
/// minutes), and no run loop of UIKit's is started for them.
final class AgentConnection {
    let path: String
    private var fd: Int32 = -1
    private var reader: AgentLineReader?
    private var nextID = 1
    /// How long a launched app is given to open its socket.
    var launchWait: TimeInterval = 30
    /// Whether a call may launch the app when nothing answers (off in the selftest).
    var mayLaunch = true

    init(path: String = AgentWire.socketPath()) { self.path = path }
    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        reader = nil
    }

    /// One call: the app's reply as it came (`ok`, `result` or `refused` and `error`).
    func call(_ tool: String, _ arguments: JSONValue) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let line = JSONValue.object(["id": .number(Double(id)), "tool": .string(tool), "arguments": arguments]).text() + "\n"
        try connect()
        // A connection that went away between calls (the app quit, and an MCP server outlived it) fails its
        // write — a Unix socket whose peer has closed says EPIPE at once — and is made again, once. A call
        // whose write went through is never sent twice: the app may have done it before it went.
        if !AgentWire.writeAll(fd, Data(line.utf8)) {
            close()
            try connect()
            guard AgentWire.writeAll(fd, Data(line.utf8)) else {
                close()
                throw AgentError.failed("SpektraLab's socket took no request.")
            }
        }
        guard let reply = reader?.next() else {
            close()
            throw AgentError.failed("SpektraLab closed the connection before replying (it may have quit).")
        }
        guard let v = try? JSONValue.parse(reply), v.object != nil else {
            throw AgentError.failed("SpektraLab's reply could not be read.")
        }
        return v
    }

    private func connect() throws {
        guard fd < 0 else { return }
        if tryConnect() { return }
        guard mayLaunch else { throw AgentError.failed("SpektraLab is not running (nothing at \(path)).") }
        try AgentLauncher.launchHidden()
        let deadline = Date().addingTimeInterval(launchWait)
        while Date() < deadline {
            usleep(250_000)
            if tryConnect() { return }
        }
        throw AgentError.failed("SpektraLab was opened but did not answer within \(Int(launchWait)) s (nothing at \(path)). "
                                + "Open SpektraLab, then try again.")
    }

    private func tryConnect() -> Bool {
        guard var addr = AgentWire.address(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        AgentWire.noSigpipe(s)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(s); return false }
        fd = s
        reader = AgentLineReader(fd: s)
        return true
    }
}

/// Opens the app this executable belongs to, hidden and in the background, as Finder would: through
/// `open` (Launch Services), so it is the app's ordinary launch with its window and menus, not this
/// process carrying on as the app. `posix_spawn`, not `Process`: nothing of Foundation's task machinery
/// is wanted for one short child.
enum AgentLauncher {
    /// The `.app` around this executable, or nil when it is not in one (a bare test binary).
    static var appBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    static func launchHidden() throws {
        guard let app = appBundle else { throw AgentError.failed("This executable is not inside SpektraLab.app, so it cannot open the app.") }
        var args = ["/usr/bin/open", "-g", "-j"]
        // A test's isolated home goes with the app it opens (`open --env`, macOS 13 and later): otherwise the
        // app would open the owner's own library while this client looks for a socket named for the test's.
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty {
            args += ["--env", "CFFIXED_USER_HOME=\(home)"]
        }
        args.append(app.path)
        var pid: pid_t = 0
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let spawned = posix_spawn(&pid, "/usr/bin/open", nil, nil, cArgs, environ)
        guard spawned == 0 else { throw AgentError.failed("SpektraLab could not be opened (posix_spawn: \(String(cString: strerror(spawned)))).") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // `open` itself returns at once; a non-zero status is Launch Services' refusal (no such app, damaged).
        if status != 0 { throw AgentError.failed("SpektraLab could not be opened (open exited with \(status >> 8)).") }
    }
}
