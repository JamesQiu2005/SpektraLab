//  log_selftest.swift — the app's own log, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  The log is what a build other people use says of itself, and it leaves the host (with the
//  user's word, to the server; by their hand, as a zip). What goes wrong with it goes wrong quietly,
//  so each of these is checked with no host and no server:
//
//  - **a line** (`LogStore.line`, `LogJSON`, `LogScrub`): one line whatever it is given, the four
//    fields first, a nil left out, a number JSON has no word for written as text — and **no file's
//    name, no folder of the host's and no profile's id** in any string, however an error words it.
//    A name in the log is the promise the consent makes, broken.
//  - **the session's file** (`LogStore`): every record in the file once it is flushed, in the order
//    it was noted; a file that fills goes on in a new one that says where it came from and restates
//    the launch; no file past the size one upload takes.
//  - **the keep** (`LogStore.clean`): 7 days, 20 files, 16 MB, the oldest first.
//  - **how the session before ended** (`LogStore.ending`): left, or ended while in use, and which
//    job it was in the middle of — the one thing a host's memory kill leaves behind.
//  - **what is due** (`LogBook`, `LogShipper`, against a server of this file's own): a file with
//    more than was sent, the oldest first; the session being written only when asked; a server that
//    cannot be reached leaves everything due; one that refuses the key stops the run; nothing sent
//    twice; the request is the one `server/logs` takes.
//  - **the zip** (`LogBundle`): every session's file, the summary and the read-me, byte for byte as
//    `unzip` reads them back.
//
//  Compiled with `Sources/Diagnostics/Log{Store,Shipping,Bundle}.swift` alone, in a folder of its
//  own under the temporary files.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a
//  rule broken on purpose, one at a time, and requires each run to fail.

import Foundation

/// The rules under test, so a broken one can be put in their place.
struct Rules {
    var name = "the app's"
    var line: (Date, LogLevel, LogCategory, String, [String: Any]) -> Data = { LogStore.line(at: $0, $1, $2, $3, $4) }
    var scrub: (String) -> String = { LogScrub.clean($0) }
    var clean: (URL, LogStore.Limits, Date) -> [String] = { LogStore.clean($0, limits: $1, now: $2, keeping: nil) }
    var ending: (URL) -> LogStore.Ending? = { LogStore.ending(of: $0) }
    var due: ([(session: String, bytes: Int64)], [String: Int64], String?, Bool) -> [String] = {
        LogBook.due($0, sent: $1, current: $2, includingCurrent: $3)
    }
    /// The limits a store is made with.
    var limits: (LogStore.Limits) -> LogStore.Limits = { $0 }
    /// The status a run of the shipper sees for the status the server gave.
    var seen: (Int) -> Int = { $0 }
    var zip: (URL, URL, Data) throws -> URL = { try LogBundle.write(to: $0, logs: $1, summary: $2) }

