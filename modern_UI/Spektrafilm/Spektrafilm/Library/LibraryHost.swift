//  LibraryHost.swift — the 2.0 library helper, `spklib-host`, as a child
//  process (`API-SPEC-library-helper.md` §2–§3).
//
//  The helper keeps libraries — SpektraLab catalogs and sessions, and a
//  Capture One catalog read one way through a snapshot — and the app talks to
//  it over three pipes: one compact JSON request per line in, one reply per
//  line out, in order, and stderr as a log. Nothing here links it.
//
//  **Started on first use, never at launch.** A person who only ever opens a
//  folder never pays for a second process: the first call starts it, and the
//  1.x path (`Import/Library.swift`, the sidecar files) never makes one. That
//  is the whole of what "the library costs nothing until it is used" means,
//  and it is why there is no `start()` in `applicationDidFinishLaunching`.
//
//  **A separate process on purpose.** SQLite, the Capture One snapshot copy
//  and a 10,000-row reply live in the helper's address space, not beside the
//  engine's Metal pool, and a crash in the helper cannot take a render with
//  it. The cost is that a handle (`"L1"`) dies with the process: `launches`
//  says when that happened, and `LibraryModel` reopens its library by path.

import Darwin
import Foundation

/// An error the helper answered with, by its code (§3's table), or the
/// transport failing under it.
struct LibraryError: Error, Equatable, Sendable, LocalizedError {
    enum Code: String, Sendable {
        case notFound = "not_found", invalidParams = "invalid_params", readOnly = "read_only"
        case conflict, sourceBusy = "source_busy", unsupported, exists, inUse = "in_use"
        case ambiguous, crossVolume = "cross_volume", io, internalError = "internal"
        case unknownMethod = "unknown_method"
        /// Not the helper's own: it could not be started, it stopped, or a
        /// reply could not be read. A call that fails this way may be retried
        /// once the helper is running again.
        case unavailable
    }

    let code: Code
    let message: String
    /// `data.revision`, which a `conflict` carries: the edit's current revision.
    var revision: Int?

    init(_ code: Code, _ message: String, revision: Int? = nil) {
        self.code = code
        self.message = message
        self.revision = revision
    }

    var errorDescription: String? { message }
}

