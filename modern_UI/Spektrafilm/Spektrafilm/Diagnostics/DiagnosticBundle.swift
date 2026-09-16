//  DiagnosticBundle.swift — "send me your logs" as one action.
//
//  RFC-016 §7: one button, one `.zip`, saved where the user chooses, nothing
//  transmitted. It carries the last N log files, the startup `capabilities`
//  JSON, the app and engine versions, the machine block, the current settings,
//  and the last error. It exists because a bundle assembled by the app cannot
//  omit the file the user forgot.
//
//  File names are included by default (§11.3) — this is a single-user desktop
//  app and the paths are the user's own — and the caller offers the untick,
//  which replaces basenames with `frame-0001.NEF` style placeholders
//  consistently across the whole bundle. `fileNamesNote` is the sentence the
//  save panel is supposed to say before it writes anything.
//
//  The zip is written here rather than by `ditto` or `zip`: a subprocess for
//  one archive is a dependency this app does not have anywhere else, and a
//  store-only zip is a hundred lines of header writing. Store-only is also the
//  right choice — the contents are text, the volume is bounded by §4's 100 MB,
//  and a deflate implementation would be a second thing to get wrong.

import Foundation

struct DiagnosticBundle {

    /// The sentence the save panel says before saving (§7). Not decoration:
    /// the untick is a promise about what leaves the machine, and a promise
    /// nobody read is not consent.
    static let fileNamesNote =
        "The bundle includes the file names of the images you worked on. Untick to replace them "
        + "with placeholders throughout — the log is otherwise unchanged."

    struct Inputs: Sendable {
        var logDirectory: URL
        /// How many of the most recent session files to include. The session
        /// being written now is the newest, so it is always one of them —
        /// a partial log is exactly the one a report is about.
        var logFileCount = 5
        var appVersion: String?
        var buildNumber: String?
        var engineVersion: String?
        var capabilitiesJSON: String?
        var lastError: String?
        /// The machine block and the current settings, as the Settings page's
        /// own model reports them.
        var machine: [String: String] = [:]
        var settings: [String: String] = [:]
        /// The previous session's outcome, when one was found (§1.7).
        var previousSession: PreviousSessionReport?
    }

    /// Assemble the bundle at `destination` (a `.zip` the caller has chosen the
    /// path of) and return it. Throws only when the archive cannot be written;
    /// a piece that is missing (no engine yet, no error yet) is simply left out
    /// rather than failing the whole thing.
    @discardableResult
    static func assemble(to destination: URL, includeFileNames: Bool, inputs: Inputs,
                         fileManager: FileManager = .default) throws -> URL {
        var anonymiser = Anonymiser(enabled: !includeFileNames)
        var zip = ZipWriter()

        let files = LogCleanup.logFiles(in: inputs.logDirectory, fileManager: fileManager)
            .prefix(max(0, inputs.logFileCount))
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let body = anonymiser.rewrite(text)
            zip.add("logs/\(file.lastPathComponent)", Data(body.utf8))
        }

        if let json = inputs.capabilitiesJSON {
            zip.add("capabilities.json", Data(json.utf8))
        }