    static var broken: [Rules] {
        var all: [Rules] = []
        func rule(_ name: String, _ change: (inout Rules) -> Void) {
            var r = Rules()
            r.name = name
            change(&r)
            all.append(r)
        }
        rule("a string goes into a line as it came") { r in
            r.line = { date, level, category, message, fields in
                var text = "{\"t\":\"\(LogStore.stamp(date))\",\"lvl\":\"\(level.rawValue)\",\"cat\":\"\(category.rawValue)\",\"msg\":\(LogJSON.string(message))"
                for key in fields.keys.sorted() {
                    if let s = fields[key] as? String { text += ",\(LogJSON.string(key)):\(LogJSON.string(s))" }
                    else if let w = LogJSON.write(fields[key]!) { text += ",\(LogJSON.string(key)):\(w)" }
                }
                return Data((text + "}\n").utf8)
            }
            r.scrub = { $0 }
        }
        rule("only a path's file is taken out, not a name in quotes or alone") { r in
            let pathsOnly: (String) -> String = { text in
                let p = try! NSRegularExpression(pattern: "(?<=/)[^/\\n\"']+?\\.(dng|heic|jpe?g|png|tiff?)(?![A-Za-z0-9])", options: [.caseInsensitive])
                return p.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<file>.$1")
            }
            r.scrub = pathsOnly
            r.line = { date, level, category, message, fields in
                var text = "{\"t\":\"\(LogStore.stamp(date))\",\"lvl\":\"\(level.rawValue)\",\"cat\":\"\(category.rawValue)\",\"msg\":\(LogJSON.string(pathsOnly(message)))"
                for key in fields.keys.sorted() {
                    if let s = fields[key] as? String { text += ",\(LogJSON.string(key)):\(LogJSON.string(pathsOnly(s)))" }
                    else if let w = LogJSON.write(fields[key]!) { text += ",\(LogJSON.string(key)):\(w)" }
                }
                return Data((text + "}\n").utf8)
            }
        }
        rule("a profile's id stays as the engine wrote it") { r in
            r.scrub = { text in
                let kept = LogScrub.stockNames
                LogScrub.stockNames = [:]
                defer { LogScrub.stockNames = kept }
                return LogScrub.clean(text)
            }
        }
        rule("a line may be more than one line") { r in
            r.line = { date, level, category, message, fields in
                var data = LogStore.line(at: date, level, category, message, fields)
                if message.contains("\n") { data.insert(0x0A, at: data.count / 2) }
                return data
            }
        }
        rule("a field that is nil is written as null") { r in
            r.line = { date, level, category, message, fields in
                let line = String(decoding: LogStore.line(at: date, level, category, message, fields), as: UTF8.self)
                let nils = fields.keys.sorted().filter { LogJSON.write(fields[$0]!) == nil }
                guard !nils.isEmpty else { return Data(line.utf8) }
                return Data((String(line.dropLast(2)) + nils.map { ",\(LogJSON.string($0)):null" }.joined() + "}\n").utf8)
            }
        }
        rule("old files are kept for ever") { r in
            r.clean = { folder, limits, now in
                var l = limits
                l.days = 100_000
                return LogStore.clean(folder, limits: l, now: now, keeping: nil)
            }
        }
        rule("any number of files is kept") { r in
            r.clean = { folder, limits, now in
                var l = limits
                l.files = .max
                return LogStore.clean(folder, limits: l, now: now, keeping: nil)
            }
        }
        rule("any size is kept") { r in
            r.clean = { folder, limits, now in
                var l = limits
                l.totalBytes = .max
                return LogStore.clean(folder, limits: l, now: now, keeping: nil)
            }
        }
        rule("the newest files go first") { r in
            r.clean = { folder, limits, now in
                let files = LogStore.sessions(in: folder).reversed()
                var gone: [String] = []
                for (i, url) in files.enumerated() where i >= limits.files {
                    try? FileManager.default.removeItem(at: url)
                    gone.append(url.deletingPathExtension().lastPathComponent)
                }
                return gone
            }
        }
        rule("a session's file has no end") { $0.limits = { var l = $0; l.sessionBytes = .max; return l } }
        rule("every session before this one left the app") { r in
            r.ending = { url in LogStore.ending(of: url).map { var e = $0; e.last = "background"; return e } }
        }
        rule("a job begun is a job ended") { r in
            r.ending = { url in LogStore.ending(of: url).map { var e = $0; e.open = []; return e } }
        }
        rule("a job ended is still open") { r in
            r.ending = { url in
                guard var e = LogStore.ending(of: url), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                e.open = text.split(separator: "\n").filter { $0.contains("\"cat\":\"job\"") && $0.contains("\"msg\":\"start\"") }.map { _ in "a job" }
                return e
            }
        }
        rule("what was sent is due again") { $0.due = { files, _, current, including in LogBook.due(files, sent: [:], current: current, includingCurrent: including) } }
        rule("a file that has grown is not due") { r in
            r.due = { files, sent, current, including in
                LogBook.due(files, sent: sent, current: current, includingCurrent: including).filter { sent[$0] == nil }
            }
        }
        rule("the session being written is always sent") { $0.due = { files, sent, current, _ in LogBook.due(files, sent: sent, current: current, includingCurrent: true) } }
        rule("the newest session is sent first") { r in
            r.due = { files, sent, current, including in LogBook.due(files, sent: sent, current: current, includingCurrent: including).reversed() }
        }
        rule("a server that fails has taken the file") { $0.seen = { $0 >= 500 ? 204 : $0 } }
        rule("a refused key reads as a server that fails") { $0.seen = { $0 == 401 ? 500 : $0 } }
        rule("the zip leaves the oldest session out") { r in
            r.zip = { destination, folder, summary in
                let scratch = folder.deletingLastPathComponent().appendingPathComponent("short-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                for url in LogStore.sessions(in: folder).dropLast() {
                    try FileManager.default.copyItem(at: url, to: scratch.appendingPathComponent(url.lastPathComponent))
                }
                return try LogBundle.write(to: destination, logs: scratch, summary: summary)
            }
        }
        rule("the zip's files are cut short") { r in
            r.zip = { destination, folder, summary in
                let scratch = folder.deletingLastPathComponent().appendingPathComponent("cut-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                for url in LogStore.sessions(in: folder) {
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    try data.prefix(max(1, data.count - 1)).write(to: scratch.appendingPathComponent(url.lastPathComponent))
                }
                return try LogBundle.write(to: destination, logs: scratch, summary: summary)
            }
        }
        return all
    }
}

