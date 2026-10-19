//  ExportStabilityTests.swift — what a long unattended batch needs from the
//  app that a single export does not.
//
//  A 1.3.3 user exported 1,209 102 MP frames in one eight-hour run. Each
//  rendered in a steady 7 s, except eight in one two-hour stretch of the
//  evening that took 200 to 1,010 s — a 1 s reprint among them — with no
//  more memory pressure than in the hours either side, and nothing holding
//  off App Nap or idle sleep.

import AppKit
import IOKit.pwr_mgt
import XCTest

@MainActor
final class ExportStabilityTests: XCTestCase {
    /// A batch holds off idle sleep for as long as it runs, and lets go when
    /// it ends — asked of the power manager, which is what decides, rather
    /// than of the token the session keeps.
    func testABatchExportHoldsOffIdleSleepUntilItEnds() async throws {
        let s = Session()
        let before = idleSleepAssertions()

        s.batchExporting = true
        try await waitUntil("the power manager to see the batch", timeout: 5) {
            self.idleSleepAssertions() > before
        }

        s.batchExporting = false
        try await waitUntil("the batch to let go", timeout: 5) {
            self.idleSleepAssertions() == before
        }
        XCTAssertNil(s.exportActivity)
    }

    /// An engine call that runs far too long says so while it runs, with the
    /// Mac's state — and stops saying so when it returns. The batch's
    /// 1,010 s render had nothing in the log between its start and its end.
    func testAStalledEngineCallIsLoggedWhileItRuns() async throws {
        let log = Log(ringCapacity: Log.defaultRingCapacity)
        let stillRunning = { log.records().filter { $0.message == "still running" } }

        let answer = StallWatch.watching("render", tier: "full", log: log, every: .milliseconds(50)) {
            Thread.sleep(forTimeInterval: 0.3)
            return 42
        }
        XCTAssertEqual(answer, 42)
        let during = stillRunning()
        XCTAssertGreaterThanOrEqual(during.count, 2, "a stalled call left nothing in the log")
        let fields = Set(during.first?.fields.map(\.name) ?? [])
        XCTAssertTrue(["op", "tier", "beat", "wall_s", "awake_s", "mb", "free_mb", "thermal", "low_power"]
            .allSatisfy(fields.contains), "missing fields: \(fields)")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(stillRunning().count, during.count, "the watch went on after the call returned")
    }

    /// The Mac's sleeps and wakes reach the log, so a stall can be read
    /// against them.
    func testSleepAndWakeAreLogged() {
        let log = Log(ringCapacity: Log.defaultRingCapacity)
        let events = SystemEvents()
        events.start(log: log)
        defer { events.stop() }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let wakes = log.records().filter {
            $0.message == "system" && $0.fields.contains { $0.name == "event" && $0.value == .string("did_wake") }
        }
        XCTAssertEqual(wakes.count, 1)

        events.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(log.records().filter { $0.message == "system" }.count, 1, "stop left an observer")
    }

    /// A batch renders each frame at full size once, for the file. The
    /// canvas's own full-size render and its native original — work for a
    /// person looking at the frame — wait until the run is over, and are then
    /// made for the frame it leaves open. In the 1,209-frame log every frame
    /// ran three full-size renders where the file needed one.
    func testABatchLeavesTheCanvasRendersUntilItEnds() async throws {
        let url = try rawFrame()
        let s = Session()
        // Asked for, not made: whether the original is then rendered is the
        // memory arena's call on this machine's free memory, which a test
        // cannot hold still. The ask is logged before that check.
        let asks = { s.log.records().filter { $0.message == "native original trigger" }.count }
        let asksBefore = asks()
        s.open(urls: [url])
        s.batchExporting = true
        try await waitUntil("the frame to decode", timeout: 120) { s.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { s.serviceReady }
        let sid = await s.ensureDeveloped()
        XCTAssertNotNil(sid, "the frame did not develop")
        try await Task.sleep(for: .milliseconds(Session.fullRenderDebounceMs + 500))
        XCTAssertFalse(s.fullPending, "the canvas rendered at full size during the batch")
        XCTAssertFalse(s.renderer.showsFullRender)
        XCTAssertEqual(asks(), asksBefore, "the native original was asked for during the batch")

        s.batchExporting = false
        try await waitUntil("the canvas's full-size render", timeout: 60) {
            s.renderer.showsFullRender && !s.fullPending
        }
        XCTAssertEqual(asks(), asksBefore + 1, "the open frame's original was not asked for")
    }

    /// A copy of the A7 III RAW (24 MP, past the preview edge) in a folder of
    /// its own: a develop writes a sidecar.
    private func rawFrame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "the A7 III frame is not here")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// This process's assertions that keep the Mac from idle-sleeping.
    private func idleSleepAssertions() -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return 0 }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.filter {
            ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleSystemSleep
        }.count
    }

    private func waitUntil(_ what: String, timeout: TimeInterval,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
