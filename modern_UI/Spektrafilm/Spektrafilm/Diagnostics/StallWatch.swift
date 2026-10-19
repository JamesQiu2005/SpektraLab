//  StallWatch.swift — what the log says while an engine call takes far too
//  long, and what the Mac was doing meanwhile.
//
//  A 1.3.3 batch of 1,209 102 MP frames rendered each in a steady 7 s, until
//  fifteen frames in one evening stretch took minutes each — one render
//  1,010 s. The log had nothing between the render's start and its end, and
//  nothing about the Mac: whether it slept, ran hot, or was on Low Power Mode.
//  Every duration in it counted sleep as well, so even "how long did it run"
//  could not be answered. These two pieces are what that log was missing.

import AppKit
import Foundation

enum StallWatch {
    /// A render this long is far past any normal one: a 102 MP full render
    /// takes about 7 s on the M2 the batch ran on.
    static let interval: Duration = .seconds(30)

    /// Run `body`, writing a `still running` record every `interval` until it
    /// returns. The engine's calls are synchronous and hold its actor, so the
    /// record is written from a task of its own.
    static func watching<T>(_ op: String, tier: String? = nil, log: Log,
                            every interval: Duration = StallWatch.interval,
                            _ body: () throws -> T) rethrows -> T {
        let wallStart = Date()
        let awakeStart = DispatchTime.now().uptimeNanoseconds
        let watch = Task.detached(priority: .utility) {
            var beat = 0
            while true {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                beat += 1
                var fields: [LogField] = [.init("op", op)]
                if let tier { fields.append(.init("tier", tier)) }
                fields.append(.init("beat", beat))
                fields += elapsed(since: wallStart, awakeSince: awakeStart)
                fields += machineState()
                log.warn(.engine, "still running", fields)
            }
        }
        defer { watch.cancel() }
        return try body()
    }

    /// Wall time and awake time since a start. `DispatchTime` stops while the
    /// Mac sleeps and `Date` does not, so a gap between the two is sleep.
    static func elapsed(since wall: Date, awakeSince awake: UInt64) -> [LogField] {
        [.init("wall_s", Date().timeIntervalSince(wall)),
         .init("awake_s", Double(DispatchTime.now().uptimeNanoseconds &- awake) / 1e9)]
    }

    /// The process's memory and the machine's state, as one record's fields.
    static func machineState() -> [LogField] {
        [.init("mb", Double(MemorySampler.footprintBytes()) / 1e6),
         .init("free_mb", Double(MemorySampler.freeBytes()) / 1e6),
         .init("thermal", thermalName(ProcessInfo.processInfo.thermalState)),
         .init("low_power", ProcessInfo.processInfo.isLowPowerModeEnabled)]
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// The Mac's sleeps and wakes, its display's, its thermal state and Low Power
/// Mode, as `app/system` records — the events a stalled render has to be read
/// against.
@MainActor
final class SystemEvents {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Idempotent: the app starts its diagnostics once, tests more often.
    func start(log: Log) {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "will_sleep"),
            (NSWorkspace.didWakeNotification, "did_wake"),
            (NSWorkspace.screensDidSleepNotification, "screens_sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens_wake"),
        ]
        for (name, event) in events {
            observe(workspace, name, event, log: log)
        }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification, "thermal", log: log)
        observe(.default, .NSProcessInfoPowerStateDidChange, "power_state", log: log)
    }

    func stop() {
        for (centre, token) in observers { centre.removeObserver(token) }
        observers.removeAll()
    }

    private func observe(_ centre: NotificationCenter, _ name: Notification.Name, _ event: String, log: Log) {
        let token = centre.addObserver(forName: name, object: nil, queue: nil) { _ in
            log.info(.app, "system", [.init("event", event)] + StallWatch.machineState())
        }
        observers.append((centre, token))
    }
}
