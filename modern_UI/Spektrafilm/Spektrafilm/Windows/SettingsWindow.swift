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
//  **Pages, since 1.1.1 (RFC-026).** The sections had grown to nine in one
//  scrolling column, so they are grouped the way Capture One's preferences
//  are: a toolbar of icon tabs (General, Rendering, Memory, Diagnostics,
//  Agents), and on each page plain groups — a small title and a hairline, not
//  collapsible, because a settings page is read, not worked in. The rows
//  inside are the editor's own: rail rows, pills, toggles and `Theme` tokens.
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

    /// The page on screen, remembered between openings like the editor's
    /// own layout.
    @AppStorage(Session.uiKey + "settingsPage") private var page: SettingsPage = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $page)
            Hairline()
            ScrollView {
                VStack(spacing: Theme.Metric.Settings.groupSpacing) {
                    switch page {
                    case .general:
                        languageSection
                        appearanceSection
                        machineSection
                    case .rendering:
                        renderingSection
                    case .memory:
                        memorySection
                        diskCacheSection
                    case .diagnostics:
                        diagnosticsSection
                        logsSection
                        bundleSection
                    case .agents:
                        AgentsSettingsPage()
                    }
                }
                .padding(.vertical, Theme.Metric.Settings.verticalInset)
            }
            .id(page)
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
        return SettingsGroup(L(.setLanguage)) {
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
        SettingsGroup(L(.setInterface)) {
            SettingsRows {
                VStack(spacing: Theme.Metric.Settings.rowSpacing) {
                    PillMenu(label: L(.setScale),
                             options: InterfaceScale.allCases,
                             title: { $0.label },
                             selection: Binding(get: { InterfaceScaleStore.shared.scale },
                                                set: { InterfaceScaleStore.shared.scale = $0 }))
                    caption(L(.setScaleCaption))
                    HStack {
                        Button(L(.setResetLayout)) { SectionLayoutStore.resetAllLayout() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                    }
                    caption(L(.setResetLayoutCaption))
                }
            }
        }
    }

    // MARK: - rendering

    @ViewBuilder private var renderingSection: some View {
        SettingsGroup(L("Preview", zh: "预览")) {
            SettingsRows {
                VStack(spacing: 4) {
                    PillMenu(label: L("Preview", zh: "预览"), options: Session.previewEdgeChoices,
                             title: { "\($0) px" },
                             selection: Binding(get: { session.previewLongEdge },
                                                set: { session.setPreviewLongEdge($0) }))
                    caption(L("The resolution every interactive edit renders at. The frame's own resolution is rendered separately once an edit settles, so this trades responsiveness while dragging against nothing in the finished picture. The recorded cost of a reprint on a 45 MP frame is 13.7 ms at 2560 px, and rises roughly with the pixels.", zh: "每次交互编辑的渲染分辨率。编辑停下后会另外按照片本身的分辨率渲染，所以这里只是拖动时的流畅度，与最终画面无关。在 4500 万像素的照片上，2560 px 时一次重新印放实测约 13.7 ms，大致随像素数增加。"))
                    ToggleRow(label: L("Fast stock preview", zh: "快速相纸预览"), isOn: $session.fastStockPreview)
                    caption(L("When a print stock is picked, show the LUT applied to the negative already on the canvas instead of waiting for the full reprint. It is the same table, so the preview and the print agree.", zh: "选择相纸时，先把查找表套用到画布上已有的负片上显示，而不是等待完整的重新印放。用的是同一张表，所以预览与印放结果一致。"))
                }
            }
        }
        SettingsGroup(L("Film effects", zh: "胶片效果")) {
            SettingsRows {
                VStack(spacing: 4) {
                    ToggleRow(label: L("Crop re-maps the frame", zh: "裁剪重新映射画幅"),
                              isOn: Binding(get: { Session.recalculateEffectsAfterCrop },
                                            set: { Session.recalculateEffectsAfterCrop = $0
                                                   session.recomputeFilmFormat() }))
                    caption(L("Whether cropping changes the physical scale of grain, halation and glare. Off — the default, and the physically true answer — the crop shows less of the same negative and its grain is the size it always was. On, the cropped rectangle *is* the frame: the Film section's Side Length now describes the crop, so a smaller crop gets coarser grain and wider halation, as if the whole negative had been the crop. It applies as you drag the crop, and switching it re-develops the open frame at once. The engine's film size tops out at 200 mm, which a crop to about a fifth of a 135 frame's long edge reaches. This is the setting the Film section's Side Length row is measured against.", zh: "裁剪是否改变颗粒、光晕与耀光的物理尺度。关闭（默认，也是物理上正确的做法）时，裁剪只是看到同一张负片的更小部分，颗粒大小不变。打开时，裁剪框就是画幅：胶片画幅中的边长描述的是裁剪后的区域，裁得越小颗粒越粗、光晕越宽，就像整张负片本来就是这么大。拖动裁剪时即时生效，切换此项会立即重新显影当前照片。引擎的胶片尺寸上限为 200 mm，大约相当于把 135 画幅的长边裁到五分之一。胶片画幅中的边长一行以此设置为准。"))
                    ToggleRow(label: L("Decouple effects", zh: "分离效果强度"), isOn: $decoupleEffects)
                    caption(L("Show a strength for each film effect beside its switch — grain, halation and its scatter, DIR couplers, glare — and let grain's sub-layer model be chosen on its own. Every strength is a multiple of what the chosen film would do, so 1 is always that film as modelled. The strengths belong to the frame: turning this off hides the sliders and changes no picture.", zh: "在每个胶片效果的开关旁显示强度滑块（颗粒、光晕及其散射、DIR 耦合剂、耀光），并可单独选择颗粒的分层模型。强度是所选胶片本身效果的倍数，1 始终代表该胶片的模型原样。强度属于照片本身：关闭此项只会隐藏滑块，不会改变任何画面。"))
                }
            }
        }
    }

    // MARK: - diagnostics

    private var diagnosticsSection: some View {
        // Read once, outside the pill's title closure, for the reason
        // `languageSection` gives.
        let chinese = Localization.shared.resolved == .simplifiedChinese
        return SettingsGroup(L("Diagnostics", zh: "诊断")) {
            SettingsRows {
                VStack(spacing: 4) {
                    PillMenu(label: L("Log level", zh: "日志级别"), options: LogLevelSetting.allCases,
                             title: { [chinese] in chinese ? Self.logLevelZH[$0.label] ?? $0.label : $0.label },
                             selection: Binding(get: { diagnostics.level },
                                                set: { diagnostics.level = $0 }))
                    caption(L(diagnostics.level.detail, zh: Self.zh[diagnostics.level.detail] ?? ""))
                    ToggleRow(label: L("Per-node GPU timings", zh: "逐节点 GPU 计时"),
                              isOn: Binding(get: { diagnostics.perNodeGPUTimings },
                                            set: { diagnostics.perNodeGPUTimings = $0 }))
                    // Visible, not hover help. RFC-016 §5.2 is specific: "the
                    // Settings toggle must say so in the same sentence". A
                    // tooltip is not the toggle saying so — it is the toggle
                    // saying so to whoever already suspected there was
                    // something to hover over.
                    caption(L(Diagnostics.perNodeTimingsNote, zh: Self.zh[Diagnostics.perNodeTimingsNote] ?? ""))
                    ToggleRow(label: L("Write a job log beside exports", zh: "在导出文件旁写入任务日志"),
                              isOn: Binding(get: { diagnostics.writeExportJobLog },
                                            set: { diagnostics.writeExportJobLog = $0 }))
                    caption(L(Diagnostics.exportJobLogNote, zh: Self.zh[Diagnostics.exportJobLogNote] ?? ""))
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
        SettingsGroup(L("Memory", zh: "内存")) {
            SettingsRows {
                VStack(alignment: .leading, spacing: 3) {
                    if let m = diagnostics.memory {
                        readout(L("Footprint", zh: "占用"), bytes(m.footprintBytes))
                        readout(L("Session peak", zh: "本次峰值"), bytes(m.peakBytes))
                        readout(L("Free", zh: "可用"), bytes(m.freeBytes))
                    } else {
                        readout(L("Footprint", zh: "占用"), L("not sampled yet", zh: "尚未采样"))
                    }
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    // A setting, not a readout — so it lives outside the
                    // `memory` branch above. Inside it, the control would
                    // disappear until the first sample landed, which is
                    // exactly when someone setting up a small machine would
                    // go looking for it.
                    intRow(L("Reserve", zh: "预留"), diagnostics.memoryReserveMegabytes, "MB",
                           Diagnostics.memoryReserveRange) {
                        diagnostics.memoryReserveMegabytes = $0
                    }
                    caption(L(Diagnostics.memoryReserveNote, zh: Self.zh[Diagnostics.memoryReserveNote] ?? ""))
                    intRow(L("Working-set cap", zh: "工作集上限"),
                           diagnostics.memoryCapIsUnlimited
                               ? Diagnostics.defaultMemoryCapMB
                               : diagnostics.memoryCapMegabytes,
                           "MB", Diagnostics.memoryCapRange) {
                        diagnostics.memoryCapMegabytes = $0
                    }
                    .disabled(diagnostics.memoryCapIsUnlimited)
                    ToggleRow(label: L("Unlimited", zh: "不限制"),
                              isOn: Binding(get: { diagnostics.memoryCapIsUnlimited },
                                            set: { diagnostics.memoryCapIsUnlimited = $0 }))
                    caption(L(Diagnostics.memoryCapNote, zh: Self.zh[Diagnostics.memoryCapNote] ?? ""))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    readout(L("Held by SpektraLab", zh: "SpektraLab 占用"),
                            bytes(UInt64(max(0, diagnostics.arena.totalBytes))),
                            help: arenaBreakdown())
                    readout(L("Evictable", zh: "可释放"),
                            bytes(UInt64(max(0, diagnostics.arena.evictableBytes))))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    ToggleRow(label: L("Allow exceeding the reserve", zh: "允许超出预留"),
                              isOn: Binding(get: { diagnostics.allowOverReserve },
                                            set: { diagnostics.allowOverReserve = $0 }))
                    caption(L("A frame whose projected peak does not leave the reserve free gets a warning you can override. Nothing is ever blocked; this is the standing answer to that warning, and turning it off makes the app ask again.", zh: "预计峰值会挤占预留内存的照片会收到一条可以忽略的警告。任何操作都不会被阻止；这一项是对该警告的长期回答，关闭后会重新询问。"))
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
        SettingsGroup(L("Disk cache", zh: "磁盘缓存")) {
            SettingsRows {
                VStack(alignment: .leading, spacing: 3) {
                    if session.hasDiskCache {
                        readout(L("In use", zh: "已用"), "\(bytes(session.diskCacheBytes))" + L(" of ", zh: " / ")
                                          + "\(bytes(diagnostics.diskCacheCapBytes))")
                    } else {
                        readout(L("In use", zh: "已用"), L("the cache could not be opened", zh: "无法打开缓存"))
                    }
                    intRow(L("Limit", zh: "上限"), diagnostics.diskCacheCapMegabytes / 1_000, "GB",
                           Diagnostics.diskCacheCapGigabyteRange) {
                        diagnostics.diskCacheCapMegabytes = $0 * 1_000
                    }
                    caption(L(Diagnostics.diskCacheCapNote, zh: Self.zh[Diagnostics.diskCacheCapNote] ?? ""))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    labelled(L("Location", zh: "位置")) {
                        Text(Session.diskCacheRoot.path)
                            .font(Theme.Font.caption).foregroundStyle(Theme.text)
                            // A path in full, wrapping; never "…/SpektraLab".
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(minHeight: 16)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    HStack(spacing: 10) {
                        Button(L("Reveal in Finder", zh: "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Session.diskCacheRoot])
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        Button(L("Empty cache now", zh: "立即清空缓存")) {
                            session.clearDiskCacheNow()
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption)
                        .foregroundStyle(session.hasDiskCache ? Theme.accent : Theme.dim)
                        .disabled(!session.hasDiskCache)
                        .help(L("Deletes every cached decode and print. Nothing of yours is in it.", zh: "删除所有缓存的解码与印放结果。其中没有任何你的作品。"))
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - logs

    private var logsSection: some View {
        SettingsGroup(L("Logs", zh: "日志")) {
            SettingsRows {
                VStack(spacing: 4) {
                    intRow(L("Keep for", zh: "保留时长"), diagnostics.retentionDays, L("days", zh: "天"), 1...365) {
                        diagnostics.retentionDays = $0
                    }
                    intRow(L("Keep at most", zh: "最多保留"), diagnostics.retentionMegabytes, "MB", 10...10_000) {
                        diagnostics.retentionMegabytes = $0
                    }
                    intRow(L("Keep at most", zh: "最多保留"), diagnostics.retentionFiles, L("files", zh: "个文件"), 1...500) {
                        diagnostics.retentionFiles = $0
                    }
                    caption(L("Whichever limit is reached first wins, oldest file first. Cleaning runs at launch, never during a render.", zh: "先达到哪个上限就按哪个清理，最旧的文件先删。清理在启动时进行，不会在渲染时进行。"))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    labelled(L("Destination", zh: "存放位置")) {
                        Text(diagnostics.logDirectory.path)
                            .font(Theme.Font.caption).foregroundStyle(Theme.text)
                            // A path in full, wrapping; never "…/SpektraLab".
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(minHeight: 16)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button(L("Choose…", zh: "选择…")) { chooseLogDirectory() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    }
                    caption(L(Diagnostics.logDirectoryNote, zh: Self.zh[Diagnostics.logDirectoryNote] ?? ""))
                    if let f = diagnostics.cleanupFailure { warning(f) }
                    if let f = diagnostics.writeFailure { warning(f) }
                    HStack(spacing: 10) {
                        Button(L("Reveal in Finder", zh: "在访达中显示")) { diagnostics.revealLogsInFinder() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        Button(L("Clear logs now", zh: "立即清空日志")) { diagnostics.clearLogsNow() }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                            .help(L("Deletes every log file except this session's.", zh: "删除除本次会话以外的所有日志文件。"))
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - the bundle

    private var bundleSection: some View {
        SettingsGroup(L("Diagnostic bundle", zh: "诊断包")) {
            SettingsRows {
                VStack(spacing: 4) {
                    ToggleRow(label: L("Include image file names", zh: "包含图像文件名"),
                              isOn: Binding(get: { diagnostics.includeFileNamesInBundle },
                                            set: { diagnostics.includeFileNamesInBundle = $0 }))
                    caption(L(DiagnosticBundle.fileNamesNote, zh: Self.zh[DiagnosticBundle.fileNamesNote] ?? ""))
                    HStack(spacing: 10) {
                        Button(savingBundle ? L("Saving…", zh: "正在保存…") : L("Save diagnostic bundle…", zh: "保存诊断包…")) { saveBundle() }
                            .buttonStyle(.plain).font(Theme.Font.caption)
                            .foregroundStyle(savingBundle ? Theme.dim : Theme.accent)
                            .disabled(savingBundle)
                        Spacer()
                    }
                    caption(L("One zip: the recent log files, the engine's capabilities, the app and engine versions, this machine, the current settings and the last error. Nothing is transmitted — it is written where you choose.", zh: "一个 zip 文件：最近的日志、引擎能力、应用与引擎版本、本机信息、当前设置和最近一次错误。不会上传任何内容，只写到你选择的位置。"))
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
        SettingsGroup(L("This session", zh: "本次会话")) {
            SettingsRows {
                VStack(alignment: .leading, spacing: 3) {
                    readout(L("App", zh: "应用"), Diagnostics.bundleInfo.version)
                    readout(L("Engine", zh: "引擎"), diagnostics.engineVersion ?? L("not reported yet", zh: "尚未报告"))
                    readout(L("Render core", zh: "渲染核心"), session.renderCore ?? L("not reported yet", zh: "尚未报告"))
                    readout(L("Log file", zh: "日志文件"), diagnostics.currentLogFile?.lastPathComponent ?? L("none", zh: "无"))
                    Divider().overlay(Theme.plotGrid).padding(.vertical, 4)
                    HStack(spacing: 10) {
                        Button(updateStatus == .checking ? L("Checking…", zh: "正在检查…") : L("Check for updates", zh: "检查更新")) {
                            checkForUpdates()
                        }
                        .buttonStyle(.plain).font(Theme.Font.caption)
                        .foregroundStyle(updateStatus == .checking ? Theme.dim : Theme.accent)
                        .disabled(updateStatus == .checking)
                        Text(updateSummary)
                            .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    if case .updateAvailable(_, let release) = updateStatus {
                        Button(L("Open release page", zh: "打开发布页面")) { NSWorkspace.shared.open(release) }
                            .buttonStyle(.plain).font(Theme.Font.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    if case .failed(let reason) = updateStatus {
                        warning(L("Could not check: \(reason)", zh: "无法检查：\(reason)"))
                    }
                    caption(L("One unauthenticated request to GitHub's public SpektraLab release API, only when you press this. It sends no identifier and no app version.", zh: "仅在你按下时，向 GitHub 公开的 SpektraLab 发布接口发送一次匿名请求。不发送任何标识符或应用版本。"))
                    if diagnostics.previousSessionChecked {
                        if let p = diagnostics.previousSession {
                            readout(L("Last session", zh: "上次会话"), p.endedCleanly
                                    ? L("ended cleanly", zh: "正常结束")
                                    : L("did not end cleanly (\(p.file))", zh: "未正常结束（\(p.file)）"))
                            if !p.endedCleanly {
                                caption(L("That log has no session-end record, which is how a hang, an out-of-memory kill or a crash shows up — the app never got to write one. The file is in the log folder and the diagnostic bundle includes it.", zh: "该日志没有会话结束记录——卡死、内存不足被终止或崩溃都会这样，应用没来得及写下它。文件在日志文件夹中，诊断包也会包含它。"))
                            }
                        } else {
                            readout(L("Last session", zh: "上次会话"), L("no earlier log", zh: "没有更早的日志"))
                        }
                    }
                    if let e = diagnostics.lastError { warning(L("Last error — ", zh: "最近一次错误 — ") + e) }
                }
            }
        }
    }

    // MARK: - pieces

    /// Chinese for the Settings captions whose English lives beside the
    /// setting it describes, in `Diagnostics` and `DiagnosticBundle`.
    static let zh: [String: String] = [
        Diagnostics.perNodeTimingsNote:
            "让引擎为每个管线节点单独计时。每个节点都必须在计时结束前完成提交，这会放弃引擎赖以提速的批处理，渲染会明显变慢。这是诊断模式，不应作为默认。",
        Diagnostics.exportJobLogNote:
            "在每个导出文件旁写入一个 .joblog.jsonl：配方、引擎版本、耗时和实际应用的曝光。无论是否打开，会话日志都会记录每次导出。",
        Diagnostics.memoryReserveNote:
            "SpektraLab 为其他程序留出的空闲内存。预计峰值放不进这一预留的照片会收到一条可以忽略的警告，绝不会被拒绝。下方的选项只会关掉警告，不会影响释放。",
        Diagnostics.memoryCapNote:
            "SpektraLab 可在缓存和临时缓冲区中占用的内存。正在查看的照片永远不会被释放，无论此处如何设置。可用内存由本机的其他应用决定；这里是 SpektraLab 自己能决定的部分。",
        Diagnostics.diskCacheCapNote:
            "SpektraLab 用于存放解码后的照片和完成的印放的磁盘空间，这样重新打开照片时不必再次解码。这里没有任何你的作品——每一项都能从原始文件重新生成，清空的唯一代价是下次打开这些照片时要多等一会儿。价值最低的条目先被清除，依据是使用频率与生成成本。",
        Diagnostics.logDirectoryNote:
            "会话日志的写入位置。更改在下次启动时生效；本次会话继续写入已打开的文件。",
        DiagnosticBundle.fileNamesNote:
            "诊断包会包含你处理过的图像的文件名。取消勾选后会全部替换为占位符，日志其余内容不变。",
        LogLevelSetting.normal.detail: "日常记录：打开、渲染、导出、内存与错误。",
        LogLevelSetting.detailed.detail: "增加画布与引擎每一步的记录。下次启动时恢复为“普通”。",
        LogLevelSetting.verbose.detail: "记录全部内容，包括逐节点跟踪。会降低渲染速度，下次启动时恢复为“普通”。",
    ]

    static let logLevelZH: [String: String] = [
        LogLevelSetting.normal.label: "普通",
        LogLevelSetting.detailed.label: "详细",
        LogLevelSetting.verbose.label: "全部",
    ]

    private func readout(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(spacing: 0) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.dim)
                .fixedSize().padding(.trailing, 6)
                .frame(minWidth: 96, alignment: .leading)
            Text(value).font(Theme.Font.caption).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help ?? "")
    }

    private func arenaBreakdown() -> String {
        let parts = diagnostics.arena.breakdown().map {
            "\($0.kind): \(bytes(UInt64(max(0, $0.bytes))))"
        }
        return parts.isEmpty ? L("No cache or frame allocations registered yet.", zh: "尚未登记任何缓存或照片内存分配。")
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
                .fixedSize().padding(.trailing, 6)
                .frame(minWidth: Theme.Metric.sliderLabelWidth, alignment: .leading)
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
                .fixedSize().padding(.trailing, 6)
                .frame(minWidth: Theme.Metric.sliderLabelWidth, alignment: .leading)
            content()
        }
        // At least a row; taller when a path under it wraps.
        .frame(minHeight: Theme.Metric.rowHeight)
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
        panel.prompt = L("Choose", zh: "选择")
        panel.message = L("Where should SpektraLab write its logs?", zh: "SpektraLab 应把日志写到哪里？")
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
            : L("Image file names will be replaced with placeholders throughout.", zh: "图像文件名将全部替换为占位符。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savingBundle = true
        bundleResult = nil
        Task {
            defer { savingBundle = false }
            do {
                let written = try await diagnostics.saveDiagnosticBundle(to: url)
                bundleResult = L("Wrote \(written.lastPathComponent).", zh: "已写入 \(written.lastPathComponent)。")
                NSWorkspace.shared.activateFileViewerSelecting([written])
            } catch {
                bundleResult = L("Could not write the bundle: \(error.localizedDescription)", zh: "无法写入诊断包：\(error.localizedDescription)")
            }
        }
    }

    private var updateSummary: String {
        switch updateStatus {
        case .idle:
            return L("not checked", zh: "尚未检查")
        case .checking:
            return L("checking GitHub…", zh: "正在检查 GitHub…")
        case .updateAvailable(let version, _):
            return L("\(version) is available", zh: "\(version) 可供更新")
        case .upToDate:
            return L("this is the newest release", zh: "已是最新版本")
        case .failed:
            return L("could not check", zh: "无法检查")
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
struct SettingsRows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Theme.Metric.rowInset)
            .padding(.vertical, Theme.Metric.Settings.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - pages, tabs and groups (Capture One's preferences, RFC-026)

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, rendering, memory, diagnostics, agents
    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .general: L(.setTabGeneral)
        case .rendering: L(.setTabRendering)
        case .memory: L(.setTabMemory)
        case .diagnostics: L(.setTabDiagnostics)
        case .agents: L(.setTabAgents)
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .rendering: "slider.horizontal.3"
        case .memory: "memorychip"
        case .diagnostics: "stethoscope"
        case .agents: "terminal"
        }
    }
}

/// The toolbar: an icon over its name per page, the chosen one on a plate
/// with its icon in the accent, as Capture One draws it.
struct SettingsTabBar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                let on = page == selection
                Button { selection = page } label: {
                    VStack(spacing: 3) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 16 * InterfaceScaleStore.shared.scale.factor))
                            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                            .frame(height: 20 * InterfaceScaleStore.shared.scale.factor)
                        Text(page.title)
                            .font(Theme.Font.caption)
                            .foregroundStyle(on ? Theme.text : Theme.dim)
                            .fixedSize()
                    }
                    .frame(minWidth: Theme.Metric.Settings.tabWidth)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .background(on ? Theme.ground : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.Metric.Settings.tabRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// One group on a page: a small grey title, a hairline, and its rows. Not
/// collapsible — the page is short enough to read whole, which is the point
/// of having pages.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.dim)
                    .fixedSize()
                Hairline().opacity(0.35)
            }
            .padding(.horizontal, Theme.Metric.rowInset)
            .padding(.top, 4)
            content()
        }
    }
}
