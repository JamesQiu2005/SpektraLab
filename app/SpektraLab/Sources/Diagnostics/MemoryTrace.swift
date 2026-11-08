//  MemoryTrace.swift — when the app's memory is worth a line in the log.
//
//  The beta's first day (2026-10-12) left one question the log could not
//  answer: an reference device ended the app four times in one export, and a
//  48 MP ProRAW shot opened at up to 2.9 GB over a footprint that was already
//  0.8 to 2.1 GB — and the log held memory only inside a job's own record,
//  which a job that never ends does not leave. The owner, that evening: "a
//  moderately more detailed log system including the ram usage from
//  testers in the next version".
//
//  So the app's footprint is read four times a second while it is in front
//  (`MemoryLog`), and this is the rule for which readings become records:
//
//  - **a rise**: the footprint is `rise` or more over the last one written;
//  - **a fall**: it is `fall` or more under it;
//  - **low**: what is left of the app's allowance has gone under one of
//    `floors` — once a floor, until the allowance has come back to twice it.
//
//  A session at rest writes nothing. One that grows by 1.5 GB a second (the
//  exports of the first day's table (c)) writes a line every reading, each in
//  the file before the next (`LogStore`: every record reaches the file at
//  once), so the last line before the operating system ends the app is within a quarter of a
//  second of the end.
//
//  It also keeps the session's highest footprint and least allowance, with
//  what the app was doing at each, for the record written as the app is left.
//
//  Foundation only: `tools/memory_selftest.swift` checks it on a Mac.

import Foundation

struct MemoryTrace: Equatable, Sendable {
    /// Why a reading is written.
    enum Note: Equatable, Sendable {
        case rise
        case fall
        /// What is left of the allowance is under this many MB.
        case low(Int)

        var name: String {
            switch self {
            case .rise: "rise"
            case .fall: "fall"
            case .low: "low"
            }
        }
    }

    struct Rule: Equatable, Sendable {
        /// Bytes over the last footprint written.
        var rise: UInt64 = 256 << 20
        /// Bytes under it. Wider than `rise`: what comes back is the less urgent news.
        var fall: UInt64 = 512 << 20
        /// MB left of the allowance, the highest first.
        var floors = [2048, 1024, 512, 256, 128]
    }

    var rule = Rule()
    /// The footprint as the log last had it.
    private(set) var written: UInt64?
    /// The floors already said, until the allowance is back at twice each.
    private(set) var said: Set<Int> = []
    private(set) var readings = 0
    private(set) var peak: UInt64 = 0
    private(set) var peakDuring = ""
    private(set) var least = UInt64.max
    private(set) var leastDuring = ""

    /// One reading: what, if anything, the log is owed for it. `during` is
    /// what the app was doing, kept beside a new highest or least.
    mutating func take(footprint: UInt64, left: UInt64, during: String) -> [Note] {
        readings += 1
        if footprint > peak { peak = footprint; peakDuring = during }
        if left < least { least = left; leastDuring = during }
        var notes: [Note] = []
        if let base = written {
            if footprint >= base + rule.rise { notes.append(.rise) }
            else if footprint + rule.fall <= base { notes.append(.fall) }
        }
        let leftMB = Int(left >> 20)
        // The lowest floor gone under that has not been said; the ones above it are said with it.
        if let floor = rule.floors.filter({ leftMB < $0 && !said.contains($0) }).min() {
            notes.append(.low(floor))
            for f in rule.floors where leftMB < f { said.insert(f) }
        }
        said = said.filter { leftMB < 2 * $0 }
        if written == nil || !notes.isEmpty { written = footprint }
        return notes
    }

    /// A record was written for a reason of its own (a mark): rises and falls
    /// are counted from it.
    mutating func wrote(footprint: UInt64) { written = footprint }
}
