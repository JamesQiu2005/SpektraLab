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
//    timings give up the batching the engine depends on; the caption under
//    the checkbox is `Diagnostics.perNodeTimingsNote`, and it is the RFC's
//    own sentence rather than a paraphrase that could drift from it. These
//    captions were briefly moved to hover help to make the page more compact;
//    RFC-016 §5.2 says "the Settings toggle must say so in the same
//    sentence", and a tooltip only says it to somebody who already suspected
//    there was something to hover over.
//
//  Visually this is the app's right panel: `PanelSection` headers, rail rows,
//  hairlines and `Theme` tokens, with no second card/well language inside the
//  rail. Not an AppKit-standard
//  preferences window, because the rest of the interface is not one either.
//
//  **Language and Interface are localized, and the diagnostic sections are
//  not.** That is deliberate and it is written down:
//  `design/LOCALIZATION-zh-Hans.md`, last section — "本文件是主编辑器文案规格，
//  不是完整应用语言包；设置、导出页、系统错误的完整本地化留到相应页面工作。"
//  This page is the *control* for the language and the place a reader who has
//  just switched into Chinese arrives, so language and type scale have to be
//  usable in that language; translating the remaining sections (diagnostics, memory
//  readouts, bundle copy, the log notes) is a page-worth of work with its own
//  review, and half a page translated reads worse than either whole state.

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
    @State private var updateStatus: UpdateCheck.Status = .idle
    /// The memory readout refreshes while the page is open and stops when it
    /// closes. A settings page nobody is looking at has no business taking
    /// samples.
    @State private var ticker: Timer?
    @AppStorage(Session.decoupleEffectsKey) private var decoupleEffects = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                languageSection
                appearanceSection
                renderingSection
                diagnosticsSection
                memorySection
                diskCacheSection
                logsSection
                bundleSection
                machineSection
            }
            .padding(.vertical, Theme.Metric.Settings.verticalInset)
        }
        .frame(width: Theme.Metric.Settings.width, height: Theme.Metric.Settings.height)
        .background(Theme.card)
        .preferredColorScheme(.dark)
        .onAppear {
            diagnostics.refreshMemory()
            session.refreshDiskCacheUsage()
            // 2 s: fast enough to watch a render land, slow enough that the
            // page is not itself a load. The sampler's own records are
            // written at boundaries, not on this timer.
            ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    diagnostics.refreshMemory()
                    session.refreshDiskCacheUsage()
                }
            }
        }
        .onDisappear { ticker?.invalidate(); ticker = nil }
    }

    // MARK: - language

    /// First on the page, because it is the control for the thing that changes
    /// every other word on the screen — including the caption under it.
    ///
    /// The menu's three labels come from `LanguageSetting.label(in:)` and not
    /// from `L(_:)`, and the active language is read **once, here, outside the
    /// closure**: `PillMenu` takes a plain `(T) -> String`, so a closure that
    /// reached into main-actor state on its own could not be built in a view's
    /// body without a concurrency error. Reading it outside keeps that closure
    /// a pure function of a captured value.
    private var languageSection: some View {
        let active = Localization.shared.resolved
        return PanelSection(L(.setLanguage), systemImage: "globe", key: "setLanguage") {
            SettingsRows {
                VStack(spacing: 4) {
                    PillMenu(label: L(.setLanguage),
                             options: LanguageSetting.allCases,
                             title: { $0.label(in: active) },
                             selection: Binding(get: { Localization.shared.language },
                                                set: { Localization.shared.language = $0 }))
                    caption(L(.setLanguageCaption))
                }
            }
        }
    }

    // MARK: - appearance

    private var appearanceSection: some View {
        let chinese = Localization.shared.resolved == .simplifiedChinese
        return PanelSection(chinese ? "界面" : "Interface",
                            systemImage: "textformat.size", key: "setAppearance") {
            SettingsRows {
                VStack(spacing: Theme.Metric.Settings.rowSpacing) {
                    PillMenu(label: chinese ? "缩放" : "Scale",
                             options: InterfaceScale.allCases,
                             title: { $0.label },
                             selection: Binding(get: { InterfaceScaleStore.shared.scale },
                                                set: { InterfaceScaleStore.shared.scale = $0 }))
                    caption(chinese
                            ? "同步调整主界面、设置与导出页的字体大小；更改立即生效。"
                            : "Scales type across the editor, Settings and Export. Changes apply immediately.")
                }
            }
        }
    }

    // MARK: - rendering

    private var renderingSection: some View {
        PanelSection("Rendering", systemImage: "slider.horizontal.3", key: "setRendering") {
            SettingsRows {
                VStack(spacing: 4) {
                    PillMenu(label: "Preview", options: Session.previewEdgeChoices,
                             title: { "\($0) px" },
                             selection: Binding(get: { session.previewLongEdge },
                                                set: { session.setPreviewLongEdge($0) }))
                    caption("The resolution every interactive edit renders at. The frame's own resolution is rendered separately once an edit settles, so this trades responsiveness while dragging against nothing in the finished picture. The recorded cost of a reprint on a 45 MP frame is 13.7 ms at 2560 px, and rises roughly with the pixels.")
                    ToggleRow(label: "Fast stock preview", isOn: $session.fastStockPreview)
                    caption("When a print stock is picked, show the LUT applied to the negative already on the canvas instead of waiting for the full reprint. It is the same table, so the preview and the print agree.")
                    ToggleRow(label: "Crop re-maps the frame",
                              isOn: Binding(get: { Session.recalculateEffectsAfterCrop },
                                            set: { Session.recalculateEffectsAfterCrop = $0
                                                   session.recomputeFilmFormat() }))
                    caption("Whether cropping changes the physical scale of grain, halation and glare. Off — the default, and the physically true answer — the crop shows less of the same negative and its grain is the size it always was. On, the cropped rectangle *is* the frame: the Film section's Side Length now describes the crop, so the effects grow with it. This is the setting the Film section's Side Length row is measured against.")
                    ToggleRow(label: "Decouple effects", isOn: $decoupleEffects)
                    caption("Show a strength for each film effect beside its switch — grain, halation and its scatter, DIR couplers, glare — and let grain's sub-layer model be chosen on its own. Every strength is a multiple of what the chosen film would do, so 1 is always that film as modelled. The strengths belong to the frame: turning this off hides the sliders and changes no picture.")
                }
            }
        }
    }

    // MARK: - diagnostics

    private var diagnosticsSection: some View {
        PanelSection("Diagnostics", systemImage: "stethoscope", key: "setDiagnostics") {
            SettingsRows {
                VStack(spacing: 4) {
                    PillMenu(label: "Log level", options: LogLevelSetting.allCases,
                             title: { $0.label },
                             selection: Binding(get: { diagnostics.level },
                                                set: { diagnostics.level = $0 }))
                    caption(diagnostics.level.detail)
                    ToggleRow(label: "Per-node GPU timings",
                              isOn: Binding(get: { diagnostics.perNodeGPUTimings },
                                            set: { diagnostics.perNodeGPUTimings = $0 }))
                    // Visible, not hover help. RFC-016 §5.2 is specific: "the
                    // Settings toggle must say so in the same sentence". A
                    // tooltip is not the toggle saying so — it is the toggle
                    // saying so to whoever already suspected there was
                    // something to hover over.
                    caption(Diagnostics.perNodeTimingsNote)
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
            SettingsRows {
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
                    caption(Diagnostics.memoryReserveNote)
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
                    caption(Diagnostics.memoryCapNote)
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
                    caption("A frame whose projected peak does not leave the reserve free gets a warning you can override. Nothing is ever blocked; this is the standing answer to that warning, and turning it off makes the app ask again.")
                }
            }
        }
    }

    // MARK: - disk cache

    /// The disk half of what the app holds, and until now the half nobody
    /// could see. `DiskCacheStore` has always evicted — against a 16 GB
    /// constant compiled into it, which is not the same as being managed: no
    /// readout, no control, and no line in the session record. This section is
    /// the readout and the control; `Diagnostics.diskCacheCapMegabytes` is the
    /// line in the record.
    ///
    /// It sits under Memory rather than under Logs because it answers the same
    /// question — what is SpektraLab holding, and what may it hold — for the
    /// other kind of storage. The unit differs and so does the consequence:
    /// over the memory cap the app evicts to keep working, over this one it
    /// evicts to stop growing.
    private var diskCacheSection: some View {
        PanelSection("Disk cache", systemImage: "internaldrive", key: "setDiskCache") {
            SettingsRows {
                VStack(alignment: .leading, spacing: 3) {
                    if session.hasDiskCache {
                        readout("In use", "\(bytes(session.diskCacheBytes)) of "
                                          + "\(bytes(diagnostics.diskCacheCapBytes))")
                    } else {
                        readout("In use", "the cache could not be opened")
                    }
                    intRow("Limit", diagnostics.diskCacheCapMegabytes / 1_000, "GB",
                           Diagnostics.diskCacheCapGigabyteRange) {
                        diagnostics.diskCacheCapMegabytes = $0 * 1_000
                    }
                    caption(Diagnostics.diskCacheCapNote)
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    labelled("Location") {
                        Text(Session.diskCacheRoot.path)
                            .font(Theme.Font.caption).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 16)
                            .background(Theme.field, in: Capsule())
                    }
                    HStack(spacing: 10) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Session.diskCacheRoot])
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        Button("Empty cache now") {
                            session.clearDiskCacheNow()
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption)
                        .foregroundStyle(session.hasDiskCache ? Theme.accent : Theme.dim)
                        .disabled(!session.hasDiskCache)
                        .help("Deletes every cached decode and print. Nothing of yours is in it.")
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - logs

    private var logsSection: some View {
        PanelSection("Logs", systemImage: "doc.text", key: "setLogs") {
            SettingsRows {
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
                    caption("Whichever limit is reached first wins, oldest file first. Cleaning runs at launch, never during a render.")
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
                    caption(Diagnostics.logDirectoryNote)
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
            SettingsRows {
                VStack(spacing: 4) {
                    ToggleRow(label: "Include image file names",
                              isOn: Binding(get: { diagnostics.includeFileNamesInBundle },
                                            set: { diagnostics.includeFileNamesInBundle = $0 }))
                    caption(DiagnosticBundle.fileNamesNote)
                    HStack(spacing: 10) {
                        Button(savingBundle ? "Saving…" : "Save diagnostic bundle…") { saveBundle() }
                            .buttonStyle(.plain).font(Theme.Font.caption)
                            .foregroundStyle(savingBundle ? Theme.dim : Theme.accent)
                            .disabled(savingBundle)
                        Spacer()
                    }
                    caption("One zip: the recent log files, the engine's capabilities, the app and engine versions, this machine, the current settings and the last error. Nothing is transmitted — it is written where you choose.")
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
            SettingsRows {
                VStack(alignment: .leading, spacing: 3) {
                    readout("App", Diagnostics.bundleInfo.version)
                    readout("Engine", diagnostics.engineVersion ?? "not reported yet")
                    readout("Render core", session.renderCore ?? "not reported yet")
                    readout("Log file", diagnostics.currentLogFile?.lastPathComponent ?? "none")
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    HStack(spacing: 10) {
                        Button(updateStatus == .checking ? "Checking…" : "Check for updates") {
                            checkForUpdates()
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption)
                        .foregroundStyle(updateStatus == .checking ? Theme.dim : Theme.accent)
                        .disabled(updateStatus == .checking)
                        Text(updateSummary)
                            .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    if case .updateAvailable(_, let release) = updateStatus {
                        Button("Open release page") { NSWorkspace.shared.open(release) }
                            .buttonStyle(.plain).font(Theme.Font.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    if case .failed(let reason) = updateStatus {
                        warning("Could not check: \(reason)")
                    }
                    caption("One unauthenticated request to GitHub's public SpektraLab release API, only when you press this. It sends no identifier and no app version.")
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

    private var updateSummary: String {
        switch updateStatus {
        case .idle:
            return "not checked"
        case .checking:
            return "checking GitHub…"
        case .updateAvailable(let version, _):
            return "\(version) is available"
        case .upToDate:
            return "this is the newest release"
        case .failed:
            return "could not check"
        }
    }

    private func checkForUpdates() {
        updateStatus = .checking
        Task {
            updateStatus = await UpdateCheck.check()
        }
    }
}

/// Settings content sits directly on the rail, like the editor's controls.
/// Keeping the inset and spacing in `Theme` prevents this window from growing
/// a parallel preferences-page visual system.
private struct SettingsRows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Theme.Metric.rowInset)
            .padding(.vertical, Theme.Metric.Settings.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
