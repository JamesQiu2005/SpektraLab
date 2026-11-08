//  memory_selftest.swift — which readings of the app's memory the log keeps, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  `MemoryTrace` decides, four times a second, whether a reading of the app's footprint becomes a
//  record (`Sources/Diagnostics/MemoryTrace.swift`). What goes wrong with it goes wrong quietly — a
//  log with no line before the app was ended, or one with a line every quarter second all day — so:
//
//  - a session at rest writes nothing, however long;
//  - the export of the beta's first day (1.5 GB a second, to the end of a 6,144 MB allowance) leaves
//    a line at every reading, and the last one within 256 MB of where it stopped;
//  - a fall is written, and only once it is 512 MB;
//  - each floor of the allowance is said once on the way down, the lowest gone under, and again
//    only after the allowance has come back to twice it;
//  - a mark (`wrote`) is where rises and falls are counted from;
//  - the session's highest footprint and least allowance are kept with what the app was doing.
//
//  Compiled with `Sources/Diagnostics/MemoryTrace.swift` alone.

import Foundation

let MB: UInt64 = 1 << 20

/// The rule under test, so a broken one can be put in its place.
struct Subject {
    var name = "the app's"
    var make: () -> MemoryTrace = { MemoryTrace() }
    /// What a reading is turned into before the trace sees it (a broken reader).
    var footprint: (UInt64) -> UInt64 = { $0 }
    var left: (UInt64) -> UInt64 = { $0 }
    var marks = true

    static var broken: [Subject] {
        var out: [Subject] = []
        var s = Subject(name: "a rise is never written")
        s.make = { var t = MemoryTrace(); t.rule.rise = .max / 2; return t }
        out.append(s)
        s = Subject(name: "every reading is written")
        s.make = { var t = MemoryTrace(); t.rule.rise = 0; return t }
        out.append(s)
        s = Subject(name: "a fall is never written")
        s.make = { var t = MemoryTrace(); t.rule.fall = .max / 2; return t }
        out.append(s)
        s = Subject(name: "no floor is said")
        s.make = { var t = MemoryTrace(); t.rule.floors = []; return t }
        out.append(s)
        s = Subject(name: "the allowance is read as the footprint")
        s.left = { _ in 6144 * MB }
        out.append(s)
        s = Subject(name: "a mark is not counted from")
        s.marks = false
        out.append(s)
        s = Subject(name: "the footprint is read as nothing")
        s.footprint = { _ in 0 }
        out.append(s)
        return out
    }
}

func run(_ s: Subject, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0, failed: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAILED  \(what)") } }
    }
    func take(_ t: inout MemoryTrace, _ footprint: UInt64, _ left: UInt64, _ during: String = "") -> [MemoryTrace.Note] {
        t.take(footprint: s.footprint(footprint), left: s.left(left), during: during)
    }

    // At rest: an hour of readings that wander by less than a step.
    var t = s.make()
    var written = 0
    for i in 0..<(4 * 3600) { written += take(&t, (300 + UInt64(i % 7) * 20) * MB, 5800 * MB).count }
    check(written == 0, "a session at rest writes nothing (\(written) records in an hour)")

    // The first day's export: 1.5 GB a second from 500 MB, until 6,144 MB is gone.
    t = s.make()
    var footprint: UInt64 = 500, lastWritten: UInt64 = 0, records = 0, readings = 0, floors: [Int] = []
    _ = take(&t, footprint * MB, (6144 - footprint) * MB)
    while footprint + 375 < 6144 {
        footprint += 375
        readings += 1
        let notes = take(&t, footprint * MB, (6144 - footprint) * MB, "export full 60.2 MP")
        if !notes.isEmpty { records += 1; lastWritten = footprint }
        for case .low(let f) in notes { floors.append(f) }
    }
    check(records == readings, "a job growing by 1.5 GB a second leaves a line at every reading (\(records) of \(readings))")
    check(footprint - lastWritten < 256, "the last line is within 256 MB of where the app stopped (\(footprint - lastWritten) MB)")
    // The last reading goes under 256 and 128 together: the lower is the one said.
    check(floors == [2048, 1024, 512, 128], "each floor is said once on the way down, the lowest of two gone under together: \(floors)")
    check(t.peak == footprint * MB && t.peakDuring == "export full 60.2 MP", "the session's highest footprint is kept with what ran (\(t.peak / MB) MB, \(t.peakDuring))")
    check(t.least == (6144 - footprint) * MB && t.leastDuring == "export full 60.2 MP", "and its least allowance (\(t.least / MB) MB)")

    // Several floors in one reading: the lowest is the one said, and none of them again.
    t = s.make()
    _ = take(&t, 500 * MB, 5600 * MB)
    let once = take(&t, 5900 * MB, 200 * MB)
    check(once.contains(.low(256)) && !once.contains(.low(2048)), "a fall through four floors at once says the lowest: \(once)")
    check(take(&t, 5910 * MB, 190 * MB).isEmpty, "and says none of them a second time")
    check(take(&t, 6020 * MB, 100 * MB) == [.low(128)], "the floor under it is said when it is reached")
    // Back to rest, and down again: said again.
    _ = take(&t, 500 * MB, 5600 * MB)
    let again = take(&t, 4700 * MB, 1000 * MB)
    check(again.contains(.low(1024)), "a floor is said again after the allowance came back: \(again)")

    // A fall: only once it is 512 MB.
    t = s.make()
    _ = take(&t, 3000 * MB, 3000 * MB)
    check(take(&t, 2600 * MB, 3400 * MB).isEmpty, "a fall of 400 MB is not written")
    check(take(&t, 2400 * MB, 3600 * MB) == [.fall], "a fall of 600 MB is")
    check(take(&t, 2500 * MB, 3500 * MB).isEmpty, "and 100 MB back up from there is not")

    // A mark is where rises are counted from.
    t = s.make()
    _ = take(&t, 500 * MB, 5600 * MB)
    if s.marks { t.wrote(footprint: s.footprint(700 * MB)) }
    check(take(&t, 800 * MB, 5300 * MB).isEmpty, "100 MB over a mark is not a rise, though it is 300 MB over the reading before the mark")
    check(take(&t, 960 * MB, 5100 * MB) == [.rise], "260 MB over the mark is")
    return (passed, failed)
}

@main
enum MemorySelftest {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let all = Subject.broken
            for broken in all {
                let r = run(broken, quiet: true)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(broken.name)") } else { caught += 1; print("  caught  \(broken.name) (\(r.failed.count) checks failed)") }
            }
            print("memory log checks' own check: \(caught) of \(all.count) broken rules caught")
            exit(caught == all.count ? 0 : 1)
        }
        let r = run(Subject(), quiet: false)
        print("memory log: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