        var summary: [String: Any] = [
            "generated": LogTime.isoString(Date()),
            "app": inputs.appVersion ?? "unknown",
            "build": inputs.buildNumber ?? "unknown",
            "engine": inputs.engineVersion ?? "unknown",
            "machine": inputs.machine,
            "settings": inputs.settings,
            "file_names_included": includeFileNames,
        ]
        if let error = inputs.lastError { summary["last_error"] = error }
        if let previous = inputs.previousSession {
            summary["previous_session"] = [
                "file": previous.file,
                "ended_cleanly": previous.endedCleanly,
                "age_seconds": previous.ageSeconds,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: summary,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            zip.add("summary.json", data)
        }

        var readme = """
        SpektraLab diagnostics

        Written by the app, at the user's request. Nothing here was transmitted
        anywhere: this file is the whole of it.

          logs/            the most recent session logs, newest first
          capabilities.json what the render engine reported about itself
          summary.json     app and engine versions, this machine, current settings,
                           the last error, and whether the previous session exited cleanly

        The logs are newline-delimited JSON: one record per line, first five fields
        are t (when), lvl (error/warn/info/debug/trace), cat (app/engine/open/render/
        export/memory/canvas/error), msg, then whatever that category carries.
        """
        if !includeFileNames {
            readme += "\n\nFile names have been replaced with placeholders. This is cosmetic:\n"
                + "the log otherwise contains no image data, and never has.\n"
        }
        zip.add("README.txt", Data(readme.utf8))

        let data = zip.finish()
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// One pass over a log file: the `frame` and `path` fields are the only
    /// ones that carry a name the user chose (§5.4 — sizes, times, parameters
    /// and file names, never pixels), and the placeholders are assigned from
    /// one map so the same frame keeps the same placeholder in every file of
    /// the bundle.
    struct Anonymiser {
        private let enabled: Bool
        private var mapping: [String: String] = [:]

        init(enabled: Bool) { self.enabled = enabled }

        private static let pattern = try! NSRegularExpression(
            pattern: #""(frame|path)":"([^"]*)""#)

        mutating func rewrite(_ text: String) -> String {
            guard enabled, !text.isEmpty else { return text }
            let ns = text as NSString
            let matches = Self.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            var out = ""
            var cursor = 0
            for match in matches {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let key = ns.substring(with: match.range(at: 1))
                let value = ns.substring(with: match.range(at: 2))
                out += "\"\(key)\":\"" + placeholder(for: value) + "\""
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            return out
        }

        /// `frame-0001.ARW` — the RFC's example, keeping the extension so a
        /// reader can still tell a RAW from a TIFF.
        private mutating func placeholder(for value: String) -> String {
            let name = (value as NSString).lastPathComponent
            guard !name.isEmpty else { return value }
            let ext = (name as NSString).pathExtension
            if let existing = mapping[name] { return existing }
            let placeholder = "frame-" + String(format: "%04d", mapping.count + 1)
                + (ext.isEmpty ? "" : ".\(ext)")
            mapping[name] = placeholder
            return placeholder
        }
    }
}

// MARK: - a store-only zip

/// ZIP with no compression: local file headers, a central directory, an end
/// record. Enough for every tool that matters (Finder, `unzip`, `ditto`) and
/// small enough to read in one sitting.
struct ZipWriter {
    private struct Entry {
        var name: String
        var crc: UInt32
        var size: Int
        var offset: Int
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private var body = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ contents: Data, date: Date = Date()) {
        let offset = body.count
        let (dosTime, dosDate) = ZipWriter.dosStamp(date)
        let crc = CRC32.checksum(contents)
        let nameBytes = Data(name.utf8)

        body.appendUInt32(0x0403_4b50)        // local file header
        body.appendUInt16(20)                 // version needed
        body.appendUInt16(0x0800)             // UTF-8 names
        body.appendUInt16(0)                  // stored
        body.appendUInt16(dosTime)
        body.appendUInt16(dosDate)
        body.appendUInt32(crc)
        body.appendUInt32(UInt32(contents.count))
        body.appendUInt32(UInt32(contents.count))
        body.appendUInt16(UInt16(nameBytes.count))
        body.appendUInt16(0)                  // extra
        body.append(nameBytes)
        body.append(contents)

        entries.append(Entry(name: name, crc: crc, size: contents.count,
                             offset: offset, dosTime: dosTime, dosDate: dosDate))
    }

    mutating func finish() -> Data {
        var out = body
        let directoryOffset = out.count
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            out.appendUInt32(0x0201_4b50)     // central directory header
            out.appendUInt16(20)              // version made by
            out.appendUInt16(20)              // version needed
            out.appendUInt16(0x0800)
            out.appendUInt16(0)
            out.appendUInt16(entry.dosTime)
            out.appendUInt16(entry.dosDate)
            out.appendUInt32(entry.crc)
            out.appendUInt32(UInt32(entry.size))
            out.appendUInt32(UInt32(entry.size))
            out.appendUInt16(UInt16(nameBytes.count))
            out.appendUInt16(0)               // extra
            out.appendUInt16(0)               // comment
            out.appendUInt16(0)               // disk
            out.appendUInt16(0)               // internal attributes
            out.appendUInt32(0)               // external attributes
            out.appendUInt32(UInt32(entry.offset))
            out.append(nameBytes)
        }
        let directorySize = out.count - directoryOffset
        out.appendUInt32(0x0605_4b50)         // end of central directory
        out.appendUInt16(0)
        out.appendUInt16(0)
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt32(UInt32(directorySize))
        out.appendUInt32(UInt32(directoryOffset))
        out.appendUInt16(0)
        return out
    }

    /// MS-DOS's packed date and time: seconds are two-second units and the year
    /// starts at 1980, because that is what the format says.
    static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }
}

/// The standard CRC-32 (reflected, polynomial `0xEDB88320`), by the byte.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
