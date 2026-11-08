//  HelperProcess.swift — the little of Foundation's `Process` that LibraryHost uses, on
//  posix_spawn, because `Process` is unavailable in Mac Catalyst. The Mac app is not
//  sandboxed, so it may start the helper in its bundle as the desktop app does.

import Darwin
import Foundation

final class HelperProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String] = []
    var standardInput: Pipe?
    var standardOutput: Pipe?
    var standardError: Pipe?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited = false

    var isRunning: Bool { lock.withLock { pid != 0 && !exited } }

    func run() throws {
        guard let executableURL else { throw POSIXError(.ENOENT) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let p = standardInput { posix_spawn_file_actions_adddup2(&actions, p.fileHandleForReading.fileDescriptor, 0) }
        if let p = standardOutput { posix_spawn_file_actions_adddup2(&actions, p.fileHandleForWriting.fileDescriptor, 1) }
        if let p = standardError { posix_spawn_file_actions_adddup2(&actions, p.fileHandleForWriting.fileDescriptor, 2) }
        let argv = [executableURL.path] + arguments
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var child: pid_t = 0
        // Only the three descriptors above, nothing else of the app's: without this the helper
        // inherits the write end of its own stdin, never reads EOF, and outlives a killed app.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let rc = posix_spawn(&child, executableURL.path, &actions, &attributes, &cargs, environ)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EPERM) }
        // The child holds its ends now; ours are closed, so its exit closes stdout for the reader.
        try? standardInput?.fileHandleForReading.close()
        try? standardOutput?.fileHandleForWriting.close()
        try? standardError?.fileHandleForWriting.close()
        lock.withLock { pid = child }
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            self?.lock.withLock { self?.exited = true }
        }
    }

    func terminate() {
        let p = lock.withLock { exited ? 0 : pid }
        if p != 0 { kill(p, SIGTERM) }
    }
}
