//  SettingsWindow.swift — SpektraLab ▸ Settings… (⌘,).
//
//  RFC-016 §6 specifies a diagnostics column and names the controls it needs
//  to exist. This is that page, plus the two render settings that were
//  already settable in code and had nowhere to be set from (the preview
//  resolution, which `Session.setPreviewLongEdge` has always accepted, and
//  the fast stock preview).
//
//  Two rules this page follows, both from the RFC:
//
//  - **Every number it shows comes from the same place the log does.** The
//    memory readout reads `Diagnostics.memory`, which is the `memory` sampler
//    the log records from — not a second call to `phys_footprint`. §8's "the
//    memory numbers are the same numbers" is only checkable because there is
//    one source, and a page that sampled on its own would make that check
//    pass while the claim it stands for quietly stopped being true.
//  - **A control that costs something says so where it is.** Per-node GPU
//    timings give up the batching the engine depends on; that context remains
//    available as hover help while the page keeps its controls compact.
//
//  Visually this is the app's right panel: `PanelSection` headers, `Well`
//  grounds, `Theme` tokens, no literal colours. Not an AppKit-standard
//  preferences window, because the rest of the interface is not one either.

import AppKit
import SwiftUI

struct SettingsWindow: View {
    @Bindable var session: Session
    /// The observable the RFC-016 work put the settings on. Read directly
    /// rather than copied into `@State`: a copy is a second source of truth,
    /// and the whole point of §8.5 is that there is one.
    private var diagnostics: Diagnostics { Diagnostics.shared }

