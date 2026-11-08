//  SchedulerSignals.swift — the operating system's half of what the scheduler reads.
//
//  RFC-036 §6.2: memory pressure (warning, critical), the memory warning,
//  thermal state and Low Power Mode. Each is an event that re-plans. The
//  frontend's half — the camera, captures in flight, a finger on a control,
//  the scene's phase — is set by the pages themselves on
//  `RenderQueue.frontend`.

import Foundation
import UIKit

@MainActor
final class SchedulerSignals {
    private let pressure: DispatchSourceMemoryPressure
    private var observers: [NSObjectProtocol] = []

    init(scheduler: RenderQueue) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure = source
        source.setEventHandler { [weak scheduler, weak source] in
            guard let source else { return }
            let critical = source.data.contains(.critical)
            MainActor.assumeIsolated { scheduler?.memoryPressure(critical ? .critical : .warning) }
        }
        source.resume()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: .main) { [weak scheduler] _ in
            MainActor.assumeIsolated { scheduler?.memoryPressure(.warning) }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak scheduler] _ in
            MainActor.assumeIsolated { scheduler?.frontend.thermal = Self.thermal() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                            object: nil, queue: .main) { [weak scheduler] _ in
            MainActor.assumeIsolated { scheduler?.frontend.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        scheduler.frontend.thermal = Self.thermal()
        scheduler.frontend.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    deinit {
        pressure.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func thermal() -> FrontendState.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }
}