/// A server of this file's own: what it was asked, and what it answers.
final class Server: @unchecked Sendable {
    struct Asked { var path: String; var method: String; var key: String?; var type: String?; var build: String?; var bytes: Int; var body: Data }
    private let lock = NSLock()
    private var asked: [Asked] = []
    private var answers: [Int] = []
    private var fallback = 204
    private var unreachable = false

    var requests: [Asked] { lock.withLock { asked } }
    func answer(_ status: Int) { lock.withLock { fallback = status; answers = [] } }
    /// The next answers, in order; then the standing one.
    func next(_ statuses: [Int]) { lock.withLock { answers = statuses } }
    func cut(_ off: Bool) { lock.withLock { unreachable = off } }
    func forget() { lock.withLock { asked = [] } }

    func transport(seen: @escaping @Sendable (Int) -> Int) -> LogShipper.Transport {
        { [self] request, body in
            lock.withLock {
                if unreachable { return .failure(URLError(.cannotFindHost)) }
                asked.append(Asked(path: request.url?.path ?? "", method: request.httpMethod ?? "",
                                   key: request.value(forHTTPHeaderField: "Authorization"),
                                   type: request.value(forHTTPHeaderField: "Content-Type"),
                                   build: request.value(forHTTPHeaderField: "X-SpektraLab-Build"), bytes: body.count, body: body))
                let status = answers.isEmpty ? fallback : answers.removeFirst()
                return .success(seen(status))
            }
        }
    }
}