actor LibraryHost {
    /// Where the helper is and where it keeps linked catalogs' mirrors.
    struct Launch: Sendable, Equatable {
        var executable: URL
        var store: URL
    }

    /// `Contents/Helpers/spklib-host`, where the app's Copy Files phase puts
    /// it, unless `SPEKTRALAB_LIBRARY_HOST` names another (a test, or a helper
    /// built from the SDK's source).
    nonisolated static func bundledExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SPEKTRALAB_LIBRARY_HOST"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.bundleURL.appending(path: "Contents/Helpers/spklib-host")
    }

    /// `~/Library/Application Support/SpektraLab/Libraries`: a linked Capture
    /// One catalog's mirror is `Linked/<document UUID>.spkcatalog` in here.
    /// Beside `Sidecars/`, never inside it — `Sidecar.identityIndex` lists that
    /// folder.
    nonisolated static let defaultStore: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SpektraLab")
            .appending(path: "Libraries")

    /// The ABI this build speaks (`sdk.version`'s `abi`). The helper is
    /// refused on any other: an old app must not misread a new helper's
    /// replies, and §7 bumps `abi` for exactly that.
    nonisolated static let abi = 1

    nonisolated let launch: Launch

    private var process: Process?
    private var input: FileHandle?
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var ready: CheckedContinuation<String, Error>?
    private var starting: Task<Void, Error>?
    private var nextID = 1

    /// `spklib 0.1.0+… (abi 1, schema 1)`, once a helper is running.
    private(set) var version: String?
    /// How many helpers this host has started. A handle from an earlier
    /// launch names nothing in this one.
    private(set) var launches = 0

    init(launch: Launch) {
        self.launch = launch
    }

    var isRunning: Bool { process?.isRunning == true && version != nil }

    // MARK: - lifetime

    func start() async throws {
        if isRunning { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.spawn() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func spawn() async throws {
        guard FileManager.default.isExecutableFile(atPath: launch.executable.path) else {
            throw LibraryError(.unavailable, "The library helper is not in the app (\(launch.executable.path)).")
        }
        do {
            try FileManager.default.createDirectory(at: launch.store, withIntermediateDirectories: true)
        } catch {
            throw LibraryError(.unavailable, "The library store cannot be made at \(launch.store.path): \(error.localizedDescription)")
        }
        // A write to a helper that has just died is EPIPE, which by default is
        // a signal that ends *this* process. Ignored, the write throws instead
        // and the call fails as `unavailable`.
        signal(SIGPIPE, SIG_IGN)

        let p = Process()
        p.executableURL = launch.executable
        p.arguments = ["--store", launch.store.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // One ordered stream of complete lines; the reader below is the only
        // consumer, so a reply is never read twice or out of turn.
        let (lines, sink) = AsyncStream<Data>.makeStream()
        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
                return
            }
            for line in splitter.feed(chunk) { sink.yield(line) }
        }
        let errSplitter = LineSplitter()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for line in errSplitter.feed(chunk) {
                Log.shared.info(.library, "spklib-host: " + String(decoding: line, as: UTF8.self))
            }
        }

        do {
            try p.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw LibraryError(.unavailable, "The library helper could not be started: \(error.localizedDescription)")
        }
        process = p
        input = stdin.fileHandleForWriting
        launches += 1
        let launch = launches
        Task { [weak self] in
            for await line in lines { await self?.deliver(line) }
            await self?.exited(launch: launch)
        }

        // `{"event":"ready",…}` is the first line, then `sdk.version` decides
        // whether this app may talk to it at all.
        let line: String = try await withCheckedThrowingContinuation { c in
            ready = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.readyTimedOut()
            }
        }
        let v: SDKVersion
        do {
            v = try LibraryCoding.decode(SDKVersion.self, from: try await send("sdk.version", Data("{}".utf8)))
        } catch {
            p.terminate()
            throw error
        }
        guard v.abi == Self.abi else {
            p.terminate()
            throw LibraryError(.unavailable, "The library helper speaks ABI \(v.abi); this SpektraLab needs \(Self.abi).")
        }
        version = line
        Log.shared.info(.library, "library helper started", [.init("version", line), .init("launch", launch)])
    }

    private func readyTimedOut() {
        guard let ready else { return }
        self.ready = nil
        ready.resume(throwing: LibraryError(.unavailable, "The library helper did not start within 10 s."))
        process?.terminate()
    }

    /// The helper's stdout closed: it exited, asked or not. Every call still
    /// waiting fails as `unavailable`, and the next call starts a new helper.
    private func exited(launch: Int) {
        guard launch == launches else { return }
        let unasked = version != nil
        process = nil
        input = nil
        version = nil
        let stranded = waiting
        waiting.removeAll()
        for c in stranded.values {
            c.resume(throwing: LibraryError(.unavailable, "The library helper stopped."))
        }
        if let ready {
            self.ready = nil
            ready.resume(throwing: LibraryError(.unavailable, "The library helper stopped while starting."))
        }
        if unasked { Log.shared.warn(.library, "library helper exited", [.init("launch", launch)]) }
    }

    /// `host.shutdown`, then stdin closed, then a terminate if it is still
    /// there (§2 "Quitting"). Every write is committed before its reply, so
    /// nothing a reply confirmed is lost by any of the three.
    func shutdown() async {
        guard let p = process, p.isRunning else { return }
        _ = try? await withTimeout(seconds: 2) { try await self.send("host.shutdown", Data("{}".utf8)) }
        try? input?.close()
        for _ in 0..<20 where p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if p.isRunning { p.terminate() }
    }

    // MARK: - calls

    /// One request; the whole reply line back. The caller decodes it
    /// (`LibraryCoding.decode`), so a 10,000-row page is parsed once.
    func call(_ method: String, _ params: Data) async throws -> Data {
        try await start()
        return try await send(method, params)
    }

    private func send(_ method: String, _ params: Data) async throws -> Data {
        guard let input else { throw LibraryError(.unavailable, "The library helper is not running.") }
        let id = nextID
        nextID += 1
        var line = Data("{\"id\":\(id),\"method\":".utf8)
        line.append(LibraryJSON.string(method))
        line.append(Data(",\"params\":".utf8))
        line.append(params)
        line.append(Data("}\n".utf8))
        return try await withCheckedThrowingContinuation { c in
            waiting[id] = c
            do {
                try input.write(contentsOf: line)
            } catch {
                waiting[id] = nil
                c.resume(throwing: LibraryError(.unavailable, "The library helper is not reading: \(error.localizedDescription)"))
            }
        }
    }

    private func deliver(_ line: Data) {
        if let id = LibraryJSON.leadingID(line) {
            if let c = waiting.removeValue(forKey: id) { c.resume(returning: line) }
            return
        }
        if let ready,
           let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           obj["event"] as? String == "ready" {
            self.ready = nil
            ready.resume(returning: obj["version"] as? String ?? "spklib")
            return
        }
        Log.shared.warn(.library, "spklib-host wrote a line that is not a reply: "
                        + String(decoding: line.prefix(200), as: UTF8.self))
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LibraryError(.unavailable, "The library helper did not answer within \(Int(seconds)) s.")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

/// Bytes in, complete lines out. A reply can be megabytes and arrive in many
/// chunks; a chunk can end mid-line or hold several. Each byte is scanned
/// once: rescanning the partial line on every chunk made a 5 MB page cost
/// hundreds of megabytes of `firstIndex`.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()

    func feed(_ chunk: Data) -> [Data] {
        lock.withLock {
            var lines: [Data] = []
            var rest = chunk[...]
            while let nl = rest.firstIndex(of: 0x0A) {
                partial.append(rest[rest.startIndex..<nl])
                if !partial.isEmpty { lines.append(partial) }
                partial = Data()
                rest = rest[rest.index(after: nl)...]
            }
            partial.append(rest)
            return lines
        }
    }
}
