//  AgentServer.swift — the running app's end of the agent socket (ARCHITECTURE.md §7.16).
//
//  Listens from launch to quit (`AppServices.launch`, not under `--snapshot`), whether or not access is
//  on: the switch is read at every call, on the main actor (`AgentExecutor`), so turning it off refuses
//  the very next call of an agent already connected, and turning it on needs no relaunch.
//
//  - **One socket per bundle and home** (`AgentWire.socketPath`), mode 0600 in the user's own 0700
//    temporary folder. A file left by an app that ended without closing it is removed at start — but only
//    when nothing answers on it: a second copy of the same build (`open -n`) leaves the first one's alone
//    and serves no agents, which the log says.
//  - **Threads, not the main actor, wait on the socket**: one accepts, one per connection reads lines.
//    Each request is then run on the main actor (`execute`), and the connection's thread waits for its
//    reply. **One request at a time, app-wide** (`turn`): two agents never interleave two changes to one
//    library, as two people at one window would not.

import Darwin
import Foundation

final class AgentServer: @unchecked Sendable {
    static let shared = AgentServer()

    /// Runs one request on the main actor: the reply object, `id` filled in here.
    typealias Execute = @MainActor @Sendable (_ tool: String, _ arguments: JSONValue?) async -> JSONValue

    private(set) var path = ""
    private var listener: Int32 = -1
    private var execute: Execute?
    /// One request at a time, whichever connection it came on.
    private let turn = NSLock()

    /// Starts listening. False when it could not (another copy of the app has the socket, or the socket
    /// could not be made); the app runs on without agents and the log says why.
    @discardableResult
    func start(path: String = AgentWire.socketPath(), execute: @escaping Execute) -> Bool {
        guard listener < 0 else { return true }
        self.path = path
        self.execute = execute
        guard var addr = AgentWire.address(path) else {
            Log.warn(.app, "agent socket: the path is too long", ["length": path.utf8.count])
            return false
        }
        // A socket file that answers is another copy's; one that does not is left from an app that ended.
        if FileManager.default.fileExists(atPath: path) {
            if Self.answers(&addr) {
                Log.warn(.app, "agent socket: another copy of this build is serving agents")
                return false
            }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { Log.warn(.app, "agent socket: socket() failed", ["errno": errno]); return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            Log.warn(.app, "agent socket: bind() failed", ["errno": errno])
            close(s)
            return false
        }
        // The folder is the user's alone already; the file is too.
        chmod(path, 0o600)
        guard listen(s, 8) == 0 else {
            Log.warn(.app, "agent socket: listen() failed", ["errno": errno])
            close(s)
            unlink(path)
            return false
        }
        listener = s
        let accepting = Thread { [weak self] in self?.acceptLoop(s) }
        accepting.name = "agent socket"
        accepting.start()
        Log.note(.app, "agent socket listening")
        return true
    }

    /// The socket file, removed as the app quits (a file left behind is removed at the next start anyway).
    func stop() {
        guard listener >= 0 else { return }
        // `shutdown` first: on Darwin a `close` alone does not wake the thread blocked in `accept`.
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        unlink(path)
    }

    private static func answers(_ addr: inout sockaddr_un) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return   // closed by `stop`
            }
            AgentWire.noSigpipe(c)
            let serving = Thread { [weak self] in self?.serve(c) }
            serving.name = "agent connection"
            serving.start()
        }
    }

    /// One connection: a request a line, a reply a line, until the client closes it.
    private func serve(_ c: Int32) {
        defer { close(c) }
        let reader = AgentLineReader(fd: c)
        while let line = reader.next() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let reply = respond(line)
            guard AgentWire.writeAll(c, Data((reply.text() + "\n").utf8)) else { return }
        }
    }

    private func respond(_ line: String) -> JSONValue {
        guard let request = try? JSONValue.parse(line), request.object != nil else {
            return ["id": .null, "ok": false, "refused": true, "error": "The request is not a JSON object."]
        }
        let id = request["id"] ?? .null
        guard let tool = request["tool"]?.string, let execute else {
            return ["id": id, "ok": false, "refused": true, "error": "The request names no tool."]
        }
        turn.lock()
        defer { turn.unlock() }
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let arguments = request["arguments"]
        Task { @MainActor in
            box.value = await execute(tool, arguments)
            done.signal()
        }
        done.wait()
        var reply = box.value.object ?? [:]
        reply["id"] = id
        return .object(reply)
    }

    private final class ReplyBox: @unchecked Sendable { var value: JSONValue = .null }
}
