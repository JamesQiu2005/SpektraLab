//  LogBundle.swift — the log as one zip, for a hand to send.
//
//  The owner, 2026-10-10: "in case Cloudflare worker is not available in
//  certain region, a log zip in settings is there." Settings › Diagnostics ›
//  *Export Log Zip* makes it and hands it to the system's share sheet; where
//  it goes from there is the user's to say. It is the desktop's diagnostic
//  bundle (RFC-016 §7): "send me your logs" as one action, and a bundle the
//  app makes cannot leave out the file somebody forgot.
//
//      SpektraLab-log-20261010-1247.zip
//        README.txt       what this is, and what is never in it
//        summary.json     this build, this reference device, the app's settings, what was sent
//        logs/*.jsonl     every session's file the host still keeps (7 days)
//
//  No names to take out first, as the desktop's has: this log carries none
//  (`LogStore`).
//
//  `ZipWriter` and `CRC32` are the desktop's own, from
//  `modern_UI/Spektrafilm/Spektrafilm/Diagnostics/DiagnosticBundle.swift`,
//  copied as they are: a store-only zip is a hundred lines of headers, the
//  contents are text and a few megabytes at most, and a deflate of the app's
//  own would be a second thing to get wrong.

import Foundation

enum LogBundle {
    /// "SpektraLab-log-20261010-1247.zip", by this host's clock.
    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "SpektraLab-log-" + f.string(from: date) + ".zip"
    }

    /// What `summary.json` holds: what was sent is a build with a server's to say alone.
    /// The read-me names no reference device: the same file is written on a window.
    #if SPK_LOG_UPLOAD
    private static let summaryLine = """
      summary.json   this build, this device's model and system, the app's settings,
                     and what has been sent to SpektraLab's server so far
    """
    #else
    private static let summaryLine = """
      summary.json   this build, this device's model and system, the app's settings
    """
    #endif

    static let readme = """
    SpektraLab log

    Made by the app when Export Log Zip was tapped in Settings. Making it sent
    nothing anywhere: this file is the whole of it, and it goes where you send it.

    \(summaryLine)
      logs/          one file for each time the app was opened, for the last 7 days

    What the log holds: the device's model, system and region setting, its memory,
    Low Power Mode and heat; each develop and export with its size, its time and
    the memory it took; the memory the app held and the device had left as the
    app ran, with which page was open and whether the camera was on; the lenses and formats the camera offers, and each shot
    as it is made (its format, its lens, its file's size); the library in numbers
    (how many frames, from where, how much storage, how much of Photos the app
    may read); the films, papers and controls that were used; errors, whether
    the app was ended while in use, and iOS's own performance and crash reports
    for this app. Every line carries the time it was written, with the device's
    offset from UTC.

    What is never in it: a picture, a picture's file name, where a picture was
    taken, when a photograph in the library was taken (only a shot made with the
    app's own camera leaves a line, at the time it is made), a name, an account.

    The logs are newline-delimited JSON, one record a line. Every line begins
    with t (when), lvl (error, warn, info), cat (app, engine, job, export,
    camera, library, develop, upload, system, memory) and msg.
    """

    /// The zip, written to `destination`: every session file in `folder`, the
    /// newest first, with `summary` (JSON) and the read-me.
    @discardableResult
    static func write(to destination: URL, logs folder: URL, summary: Data) throws -> URL {
        var zip = ZipWriter()
        zip.add("README.txt", Data(readme.utf8))
        zip.add("summary.json", summary)
        for file in LogStore.sessions(in: folder) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let written = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            zip.add("logs/" + file.lastPathComponent, data, date: written)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try zip.finish().write(to: destination, options: .atomic)
        return destination
    }
}

// MARK: - a store-only zip (the desktop's)

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