    @State private var bundleResult: String?
    @State private var savingBundle = false
    /// The memory readout refreshes while the page is open and stops when it
    /// closes. A settings page nobody is looking at has no business taking
    /// samples.
    @State private var ticker: Timer?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                renderingSection
                diagnosticsSection
                memorySection
                logsSection
                bundleSection
                machineSection
            }
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 560)
        .background(Theme.card)
        .preferredColorScheme(.dark)
        .onAppear {
            diagnostics.refreshMemory()
            // 2 s: fast enough to watch a render land, slow enough that the
            // page is not itself a load. The sampler's own records are
            // written at boundaries, not on this timer.
            ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { diagnostics.refreshMemory() }
            }
        }
        .onDisappear { ticker?.invalidate(); ticker = nil }
    }

    // MARK: - rendering

    private var renderingSection: some View {
        PanelSection("Rendering", systemImage: "slider.horizontal.3", key: "setRendering") {
            Well {
                VStack(spacing: 4) {
                    PillMenu(label: "Preview", options: Session.previewEdgeChoices,
                             title: { "\($0) px" },
                             selection: Binding(get: { session.previewLongEdge },
                                                set: { session.setPreviewLongEdge($0) }))
                    ToggleRow(label: "Fast stock preview", isOn: $session.fastStockPreview)
                }
            }
        }
    }

    // MARK: - diagnostics

    private var diagnosticsSection: some View {
        PanelSection("Diagnostics", systemImage: "stethoscope", key: "setDiagnostics") {
            Well {
                VStack(spacing: 4) {
                    PillMenu(label: "Log level", options: LogLevelSetting.allCases,
                             title: { $0.label },
                             selection: Binding(get: { diagnostics.level },
                                                set: { diagnostics.level = $0 }))
                    ToggleRow(label: "Per-node GPU timings",
                              isOn: Binding(get: { diagnostics.perNodeGPUTimings },
                                            set: { diagnostics.perNodeGPUTimings = $0 }))
                        .help(Diagnostics.perNodeTimingsNote)
                }
            }
        }
    }

    // MARK: - memory

    /// §6's live readout, and §11.5's override in the one place it can be
    /// taken back. The override is a *standing* permission — granting it from
    /// a warning is easy and forgetting it was granted is easier, so this is
    /// where it is visible and revocable.
    private var memorySection: some View {
        PanelSection("Memory", systemImage: "memorychip", key: "setMemory") {
            Well {
                VStack(alignment: .leading, spacing: 3) {
                    if let m = diagnostics.memory {
                        readout("Footprint", bytes(m.footprintBytes))
                        readout("Session peak", bytes(m.peakBytes))
                        readout("Free", bytes(m.freeBytes))
                    } else {
                        readout("Footprint", "not sampled yet")
                    }
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    // A setting, not a readout — so it lives outside the
                    // `memory` branch above. Inside it, the control would
                    // disappear until the first sample landed, which is
                    // exactly when someone setting up a small machine would
                    // go looking for it.
                    intRow("Reserve", diagnostics.memoryReserveMegabytes, "MB",
                           Diagnostics.memoryReserveRange) {
                        diagnostics.memoryReserveMegabytes = $0
                    }
                    intRow("Working-set cap",
                           diagnostics.memoryCapIsUnlimited
                               ? Diagnostics.defaultMemoryCapMB
                               : diagnostics.memoryCapMegabytes,
                           "MB", Diagnostics.memoryCapRange) {
                        diagnostics.memoryCapMegabytes = $0
                    }
                    .disabled(diagnostics.memoryCapIsUnlimited)
                    ToggleRow(label: "Unlimited",
                              isOn: Binding(get: { diagnostics.memoryCapIsUnlimited },
                                            set: { diagnostics.memoryCapIsUnlimited = $0 }))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    readout("Held by SpektraLab",
                            bytes(UInt64(max(0, diagnostics.arena.totalBytes))),
                            help: arenaBreakdown())
                    readout("Evictable",
                            bytes(UInt64(max(0, diagnostics.arena.evictableBytes))))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    ToggleRow(label: "Allow exceeding the reserve",
                              isOn: Binding(get: { diagnostics.allowOverReserve },
                                            set: { diagnostics.allowOverReserve = $0 }))
                }
            }
        }
    }

    // MARK: - logs

    private var logsSection: some View {
        PanelSection("Logs", systemImage: "doc.text", key: "setLogs") {
            Well {
                VStack(spacing: 4) {
                    intRow("Keep for", diagnostics.retentionDays, "days", 1...365) {
                        diagnostics.retentionDays = $0
                    }
                    intRow("Keep at most", diagnostics.retentionMegabytes, "MB", 10...10_000) {
                        diagnostics.retentionMegabytes = $0
                    }
                    intRow("Keep at most", diagnostics.retentionFiles, "files", 1...500) {
                        diagnostics.retentionFiles = $0
                    }
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    labelled("Destination") {
                        Text(diagnostics.logDirectory.path)
                            .font(Theme.Font.caption).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 16)
                            .background(Theme.field, in: Capsule())
                        Button("Choose…") { chooseLogDirectory() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    }
                    if let f = diagnostics.cleanupFailure { warning(f) }
                    if let f = diagnostics.writeFailure { warning(f) }
                    HStack(spacing: 10) {
                        Button("Reveal in Finder") { diagnostics.revealLogsInFinder() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        Button("Clear logs now") { diagnostics.clearLogsNow() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                            .help("Deletes every log file except this session's.")
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - the bundle

    private var bundleSection: some View {
        PanelSection("Diagnostic bundle", systemImage: "shippingbox", key: "setBundle") {
            Well {
                VStack(spacing: 4) {
                    ToggleRow(label: "Include image file names",
                              isOn: Binding(get: { diagnostics.includeFileNamesInBundle },
                                            set: { diagnostics.includeFileNamesInBundle = $0 }))
                    HStack(spacing: 10) {
                        Button(savingBundle ? "Saving…" : "Save diagnostic bundle…") { saveBundle() }
                            .buttonStyle(.plain).font(Theme.Font.caption)
                            .foregroundStyle(savingBundle ? Theme.dim : Theme.accent)
                            .disabled(savingBundle)
                        Spacer()
                    }
                    if let bundleResult { caption(bundleResult) }
                }
            }
        }
    }

    // MARK: - this machine

    /// §1.1 and §1.7, where a person can read them: which engine is actually
    /// running, and whether the last session ended cleanly. The second is the
    /// only place a hang, a jetsam kill or a panic shows up at all — its
    /// evidence is a *missing* record, so if this page did not say so nothing
    /// would.
    private var machineSection: some View {
        PanelSection("This session", systemImage: "info.circle", key: "setMachine") {
            Well {
                VStack(alignment: .leading, spacing: 3) {
                    readout("App", Diagnostics.bundleInfo.version)
                    readout("Engine", diagnostics.engineVersion ?? "not reported yet")
                    readout("Render core", session.renderCore ?? "not reported yet")
                    readout("Log file", diagnostics.currentLogFile?.lastPathComponent ?? "none")
                    if diagnostics.previousSessionChecked {
                        if let p = diagnostics.previousSession {
                            readout("Last session", p.endedCleanly
                                    ? "ended cleanly"
                                    : "did not end cleanly (\(p.file))")
                            if !p.endedCleanly {
                                caption("That log has no session-end record, which is how a hang, an out-of-memory kill or a crash shows up — the app never got to write one. The file is in the log folder and the diagnostic bundle includes it.")
                            }
                        } else {
                            readout("Last session", "no earlier log")
                        }
                    }
                    if let e = diagnostics.lastError { warning("Last error — " + e) }
                }
            }
        }
    }

    // MARK: - pieces

    private func readout(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(spacing: 0) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.dim)
                .frame(width: 96, alignment: .leading)
            Text(value).font(Theme.Font.caption).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
        }
        .help(help ?? "")
    }

    private func arenaBreakdown() -> String {
        let parts = diagnostics.arena.breakdown().map {
            "\($0.kind): \(bytes(UInt64(max(0, $0.bytes))))"
        }
        return parts.isEmpty ? "No cache or frame allocations registered yet."
                             : parts.joined(separator: "\n")
    }

    /// An integer field with its unit beside it. A stepper rather than a
    /// slider: these are typed numbers with meaningful exact values, and the
    /// clamping lives in `Diagnostics` so a typed value cannot get out of
    /// range from here.
    private func intRow(_ label: String, _ value: Int, _ unit: String,
                        _ range: ClosedRange<Int>, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            Stepper(value: Binding(get: { value }, set: set), in: range) {
                Text("\(value)").font(Theme.Font.value).foregroundStyle(Theme.text)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            Text(unit).font(Theme.Font.caption).foregroundStyle(Theme.dim)
            Spacer()
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            content()
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    /// Bytes as a person reads them. Decimal units, because that is what
    /// Activity Monitor and the `phys_footprint` figures in the RFC use, and
    /// two numbers for the same memory that differ by 7 % is its own bug
    /// report.
    private func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_000_000_000
        return gb >= 1 ? String(format: "%.2f GB", gb)
                       : String(format: "%.0f MB", Double(b) / 1_000_000)
    }

    private func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should SpektraLab write its logs?"
        panel.directoryURL = diagnostics.logDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        diagnostics.logDirectory = url
    }

    private func saveBundle() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SpektraLab-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        // §7: "the bundle dialog says so plainly before saving". The message
        // is the same sentence the checkbox above carries, so what the user
        // agreed to and what the bundle contains cannot differ.
        panel.message = diagnostics.includeFileNamesInBundle
            ? DiagnosticBundle.fileNamesNote
            : "Image file names will be replaced with placeholders throughout."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savingBundle = true
        bundleResult = nil
        Task {
            defer { savingBundle = false }
            do {
                let written = try await diagnostics.saveDiagnosticBundle(to: url)
                bundleResult = "Wrote \(written.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([written])
            } catch {
                bundleResult = "Could not write the bundle: \(error.localizedDescription)"
            }
        }
    }
}
