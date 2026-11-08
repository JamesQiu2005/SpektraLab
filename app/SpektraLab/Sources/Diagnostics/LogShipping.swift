//  LogShipping.swift — the log, sent: to where, what is due, and what came of it.
//
//  With the user's word (`Diagnostics.consent`), each session's file is sent
//  to SpektraLab's server as it stands — when the app is opened, the sessions
//  before this one; when the app is left, this one too:
//
//      PUT <base>/v1/logs/<install>/<session>      the file's bytes, as they are
//      Authorization: Bearer <key>                 Content-Type: application/x-ndjson
//
//  `LogShipping.swift` is the server's side of it. The same session is
//  sent again as it grows and the server keeps the latest, so what has been
//  sent is one number a session: its bytes as the server last took them
//  (`LogBook`, `sent.json` beside the files). A file is due when it has more.
//
//  **Where the server is, is the build's to say** (`LogEndpoint.bundled`): the
//  address and its key come from a file that is not in the repository
//  (`gen_project.py`, `logs.local`). A build given none sends nothing, and the
//  zip in Settings is how its log leaves the host.
//
//  **Sending is never in anyone's way.** It is asked for and forgotten: a
//  failure is a line in the log and a sentence in Settings, and the file is
//  due again next time. A server that cannot be reached from where the host
//  is (the owner, 2026-10-10: "in case Cloudflare worker is not available in
//  certain region") costs one request that times out, and the zip is there.
//
//  Foundation only: `tools/log_selftest.swift` runs it against a transport of
//  its own.
//
//  **All of it is compiled under `SPK_LOG_UPLOAD`** (`gen_project.py`): a debug
//  build's, and a release build's only where it was given a server, so a
//  release build without one has no request, no key's header and no address in it.

#if SPK_LOG_UPLOAD
import Foundation

/// Where the log goes, and the key the server asks for.
struct LogEndpoint: Equatable, Sendable {
    var base: URL
    var key: String

    /// The build's own: `SPKLogsURL` and `SPKLogsKey` in its Info.plist. Nil
    /// where the build was given none, or one that is not `https`.
    static func bundled(_ info: [String: Any]? = Bundle.main.infoDictionary) -> LogEndpoint? {
        guard let text = (info?["SPKLogsURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), url.scheme == "https", url.host != nil,
              let key = (info?["SPKLogsKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return LogEndpoint(base: url, key: key)
    }

    /// One session's upload. Low Data Mode is honoured: a log can wait. A
    /// server that does not answer is given twenty seconds, no more: where it
    /// cannot be reached at all, that is what every opening and leaving of the
    /// app would otherwise spend.
    func request(install: String, session: String, build: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("v1/logs/\(install)/\(session)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(String(build.prefix(64)), forHTTPHeaderField: "X-SpektraLab-Build")
        request.timeoutInterval = 20
        request.allowsConstrainedNetworkAccess = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

/// What has been sent: each session's bytes as the server last took them.
struct LogBook: Equatable, Sendable {
    var sent: [String: Int64] = [:]

    static let fileName = "sent.json"

    static func read(_ folder: URL) -> LogBook {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let kept = try? JSONDecoder().decode([String: Int64].self, from: data) else { return LogBook() }
        return LogBook(sent: kept)
    }

    func write(_ folder: URL) {
        guard let data = try? JSONEncoder().encode(sent) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The sessions with more in their file than was sent, the oldest first.
    /// The session being written is sent only when asked for: at launch it
    /// has said nothing yet.
    static func due(_ files: [(session: String, bytes: Int64)], sent: [String: Int64], current: String?,
                    includingCurrent: Bool) -> [String] {
        files.filter { $0.bytes > 0 && $0.bytes > (sent[$0.session] ?? 0) && (includingCurrent || $0.session != current) }
            .map(\.session).sorted()
    }

    /// Sessions whose files are gone are forgotten with them.
    mutating func hold(to sessions: Set<String>) {
        sent = sent.filter { sessions.contains($0.key) }
    }
}

/// The sending itself, one run at a time.
actor LogShipper {
    enum Outcome: Equatable, Sendable {
        /// Everything due was taken; `files` is 0 when nothing was due.
        case sent(files: Int, bytes: Int64)
        /// The server answered and will not take this build's logs (its key).
        case refused(Int)
        /// Not now: no way to the server from here, or it asked to wait.
        case later(String)

        var reached: Bool { if case .sent = self { true } else { false } }
    }

    /// The request and its body, to the status the server answered with.
    typealias Transport = @Sendable (URLRequest, Data) async -> Result<Int, Error>

    private let folder: URL
    private let endpoint: LogEndpoint
    private let build: String
    private let transport: Transport

    init(folder: URL, endpoint: LogEndpoint, build: String, transport: Transport? = nil) {
        self.folder = folder
        self.endpoint = endpoint
        self.build = build
        self.transport = transport ?? Self.overTheNetwork
    }

    /// Send what is due, the oldest session first, and stop at the first that
    /// cannot go: what is left is due again next time.
    func ship(install: String, current: String?, includingCurrent: Bool) async -> Outcome {
        var book = LogBook.read(folder)
        let files = LogStore.sessions(in: folder).map { url -> (session: String, bytes: Int64) in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (url.deletingPathExtension().lastPathComponent, size)
        }
        book.hold(to: Set(files.map(\.session)))
        var count = 0
        var bytes: Int64 = 0
        for session in LogBook.due(files, sent: book.sent, current: current, includingCurrent: includingCurrent) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(session + ".jsonl")), !data.isEmpty else { continue }
            switch await transport(endpoint.request(install: install, session: session, build: build), data) {
            case .success(200..<300):
                book.sent[session] = Int64(data.count)
                book.write(folder)
                count += 1
                bytes += Int64(data.count)
            case .success(let status) where status == 400 || status == 413:
                // This file as it is will not be taken: not asked again until it has more.
                book.sent[session] = Int64(data.count)
                book.write(folder)
            case .success(let status) where status == 401 || status == 403:
                book.write(folder)
                return .refused(status)
            case .success(let status):
                book.write(folder)
                return .later("the server answered \(status)")
            case .failure(let error):
                book.write(folder)
                return .later(Self.words(error))
            }
        }
        book.write(folder)
        return .sent(files: count, bytes: bytes)
    }

    /// An error as the log says it: its kind and number, never its own words
    /// (they carry the address, and are in the host's language).
    static func words(_ error: Error) -> String {
        guard let e = error as? URLError else { return "\(type(of: error))" }
        let word: String
        switch e.code {
        case .notConnectedToInternet: word = "offline"
        case .timedOut: word = "timed out"
        case .cannotFindHost, .dnsLookupFailed: word = "host not found"
        case .cannotConnectToHost: word = "cannot connect"
        case .networkConnectionLost: word = "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: word = "no secure connection"
        case .dataNotAllowed, .internationalRoamingOff: word = "no data allowed"
        case .cancelled: word = "cancelled"
        default: word = "network error"
        }
        return "\(word) (\(e.code.rawValue))"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let overTheNetwork: Transport = { request, body in
        do {
            let (_, response) = try await session.upload(for: request, from: body)
            return .success((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failure(error)
        }
    }
}
#endif