func run(_ rules: Rules, quiet: Bool) async -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAILED  \(what)") } }
    }
    let files = FileManager.default
    let ground = files.temporaryDirectory.appendingPathComponent("spk-log-selftest-\(UUID().uuidString)", isDirectory: true)
    try? files.createDirectory(at: ground, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: ground) }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func lines(_ url: URL) -> [[String: Any]] {
        text(url).split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_600_000 + seconds) }

    // MARK: a line

    LogScrub.home = "/var/mobile/Containers/Data/Application/0A1B2C3D-AAAA-BBBB-CCCC-000000000001"
    LogScrub.stockNames = ["kodak_portra_400": "Stock One 400", "ilford_hp5_plus": "Stock Two"]
    defer { LogScrub.stockNames = [:]; LogScrub.home = NSHomeDirectory() }

    let plain = rules.line(at(0.1147), .info, .export, "saved", ["mp": 12.19, "s": 0.94321789, "whole": 48.0, "count": 3,
                                                                "ok": true, "big": UInt64(6_133_000_000), "none": Optional<Int>.none as Any,
                                                                "list": [1, 2, 3], "inner": ["b": 2, "a": "x"]])
    let plainText = String(decoding: plain, as: UTF8.self)
    expect(plainText.hasPrefix("{\"t\":\"") && plainText.hasSuffix("}\n") && plainText.dropLast().split(separator: "\n").count == 1,
           "a record is one line, and ends in a newline")
    let order = ["\"t\":", "\"lvl\":\"info\"", "\"cat\":\"export\"", "\"msg\":\"saved\"", "\"big\":", "\"count\":"].map { plainText.range(of: $0)?.lowerBound }
    expect(order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! },
           "the four fields every line has come first, then its own by name")
    let parsed = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    expect(parsed != nil, "a line reads back as JSON")
    expect((parsed?["mp"] as? Double) == 12.19 && (parsed?["s"] as? Double) == 0.9432 && (parsed?["count"] as? Int) == 3
           && (parsed?["big"] as? UInt64) == 6_133_000_000 && (parsed?["ok"] as? Bool) == true,
           "numbers read back as they were, to four places")
    expect(plainText.contains("\"whole\":48,") || plainText.contains("\"whole\":48}"), "a whole number is written whole")
    expect(plainText.contains("\"ok\":true"), "a truth is true, not 1")
    expect(parsed?["none"] == nil && !plainText.contains("none"), "a field that is nil is left out")
    expect(plainText.contains("\"inner\":{\"a\":\"x\",\"b\":2}") && plainText.contains("\"list\":[1,2,3]"), "a list and a dictionary are written, by name")
    let odd = rules.line(at(1), .warn, .job, "two\nlines \"quoted\" \\ and a tab\t", ["nan": Double.nan, "inf": -Double.infinity,
                                                                                      "id": UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000ABCD")!,
                                                                                      "when": at(2)])
    let oddText = String(decoding: odd, as: UTF8.self)
    let oddParsed = (try? JSONSerialization.jsonObject(with: odd)) as? [String: Any]
    expect(oddText.dropLast().split(separator: "\n", omittingEmptySubsequences: false).count == 1,
           "a message of two lines is still one line")
    expect((oddParsed?["msg"] as? String) == "two\nlines \"quoted\" \\ and a tab\t", "and reads back as it was")
    expect((oddParsed?["nan"] as? String) == "nan" && (oddParsed?["inf"] as? String) == "-inf",
           "a number JSON has no word for is written as text")
    expect((oddParsed?["id"] as? String) == "0a1b2c3d-0000-4000-8000-00000000abcd" && (oddParsed?["when"] as? String).flatMap(LogStore.parse) != nil,
           "an id and a date are written as text")

    // No names: however an error words it.
    let home = LogScrub.home
    let leaks: [(String, [String])] = [
        ("could not open \(home)/Library/Application Support/SpektraLab/Originals/IMG_6535.HEIC", ["IMG_6535", home]),
        ("file:///private\(home)/Library/Application%20Support/SpektraLab/WorkingCopies/0A1B/Holiday in Kyoto 12.dng: no data", ["Holiday", "Kyoto", home]),
        ("The file “Mum’s birthday.JPG” couldn’t be opened because there is no such file.", ["birthday", "Mum"]),
        ("export of 'DSC 0042 final.tiff' failed: -50", ["DSC", "0042"]),
        ("decode SPK_0032.DNG: unsupported", ["SPK_0032"]),
        ("two: a.jpg and /x/y/b c.png", ["a.jpg", "b c"]),
        ("profile kodak_portra_400 missing density curves", ["kodak", "portra"]),
        ("ilford_hp5_plus.json: not found", ["ilford", "hp5"]),
    ]
    for (said, names) in leaks {
        let cleaned = rules.scrub(said)
        expect(names.allSatisfy { !cleaned.localizedCaseInsensitiveContains($0) }, "nothing of \"\(said.suffix(46))\" names a file, a folder or a profile (\(cleaned.suffix(50)))")
        let inLine = String(decoding: rules.line(at(3), .error, .export, said, ["why": said, "deep": ["list": [said]]]), as: UTF8.self)
        expect(names.allSatisfy { !inLine.localizedCaseInsensitiveContains($0) }, "nor does a line that carries it, in its message, a field or a list")
    }
    expect(rules.scrub("could not open \(home)/Library/x.heic").contains("<file>.heic") && rules.scrub("could not open \(home)/Library/x.heic").contains("~/Library"),
           "what is left says a file was there, and of what kind")
    expect(rules.scrub("profile kodak_portra_400 missing").contains("Stock One 400"), "a profile is named as the app shows it")
    for kept in ["bands(1008) x 6, halo 656", "SpektraLab engine 1.4.2 (metal)", "colour negative", "iPhone18,3", "the server answered 503",
                 "v1/logs", "3024x4032", "0.94 s against 1.08 s predicted", "Stock One 400"] {
        expect(rules.scrub(kept) == kept, "\"\(kept)\" is left as it is")
    }

    // MARK: the session's file

    let folder = ground.appendingPathComponent("Logs", isDirectory: true)
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        private var n = 0
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func pass(_ s: Double) { lock.withLock { t = t.addingTimeInterval(s) } }
        func id() -> String { lock.withLock { n += 1; return String(format: "%08x", n) } }
    }
    let clock = Clock(at(0))
    var limits = LogStore.Limits()
    limits.sessionBytes = 2000
    limits = rules.limits(limits)
    let store = LogStore(folder: folder, limits: limits, now: { clock.now }, id: { clock.id() })
    let first = store.current
    expect(LogStore.isSession(first) && first.hasSuffix("-00000001"), "a session is named by its second and eight hex (\(first))")
    expect(!LogStore.isSession("latest") && !LogStore.isSession(first + ".jsonl") && !LogStore.isSession("20261010T044703Z-1A2B3C4D"),
           "and nothing else is a session's name")
    store.restate(["app": "0.1", "build": "7", "machine": "iPhone18,3"])
    store.write(.info, .app, "launch", ["app": "0.1", "build": "7", "machine": "iPhone18,3"])
    for i in 0..<5 { clock.pass(1); store.write(.info, .job, "end", ["id": "job-\(i)", "n": i]) }
    store.flush()
    let firstFile = folder.appendingPathComponent(first + ".jsonl")
    let firstLines = lines(firstFile)
    expect(firstLines.count == 6 && (firstLines.first?["msg"] as? String) == "launch"
           && firstLines.dropFirst().enumerated().allSatisfy { ($0.element["n"] as? Int) == $0.offset },
           "every record is in the file once it is flushed, in the order it was noted (\(firstLines.count) of 6)")
    expect(((try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup) == true, "the folder is kept out of backups")
    // A file that fills goes on in another.
    for i in 0..<40 { clock.pass(1); store.write(.info, .job, "end", ["id": "job-\(i)", "pad": String(repeating: "x", count: 60)]) }
    store.flush()
    let sessions = LogStore.sessions(in: folder)
    let sizes = sessions.map { (try? files.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
    expect(sessions.count > 2, "a session whose file fills goes on in a new one (\(sessions.count) files)")
    expect(sizes.allSatisfy { $0 <= 2000 }, "and no file is past the size one upload takes (\(sizes.max() ?? 0) of 2,000)")
    // The app's own most: what the server takes well inside a request's CPU (LogShipping.swift, "Limits").
    let own = LogStore.Limits()
    expect(own.sessionBytes <= 1 << 20 && Int64(own.lineBytes) < own.sessionBytes,
           "the app's own most for a file is a mebibyte, and a line fits in it (\(own.sessionBytes) bytes, a line \(own.lineBytes))")
    expect(sessions.map(\.lastPathComponent) == sessions.map(\.lastPathComponent).sorted(by: >) && store.current == sessions.first?.deletingPathExtension().lastPathComponent,
           "the files' names are in the order they were written, and the newest is the one in use")
    let all = sessions.reversed().flatMap(lines)
    expect(all.filter { ($0["pad"] as? String) != nil }.count == 40, "nothing is lost where one file ends and the next begins")
    let second = sessions.count > 1 ? lines(sessions[sessions.count - 2]) : []
    expect((second.first?["msg"] as? String) == "continued" && (second.first?["from"] as? String) == first
           && (second.first?["machine"] as? String) == "iPhone18,3" && (second.first?["build"] as? String) == "7",
           "a file the session goes on in says where it came from and restates the launch")
    let huge = LogStore(folder: ground.appendingPathComponent("Huge", isDirectory: true), limits: rules.limits(LogStore.Limits()),
                        now: { clock.now }, id: { clock.id() })
    huge.write(.info, .system, "metrics", ["payload": String(repeating: "y", count: 600_000)])
    huge.flush()
    let hugeLines = lines(LogStore.sessions(in: ground.appendingPathComponent("Huge", isDirectory: true)).first ?? ground)
    expect(hugeLines.count == 1 && hugeLines.first?["payload"] == nil && ((hugeLines.first?["dropped_bytes"] as? Int) ?? 0) > 600_000,
           "a record past a line's most is noted by its size alone")

    // MARK: the keep

    func plant(_ folder: URL, _ day: Double, _ bytes: Int, _ n: Int) -> String {
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = LogStore.name(at(day * 86_400), String(format: "%08x", n))
        let url = folder.appendingPathComponent(name + ".jsonl")
        files.createFile(atPath: url.path, contents: Data(repeating: 0x20, count: bytes))
        try? files.setAttributes([.modificationDate: at(day * 86_400)], ofItemAtPath: url.path)
        return name
    }
    func kept(_ folder: URL) -> Set<String> { Set(LogStore.sessions(in: folder).map { $0.deletingPathExtension().lastPathComponent }) }
    let keepLimits = LogStore.Limits(days: 7, files: 5, totalBytes: 10_000, sessionBytes: 1 << 20, lineBytes: 512 << 10)
    let aged = ground.appendingPathComponent("Aged", isDirectory: true)
    let ancient = plant(aged, 0, 100, 1), week = plant(aged, 2.5, 100, 2), recent = plant(aged, 9, 100, 3)
    try? Data("{}".utf8).write(to: aged.appendingPathComponent(LogBook.fileName))
    let goneByAge = rules.clean(aged, keepLimits, at(9.4 * 86_400))
    expect(kept(aged) == [week, recent] && goneByAge == [ancient], "a file not written for 7 days goes, and one written since stays")
    expect(files.fileExists(atPath: aged.appendingPathComponent(LogBook.fileName).path), "what is not a session's file is not the keep's to take")
    let many = ground.appendingPathComponent("Many", isDirectory: true)
    let numbered = (0..<8).map { plant(many, 10 + Double($0) * 0.01, 100, $0 + 1) }
    _ = rules.clean(many, keepLimits, at(10.2 * 86_400))
    expect(kept(many) == Set(numbered.suffix(5)), "past 20 files (5 here) the oldest go (\(kept(many).count) kept)")
    let heavy = ground.appendingPathComponent("Heavy", isDirectory: true)
    let weights = [(1, 4000), (2, 4000), (3, 4000), (4, 300)].map { plant(heavy, 10 + Double($0.0) * 0.01, $0.1, $0.0) }
    _ = rules.clean(heavy, keepLimits, at(10.2 * 86_400))
    expect(kept(heavy) == Set(weights.suffix(3)), "past the size, the oldest go until what is left fits (\(kept(heavy).count) kept)")
    let alone = ground.appendingPathComponent("Alone", isDirectory: true)
    let only = plant(alone, 10, 50_000, 1)
    _ = rules.clean(alone, keepLimits, at(10.1 * 86_400))
    expect(kept(alone) == [only], "the newest file stays whatever its size")

    // MARK: how the session before ended

    func session(_ name: String, _ records: [(LogCategory, String, [String: Any])]) -> URL {
        let dir = ground.appendingPathComponent("Endings", isDirectory: true)
        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".jsonl")
        var data = Data()
        for (i, r) in records.enumerated() { data.append(LogStore.line(at: at(Double(i)), .info, r.0, r.1, r.2)) }
        try? data.write(to: url)
        return url
    }
    let left = rules.ending(session("20261010T000000Z-0000000a", [(.app, "launch", [:]), (.app, "active", [:]),
        (.job, "start", ["id": "a", "kind": "canvas", "tier": "preview", "mp": 4.3]), (.job, "end", ["id": "a"]),
        (.app, "inactive", [:]), (.app, "background", [:])]))
    expect(left?.last == "background" && left?.inUse == false && left?.open == [] && left?.at == at(5),
           "a session that left the app ended at rest, with no job open")
    let killed = rules.ending(session("20261010T000000Z-0000000b", [(.app, "launch", [:]), (.app, "active", [:]),
        (.job, "start", ["id": "a", "kind": "canvas", "tier": "preview", "mp": 4.3]), (.job, "end", ["id": "a"]),
        (.job, "start", ["id": "b", "kind": "export", "tier": "full", "mp": 48.77])]))
    expect(killed?.last == "active" && killed?.inUse == true, "a session that stops while the app is in front was ended in use")
    expect(killed?.open == ["export full 48.8 MP"], "and the job it was in the middle of is named (\(killed?.open ?? []))")
    let back = rules.ending(session("20261010T000000Z-0000000c", [(.app, "launch", [:]), (.app, "active", [:]), (.app, "background", [:]),
        (.app, "active", [:]), (.export, "saved", ["mp": 12])]))
    expect(back?.inUse == true && back?.last == "active", "a session that came back to the front and stopped there was ended in use")
    let swiped = rules.ending(session("20261010T000000Z-0000000d", [(.app, "launch", [:]), (.app, "active", [:]), (.app, "inactive", [:]), (.app, "terminate", [:])]))
    expect(swiped?.inUse == false && swiped?.last == "terminate", "one the user ended from the switcher was not")
    expect(rules.ending(ground.appendingPathComponent("no-such-file.jsonl")) == nil, "a file that is not there has no ending")
    // The next launch says it in its own file.
    let after = LogStore(folder: ground.appendingPathComponent("Endings", isDirectory: true), limits: LogStore.Limits(),
                         now: { at(600) }, id: { "000000ff" })
    after.write(.info, .app, "launch", [:])
    after.flush()
    let said = lines(ground.appendingPathComponent("Endings/\(after.current).jsonl"))
    expect((said.first?["msg"] as? String) == "previous" && (said.first?["session"] as? String) == "20261010T000000Z-0000000d"
           && (said.first?["in_use"] as? Bool) == false && (said.last?["msg"] as? String) == "launch",
           "a launch's file begins with how the session before it ended")

    // MARK: what is due, and the sending

    let shelf: [(session: String, bytes: Int64)] = [("20261010T000003Z-0000000c", 300), ("20261010T000001Z-0000000a", 100),
                                                    ("20261010T000002Z-0000000b", 200), ("20261010T000004Z-0000000d", 0)]
    expect(rules.due(shelf, [:], "20261010T000003Z-0000000c", true) == ["20261010T000001Z-0000000a", "20261010T000002Z-0000000b", "20261010T000003Z-0000000c"],
           "everything with a byte in it is due, the oldest first")
    expect(rules.due(shelf, [:], "20261010T000003Z-0000000c", false) == ["20261010T000001Z-0000000a", "20261010T000002Z-0000000b"],
           "the session being written is due only when it is asked for")
    expect(rules.due(shelf, ["20261010T000001Z-0000000a": 100, "20261010T000002Z-0000000b": 150], nil, true)
           == ["20261010T000002Z-0000000b", "20261010T000003Z-0000000c"], "a file sent whole is not due; one that has grown since is")

    let outbox = ground.appendingPathComponent("Outbox", isDirectory: true)
    try? files.createDirectory(at: outbox, withIntermediateDirectories: true)
    func put(_ name: String, _ body: String) { try? Data(body.utf8).write(to: outbox.appendingPathComponent(name + ".jsonl")) }
    let a = "20261010T000001Z-0000000a", b = "20261010T000002Z-0000000b", c = "20261010T000003Z-0000000c"
    put(a, "{\"a\":1}\n"); put(b, "{\"b\":1}\n{\"b\":2}\n"); put(c, "{\"c\":1}\n")
    let server = Server()
    let endpoint = LogEndpoint(base: URL(string: "https://logs.example.test")!, key: "k-123")
    let install = "0a1b2c3d-0000-4000-8000-00000000abcd"
    let shipper = LogShipper(folder: outbox, endpoint: endpoint, build: "0.1 (7)", transport: server.transport(seen: rules.seen))

    server.cut(true)
    let offline = await shipper.ship(install: install, current: c, includingCurrent: true)
    expect(offline == .later("host not found (-1003)") && LogBook.read(outbox).sent.isEmpty,
           "a server that cannot be reached is said so, and everything stays due (\(offline))")
    server.cut(false)

    let launch = await shipper.ship(install: install, current: c, includingCurrent: false)
    let asked = server.requests
    expect(launch == .sent(files: 2, bytes: 24) && asked.map(\.path) == ["/v1/logs/\(install)/\(a)", "/v1/logs/\(install)/\(b)"],
           "at launch the sessions before this one are sent, the oldest first (\(launch))")
    expect(asked.allSatisfy { $0.method == "PUT" && $0.key == "Bearer k-123" && $0.type == "application/x-ndjson" && $0.build == "0.1 (7)" },
           "each as the server takes it: PUT, the key, the type, the build")
    expect(asked.first?.body == Data("{\"a\":1}\n".utf8), "and the body is the file's bytes as they are")
    server.forget()
    let again = await shipper.ship(install: install, current: c, includingCurrent: false)
    expect(again == .sent(files: 0, bytes: 0) && server.requests.isEmpty, "what was sent is not sent again")
    put(b, "{\"b\":1}\n{\"b\":2}\n{\"b\":3}\n")
    let leaving = await shipper.ship(install: install, current: c, includingCurrent: true)
    expect(leaving == .sent(files: 2, bytes: 32) && server.requests.map(\.path) == ["/v1/logs/\(install)/\(b)", "/v1/logs/\(install)/\(c)"]
           && server.requests.first?.bytes == 24, "a file that has grown is sent again whole, and on leaving the session being written goes too")

    server.forget()
    put(a, "{\"a\":1}\n{\"a\":2}\n"); put(b, "{\"b\":1}\n{\"b\":2}\n{\"b\":3}\n{\"b\":4}\n")
    server.next([503])
    let failing = await shipper.ship(install: install, current: nil, includingCurrent: true)
    expect(failing == .later("the server answered 503") && server.requests.count == 1 && LogBook.read(outbox).sent[a] == 8,
           "a server that fails stops the run, and the file is still due (\(failing))")
    server.forget()
    server.answer(401)
    let refused = await shipper.ship(install: install, current: nil, includingCurrent: true)
    expect(refused == .refused(401) && server.requests.count == 1, "a server that refuses the key is asked once, not once a file (\(server.requests.count))")
    server.forget()
    server.answer(204)
    server.next([413])
    let tooLarge = await shipper.ship(install: install, current: nil, includingCurrent: true)
    expect(tooLarge == .sent(files: 1, bytes: 32) && server.requests.count == 2 && LogBook.read(outbox).sent[a] == 16,
           "a file the server will not take as it is does not hold the others back, and is not asked again until it has more")
    try? files.removeItem(at: outbox.appendingPathComponent(a + ".jsonl"))
    _ = await shipper.ship(install: install, current: nil, includingCurrent: true)
    expect(LogBook.read(outbox).sent[a] == nil && LogBook.read(outbox).sent[b] == 32, "a session whose file is gone is forgotten with it")

    let info: [String: Any] = ["SPKLogsURL": " https://logs.spektralab.app ", "SPKLogsKey": "abc"]
    expect(LogEndpoint.bundled(info) == LogEndpoint(base: URL(string: "https://logs.spektralab.app")!, key: "abc"), "a build's server is read from its Info.plist")
    expect(LogEndpoint.bundled(["SPKLogsURL": "", "SPKLogsKey": "abc"]) == nil && LogEndpoint.bundled(["SPKLogsURL": "https://logs.spektralab.app"]) == nil
           && LogEndpoint.bundled(["SPKLogsURL": "http://logs.spektralab.app", "SPKLogsKey": "abc"]) == nil && LogEndpoint.bundled([:]) == nil,
           "a build given no server, no key, or one that is not https, has none")
    let request = endpoint.request(install: install, session: a, build: String(repeating: "b", count: 100))
    expect(request.url?.absoluteString == "https://logs.example.test/v1/logs/\(install)/\(a)" && request.value(forHTTPHeaderField: "X-SpektraLab-Build")?.count == 64
           && request.allowsConstrainedNetworkAccess == false, "the request is the server's, the build cut to what it keeps, and Low Data Mode honoured")

    // MARK: the zip

    let summary = Data("{\"app\":\"0.1\",\"build\":\"7\"}".utf8)
    let zipURL = ground.appendingPathComponent("out/" + LogBundle.fileName(at(0)))
    expect(LogBundle.fileName(at(0)).hasPrefix("SpektraLab-log-") && LogBundle.fileName(at(0)).hasSuffix(".zip"), "the zip is named for what it is")
    let made = try? rules.zip(zipURL, outbox, summary)
    expect(made != nil && files.fileExists(atPath: zipURL.path), "the zip is written")
    let unzipped = ground.appendingPathComponent("unzipped", isDirectory: true)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", "-o", zipURL.path, "-d", unzipped.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try? unzip.run()
    unzip.waitUntilExit()
    expect(unzip.terminationStatus == 0, "unzip reads it without complaint")
    expect((try? Data(contentsOf: unzipped.appendingPathComponent("summary.json"))) == summary
           && text(unzipped.appendingPathComponent("README.txt")) == LogBundle.readme, "the summary and the read-me are in it as they were given")
    let inZip = Set(((try? files.contentsOfDirectory(atPath: unzipped.appendingPathComponent("logs").path)) ?? []))
    let onDisk = LogStore.sessions(in: outbox)
    expect(inZip == Set(onDisk.map(\.lastPathComponent)) && !inZip.contains(LogBook.fileName), "every session's file is in it, and nothing else of the folder")
    expect(!onDisk.isEmpty && onDisk.allSatisfy { (try? Data(contentsOf: $0)) == (try? Data(contentsOf: unzipped.appendingPathComponent("logs/" + $0.lastPathComponent))) },
           "byte for byte")
    expect(LogBundle.readme.contains("never in it") && !LogBundle.readme.contains("\t"), "the read-me says what is never in the log")

    return (passed, failed)
}

@main
enum LogSelfTest {
    static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let all = Rules.broken
            for broken in all {
                let r = await run(broken, quiet: true)
                if r.failed.isEmpty {
                    print("  NOT CAUGHT  \(broken.name)")
                } else {
                    caught += 1
                    print("  caught  \(broken.name) (\(r.failed.count) checks failed)")
                }
            }
            print("log checks' own check: \(caught) of \(all.count) broken rules caught")
            exit(caught == all.count ? 0 : 1)
        }
        let r = await run(Rules(), quiet: false)
        print("log checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
