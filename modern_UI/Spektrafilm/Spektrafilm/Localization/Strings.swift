//  Strings.swift — every user-visible string in the main editor, in both
//  languages, and the one function that looks them up.
//
//  `design/LOCALIZATION-zh-Hans.md` is the spec this table implements; read it
//  before adding a key. Two of its rules are worth repeating here because they
//  are the ones a well-meaning edit gets wrong:
//
//    * **Names stay English.** Every film and paper profile, camera and lens
//      model, file name, and the abbreviations `CINE RAW RGB ISO EV LUT EDR`,
//      the format names, units, aspect ratios and shortcut letters are
//      identifiers, not copy. They have no Chinese value here because they are
//      not translated — a translated `Kodak Portra 400` is a different product
//      name and a broken catalog lookup.
//    * **Same English, different strings.** `Original` is both a crop ratio
//      and a view state, and `Print` is both the section and the stage named
//      inside other sentences. They get one key each, because they are
//      different strings that happen to share a spelling in one language. Do
//      not collapse them and do not global-replace an English word.
//
//  There is deliberately no `default:` in either switch. The compiler then
//  requires every case of `S` to have both languages, so a key added without a
//  translation is a build error rather than a blank label in the window.
//
//  Not everything in the editor is in here. This table covers the two tables in
//  the spec — the main page and the icon/feedback labels. The Settings page,
//  the export page and system error text are out of scope for this pass; the
//  spec's last section says so explicitly.

import Foundation

/// One case per user-visible string. The raw value is the key's name and the
/// last-resort fallback, so it must never be shown as copy if that can be
/// helped — see `L(_:)`.
///
/// Names are semantic and grouped by prefix: `rail*` `section*` `camera*`
/// `metering*` `film*` `print*` `curve*` `exposure*` `balance*` `crop*`
/// `action*` `help*` `status*` `reason*`, plus this pass's own `setLanguage*`
/// for the Settings section it adds.
enum S: String, CaseIterable, Sendable {
    // MARK: rails
    case railDevelop, railEdit

    // MARK: section titles
    case sectionCamera, sectionFilm, sectionPrint, sectionCrop
    case sectionHistogram, sectionWhiteBalance, sectionExposure
    case sectionCurve, sectionColorBalance

    // MARK: Camera
    case cameraMetering, cameraFilmExposure, cameraFilmExposureAsShot
    case cameraTemperature, cameraTint, cameraVignetting, cameraLensCorrection

    // MARK: the metering pill's options
    case meteringCustom, meteringBalanced, meteringCenter
    case meteringProtectHighlights, meteringProtectShadows
    case meteringCenterWeightedLegacy

    // MARK: Film
    case filmGroupPositive, filmGroupNegative
    case filmFormat, filmFormatSide, filmFormatShort, filmFormatLong
    case filmFormatSideLength
    case filmGrain, filmHalation, filmGlare
    // RFC-025, shown only with Settings → Decouple effects.
    case filmEffectStrength, filmGrainLayers, filmScatter, filmCouplers

    // MARK: Print
    case printGroupStill, printGroupCine, printNone, printEDR

    // MARK: Curve
    case curveLuma, curveRed, curveGreen, curveBlue, curveInput, curveOutput

    // MARK: the right rail's sliders
    case exposureContrast, exposureBrightness, exposureSaturation
    case exposureHighlights, exposureShadows
    case exposureBlackPoint, exposureWhitePoint
    case balanceMidtones

    // MARK: Crop
    case cropAspect, cropAspectFree, cropAspectOriginal
    case cropStraighten, cropStraightenUnit, cropRotate

    // MARK: actions and view states
    case actionDeveloped, actionOriginal, actionSolve, actionProcess, actionRestart

    // MARK: tooltips, menus and accessibility labels
    case helpOpen, helpExport, helpSelect, helpPan, helpBeforeAfter
    case helpZoomIn, helpZoomOut, helpFit
    case helpFullScreenEnter, helpFullScreenLeave
    case helpDevelopRailHide, helpDevelopRailShow
    case helpEditRailHide, helpEditRailShow
    case helpPickNeutral, helpWhiteBalancePreset
    case helpReset, helpResetFilmExposure, helpResetChannels, helpResetCrop
    case helpStraightenZero, helpCropWholeFrame, helpRevealInFinder
    case helpResetDefaults, helpUseFilmPaper
    case helpAllEffectsOn, helpAllEffectsOff, helpFastFlip, helpResetEffectStrengths

    // MARK: status and disabled reasons
    case statusFull, statusFullPending, statusEmptyFilmstrip
    case statusEDRScope, statusRightRailWBScope
    case reasonDecodeWBDisabled, reasonNonCustomSideLength, reasonEffectOff
    case reasonPositiveFilmDisablesPaper, reasonEDRDisabledInScanFilm

    // MARK: the Settings page's Language section
    case setLanguage, setLanguageCaption, languageFollowSystem

    // MARK: frontend v4 (2026-09-26 drawing)
    case latitudeUnmeasurable, latitudeNoLight, filmFormatSize, railFilmAndPrint, railParameters, tabPreDev, tabPostDev, sectionNavigator, sectionEnlarger, sectionLatitude, sectionScenePlacement, sectionToneMask, printEffects, filmGrainStrength, filmHalationStrength, filmScatterStrength, filmCouplersStrength, filmGlareStrength, latitudeBelow, latitudeWithin, latitudeAbove, latitudeHeld, latitudeFullSeparation, latitudeEmpty, placementHighlight, placementShadow, maskEnable, maskHighlights, maskShadows, maskCore, maskRadius, maskCurveCaption, enlargerPreflash, helpResetFilmFormat, helpResetPlacement, helpResetToneMask, helpResetEnlarger, helpSubLayerGrain, reasonPrintEffectsOff, reasonNotDeveloped, setResetLayout, setResetLayoutCaption

    // MARK: Settings as pages, and the Agents page (RFC-026)
    case setTabGeneral, setTabRendering, setTabMemory, setTabDiagnostics, setTabAgents
    case setInterface, setScale, setScaleCaption
    case setAgentsAccess, setAgentsToggle, setAgentsToggleCaption
    case setAgentsCommandLine, setAgentsInstall, setAgentsReinstall, setAgentsUninstall
    case setAgentsInstalled, setAgentsNotInstalled, setAgentsInstalledOther, setAgentsInstallCaption
    case setAgentsMCP, setAgentsClaudeCode, setAgentsClaudeDesktop, setAgentsMCPCaption
    case setAgentsCopy, setAgentsCopied, setAgentsTools
}

// MARK: - the table

extension S {
    /// English. Exhaustive, so this is also the list of what the app can say.
    var english: String {
        switch self {
        // rails and sections
        case .railDevelop: "Develop"
        case .railEdit: "Edit"
        case .latitudeUnmeasurable: "This film and paper do not print a rising tone scale, so there is no latitude to measure. A slide printed onto print film comes out as a negative."
        case .latitudeNoLight: "The frame has no light in it to measure."
        case .filmFormatSize: "Size"
        case .railFilmAndPrint: "Film and Print"
        case .railParameters: "Parameters"
        case .tabPreDev: "Pre-Dev"
        case .tabPostDev: "Post-Dev"
        case .sectionNavigator: "Navigator"
        case .sectionEnlarger: "Enlarger"
        case .sectionLatitude: "Latitude"
        case .sectionScenePlacement: "Scene Placement"
        case .sectionToneMask: "Tone Mask"
        case .printEffects: "Print Effects"
        case .filmGrainStrength: "Grain Strength"
        case .filmHalationStrength: "Halation Strength"
        case .filmScatterStrength: "Scatter Strength"
        case .filmCouplersStrength: "Couplers Strength"
        case .filmGlareStrength: "Glare Strength"
        case .latitudeBelow: "Below"
        case .latitudeWithin: "Within"
        case .latitudeAbove: "Above"
        case .latitudeHeld: "stops held"
        case .latitudeFullSeparation: "full separation"
        case .latitudeEmpty: "Develop the frame to measure it against this film and paper."
        case .placementHighlight: "Highlight"
        case .placementShadow: "Shadow"
        case .maskEnable: "Enable"
        case .maskHighlights: "Highlights"
        case .maskShadows: "Shadows"
        case .maskCore: "Core"
        case .maskRadius: "Radius"
        case .maskCurveCaption: "Change in paper exposure against the blurred negative, stops"
        case .enlargerPreflash: "Pre-flash"
        case .helpResetFilmFormat: "Reset the film format and its effects"
        case .helpResetPlacement: "Turn Scene Placement off"
        case .helpResetToneMask: "Reset the Tone Mask"
        case .helpResetEnlarger: "Reset the enlarger to the solved pack"
        case .helpSubLayerGrain: "Sub-layer grain model"
        case .reasonPrintEffectsOff: "Print Effects is off in the Print section."
        case .reasonNotDeveloped: "Develop the frame first."
        case .setResetLayout: "Reset All Layout"
        case .setResetLayoutCaption: "Panel widths, section heights and which sections are open, back to the drawing."
        case .setTabGeneral: "General"
        case .setTabRendering: "Rendering"
        case .setTabMemory: "Memory"
        case .setTabDiagnostics: "Diagnostics"
        case .setTabAgents: "Agents"
        case .setInterface: "Interface"
        case .setScale: "Scale"
        case .setScaleCaption: "Scales type across the editor, Settings and Export. Changes apply immediately."
        case .setAgentsAccess: "Access"
        case .setAgentsToggle: "Allow command line and agent access"
        case .setAgentsToggleCaption: "Lets the spektralab command and MCP agents (Claude Code, Claude Desktop, any MCP client) open, edit, process and export photographs on this Mac — the same edits this window makes, saved where it reads them. Off, every call is refused, including one from an agent already connected. Local only: nothing listens on the network, and originals are never written."
        case .setAgentsCommandLine: "Command line"
        case .setAgentsInstall: "Install spektralab"
        case .setAgentsReinstall: "Reinstall"
        case .setAgentsUninstall: "Remove"
        case .setAgentsInstalled: "Installed"
        case .setAgentsNotInstalled: "Not installed"
        case .setAgentsInstalledOther: "Installed for another copy of the app"
        case .setAgentsInstallCaption: "Writes a two-line script to ~/.local/bin/spektralab that runs this app without a window. Try `spektralab help`; every command prints JSON."
        case .setAgentsMCP: "MCP server"
        case .setAgentsClaudeCode: "Claude Code"
        case .setAgentsClaudeDesktop: "Claude Desktop"
        case .setAgentsMCPCaption: "Add SpektraLab to an agent with one of these. The agent starts the server itself over stdio when it needs it; nothing runs in the background."
        case .setAgentsCopy: "Copy"
        case .setAgentsCopied: "Copied"
        case .setAgentsTools: "Tools"
        case .sectionCamera: "Input / Camera"
        case .sectionFilm: "Film"
        case .sectionPrint: "Print"
        case .sectionCrop: "Crop"
        case .sectionHistogram: "Histogram"
        case .sectionWhiteBalance: "White Balance"
        case .sectionExposure: "Exposure"
        case .sectionCurve: "Curve"
        case .sectionColorBalance: "Color Balance"

        // Camera
        case .cameraMetering: "Metering"
        case .cameraFilmExposure: "Film Exposure"
        case .cameraFilmExposureAsShot: "As Shot"
        case .cameraTemperature: "Temperature"
        case .cameraTint: "Tint"
        case .cameraVignetting: "Vignetting"
        case .cameraLensCorrection: "Lens Correction"

        // metering
        case .meteringCustom: "Custom"
        case .meteringBalanced: "Balanced"
        case .meteringCenter: "Center"
        case .meteringProtectHighlights: "Protect highlights"
        case .meteringProtectShadows: "Protect shadows"
        case .meteringCenterWeightedLegacy: "center-weighted (legacy)"

        // Film
        case .filmGroupPositive: "Positive"
        case .filmGroupNegative: "Negative"
        case .filmFormat: "Film Format"
        case .filmFormatSide: "Side"
        case .filmFormatShort: "Short"
        case .filmFormatLong: "Long"
        case .filmFormatSideLength: "Side Length"
        case .filmGrain: "Grain"
        case .filmHalation: "Halation"
        case .filmGlare: "Glare"
        case .filmEffectStrength: "Strength"
        case .filmGrainLayers: "Sub-layers"
        case .filmScatter: "Scatter"
        case .filmCouplers: "DIR Couplers"

        // Print
        case .printGroupStill: "Still"
        case .printGroupCine: "Cine"
        case .printNone: "No Print Profile"
        case .printEDR: "Extended Dynamic Range (EDR)"

        // Curve
        case .curveLuma: "Luma"
        case .curveRed: "Red"
        case .curveGreen: "Green"
        case .curveBlue: "Blue"
        case .curveInput: "Input"
        case .curveOutput: "Output"

        // right rail
        case .exposureContrast: "Contrast"
        case .exposureBrightness: "Brightness"
        case .exposureSaturation: "Saturation"
        case .exposureHighlights: "Highlights"
        case .exposureShadows: "Shadows"
        case .exposureBlackPoint: "Black Point"
        case .exposureWhitePoint: "White Point"
        case .balanceMidtones: "Midtones"

        // Crop
        case .cropAspect: "Aspect"
        case .cropAspectFree: "Free"
        case .cropAspectOriginal: "Original"
        case .cropStraighten: "Straighten"
        case .cropStraightenUnit: "degrees"
        case .cropRotate: "Rotate"

        // actions
        case .actionDeveloped: "Developed"
        case .actionOriginal: "Original"
        case .actionSolve: "Process"
        // The spec's row gives both English forms — "Process / Process
        // this frame" — and this key is the ••• item, not a button. The
        // longer one is chosen because §8.1 of the layout handoff turns on
        // this item naming what it does: with the Developed capsule now a
        // view toggle, this is the only control in the section that changes
        // the picture, and a bare "Process" beside "Use the film's declared
        // paper" does not say that it acts on this frame.
        case .actionProcess: "Process this frame"
        case .actionRestart: "Restart"

        // help
        case .helpOpen: "Open a folder or image"
        case .helpExport: "Export"
        case .helpSelect: "Select"
        case .helpPan: "Pan"
        // The trailing clause is **not** dropped. The spec's row gives
        // the control's *name*; this key is its tooltip, and the split's
        // handle is a thing you would not discover by looking at it — the
        // one piece of real instruction in the toolbar's help. It is
        // translated below rather than glued on as an English fragment,
        // which is what the spec actually forbids.
        case .helpBeforeAfter: "Before / after split — drag the line on the canvas"
        case .helpZoomIn: "Zoom in"
        case .helpZoomOut: "Zoom out"
        case .helpFit: "Fit"
        case .helpFullScreenEnter: "Full screen"
        case .helpFullScreenLeave: "Leave full screen"
        case .helpDevelopRailHide: "Hide the darkroom rail"
        case .helpDevelopRailShow: "Show the darkroom rail"
        case .helpEditRailHide: "Hide the adjustments rail"
        case .helpEditRailShow: "Show the adjustments rail"
        case .helpPickNeutral: "Pick a neutral point on the image"
        case .helpWhiteBalancePreset: "White balance preset"
        case .helpReset: "Reset"
        case .helpResetFilmExposure: "Reset film exposure"
        case .helpResetChannels: "Reset all channels"
        case .helpResetCrop: "Reset crop"
        case .helpStraightenZero: "Straighten to 0°"
        case .helpCropWholeFrame: "Crop to whole frame"
        case .helpRevealInFinder: "Reveal in Finder"
        case .helpResetDefaults: "Reset to defaults"
        case .helpUseFilmPaper: "Use the film's declared paper"
        case .helpAllEffectsOn: "All effects on"
        case .helpAllEffectsOff: "All effects off"
        case .helpResetEffectStrengths: "Reset effect strengths to the film's own"
        case .helpFastFlip: "Fast flip (baked LUT, no glare, ignores your print grade)"

        // status and reasons
        case .statusFull: "full"
        case .statusFullPending: "full…"
        case .statusEmptyFilmstrip: "Drop a folder or images here, or press ⌘O."
        case .statusEDRScope: "Changes the render — canvas, proof and file alike"
        case .statusRightRailWBScope: "Print — an adjustment on the scan."
        case .reasonDecodeWBDisabled: "Decode white balance applies to RAW input only."
        case .reasonNonCustomSideLength:
            "Side Length is the film type's own measurement. Choose Custom to type one."
        case .reasonEffectOff: "Turn the effect on to set its strength."
        case .reasonPositiveFilmDisablesPaper:
            "A slide film is already a positive — there is nothing for a paper to interpret. "
            + "Choose a negative film to print onto paper."
        case .reasonEDRDisabledInScanFilm:
            "Extended Dynamic Range applies to selected print profiles."

        // Settings ▸ Language
        case .setLanguage: "Language"
        case .setLanguageCaption:
            "Film, paper, camera and lens names stay in English, as do technical abbreviations. "
            + "The change applies immediately — nothing needs restarting."
        case .languageFollowSystem: "Follow the system"
        }
    }

    /// 简体中文. Verbatim from `design/LOCALIZATION-zh-Hans.md`; the keys above
    /// are named after the semantics the spec distinguishes, not after the
    /// English word, so the two `Original`s and the two `Print`s do not collide.
    var simplifiedChinese: String {
        switch self {
        // rails and sections
        case .railDevelop: "显影"
        case .railEdit: "调整"
        case .latitudeUnmeasurable: "当前胶片与相纸的输出不随曝光递增，无法测量宽容度。反转片印到电影正片上会得到负像。"
        case .latitudeNoLight: "画面中没有可测量的光。"
        case .filmFormatSize: "尺寸"
        case .railFilmAndPrint: "胶片与相纸"
        case .railParameters: "参数"
        case .tabPreDev: "显影前"
        case .tabPostDev: "显影后"
        case .sectionNavigator: "导航"
        case .sectionEnlarger: "放大机"
        case .sectionLatitude: "宽容度"
        case .sectionScenePlacement: "场景置位"
        case .sectionToneMask: "影调蒙版"
        case .printEffects: "相纸效果"
        case .filmGrainStrength: "颗粒强度"
        case .filmHalationStrength: "光晕强度"
        case .filmScatterStrength: "散射强度"
        case .filmCouplersStrength: "成色剂强度"
        case .filmGlareStrength: "耀光强度"
        case .latitudeBelow: "低于"
        case .latitudeWithin: "范围内"
        case .latitudeAbove: "高于"
        case .latitudeHeld: "档保留"
        case .latitudeFullSeparation: "完整层次"
        case .latitudeEmpty: "显影后即可按当前胶片与相纸测量。"
        case .placementHighlight: "高光"
        case .placementShadow: "阴影"
        case .maskEnable: "启用"
        case .maskHighlights: "高光"
        case .maskShadows: "阴影"
        case .maskCore: "核心"
        case .maskRadius: "半径"
        case .maskCurveCaption: "按模糊后负片的曝光量计算的相纸曝光变化（档）"
        case .enlargerPreflash: "预曝光"
        case .helpResetFilmFormat: "重置胶片画幅与效果"
        case .helpResetPlacement: "关闭场景置位"
        case .helpResetToneMask: "重置影调蒙版"
        case .helpResetEnlarger: "将放大机恢复为配光结果"
        case .helpSubLayerGrain: "分层颗粒模型"
        case .reasonPrintEffectsOff: "“相纸效果”已在相纸部分关闭。"
        case .reasonNotDeveloped: "请先显影。"
        case .setResetLayout: "重置全部布局"
        case .setResetLayoutCaption: "将面板宽度、各部分高度与展开状态恢复为默认。"
        case .setTabGeneral: "常规"
        case .setTabRendering: "渲染"
        case .setTabMemory: "内存"
        case .setTabDiagnostics: "诊断"
        case .setTabAgents: "智能体"
        case .setInterface: "界面"
        case .setScale: "缩放"
        case .setScaleCaption: "同步调整主界面、设置与导出页的字体大小；更改立即生效。"
        case .setAgentsAccess: "访问"
        case .setAgentsToggle: "允许命令行与智能体访问"
        case .setAgentsToggleCaption: "允许 spektralab 命令与 MCP 智能体（Claude Code、Claude Desktop 或任何 MCP 客户端）在本机打开、编辑、冲印与导出照片——与本窗口的编辑完全相同，并保存在本窗口读取的位置。关闭时所有调用都会被拒绝，包括已连接的智能体。仅限本机：不监听网络，也从不改写原片。"
        case .setAgentsCommandLine: "命令行"
        case .setAgentsInstall: "安装 spektralab"
        case .setAgentsReinstall: "重新安装"
        case .setAgentsUninstall: "移除"
        case .setAgentsInstalled: "已安装"
        case .setAgentsNotInstalled: "未安装"
        case .setAgentsInstalledOther: "已为另一份应用安装"
        case .setAgentsInstallCaption: "在 ~/.local/bin/spektralab 写入一个两行脚本，以无窗口方式运行本应用。可先试 `spektralab help`；每条命令都输出 JSON。"
        case .setAgentsMCP: "MCP 服务"
        case .setAgentsClaudeCode: "Claude Code"
        case .setAgentsClaudeDesktop: "Claude Desktop"
        case .setAgentsMCPCaption: "用以下任一方式把 SpektraLab 添加给智能体。服务由智能体在需要时通过 stdio 自行启动，不在后台常驻。"
        case .setAgentsCopy: "复制"
        case .setAgentsCopied: "已复制"
        case .setAgentsTools: "工具"
        case .sectionCamera: "输入 / 相机"
        case .sectionFilm: "胶片"
        case .sectionPrint: "印相"
        case .sectionCrop: "裁剪"
        case .sectionHistogram: "直方图"
        case .sectionWhiteBalance: "白平衡"
        case .sectionExposure: "曝光"
        case .sectionCurve: "曲线"
        case .sectionColorBalance: "色彩平衡"

        // Camera
        case .cameraMetering: "测光方式"
        case .cameraFilmExposure: "胶片曝光"
        case .cameraFilmExposureAsShot: "拍摄时设置"
        case .cameraTemperature: "色温"
        case .cameraTint: "色调"
        case .cameraVignetting: "暗角"
        case .cameraLensCorrection: "镜头校正"

        // metering
        case .meteringCustom: "自定义"
        case .meteringBalanced: "均衡"
        case .meteringCenter: "中央主体"
        case .meteringProtectHighlights: "保护高光"
        case .meteringProtectShadows: "保护阴影"
        case .meteringCenterWeightedLegacy: "中央重点（旧版）"

        // Film
        case .filmGroupPositive: "正片"
        case .filmGroupNegative: "负片"
        case .filmFormat: "胶片画幅"
        case .filmFormatSide: "基准边"
        case .filmFormatShort: "短边"
        case .filmFormatLong: "长边"
        case .filmFormatSideLength: "边长"
        case .filmGrain: "颗粒"
        case .filmHalation: "光晕"
        case .filmGlare: "耀光"
        case .filmEffectStrength: "强度"
        case .filmGrainLayers: "分层颗粒"
        case .filmScatter: "散射"
        case .filmCouplers: "DIR 成色剂"

        // Print
        case .printGroupStill: "静态摄影"
        case .printGroupCine: "电影"
        case .printNone: "不使用相纸配置"
        case .printEDR: "扩展动态范围（EDR）"

        // Curve
        case .curveLuma: "明度"
        case .curveRed: "红"
        case .curveGreen: "绿"
        case .curveBlue: "蓝"
        case .curveInput: "输入"
        case .curveOutput: "输出"

        // right rail
        case .exposureContrast: "对比度"
        case .exposureBrightness: "亮度"
        case .exposureSaturation: "饱和度"
        case .exposureHighlights: "高光"
        case .exposureShadows: "阴影"
        case .exposureBlackPoint: "黑场"
        case .exposureWhitePoint: "白场"
        case .balanceMidtones: "中间调"

        // Crop
        case .cropAspect: "宽高比"
        case .cropAspectFree: "自由"
        case .cropAspectOriginal: "原始比例"
        case .cropStraighten: "拉直"
        case .cropStraightenUnit: "度"
        case .cropRotate: "旋转"

        // actions
        case .actionDeveloped: "显影效果"
        case .actionOriginal: "原图"
        case .actionSolve: "配光"
        case .actionProcess: "自动测光与配光"
        case .actionRestart: "重新启动"

        // help
        case .helpOpen: "打开文件夹或图像"
        case .helpExport: "导出"
        case .helpSelect: "选择"
        case .helpPan: "平移"
        case .helpBeforeAfter: "原图 / 效果对比 — 在画布上拖动分界线"
        case .helpZoomIn: "放大"
        case .helpZoomOut: "缩小"
        case .helpFit: "适合窗口"
        case .helpFullScreenEnter: "进入全屏"
        case .helpFullScreenLeave: "退出全屏"
        case .helpDevelopRailHide: "隐藏显影栏"
        case .helpDevelopRailShow: "显示显影栏"
        case .helpEditRailHide: "隐藏调整栏"
        case .helpEditRailShow: "显示调整栏"
        case .helpPickNeutral: "在图像中选取中性色"
        case .helpWhiteBalancePreset: "白平衡预设"
        case .helpReset: "重置"
        case .helpResetFilmExposure: "重置胶片曝光"
        case .helpResetChannels: "重置所有通道"
        case .helpResetCrop: "重置裁剪"
        case .helpStraightenZero: "拉直到 0°"
        case .helpCropWholeFrame: "恢复完整画面"
        case .helpRevealInFinder: "在 Finder 中显示"
        case .helpResetDefaults: "恢复默认设置"
        case .helpUseFilmPaper: "使用胶片预设的相纸"
        case .helpAllEffectsOn: "开启所有效果"
        case .helpAllEffectsOff: "关闭所有效果"
        case .helpResetEffectStrengths: "将效果强度恢复为胶片默认值"
        case .helpFastFlip: "快速切换（使用预烘焙 LUT，不含耀光，忽略印相调整）"

        // status and reasons
        case .statusFull: "全分辨率"
        case .statusFullPending: "全分辨率处理中…"
        case .statusEmptyFilmstrip: "将文件夹或图像拖到此处，或按 ⌘O。"
        case .statusEDRScope: "影响渲染结果：画布、软打样和导出文件同步变化。"
        case .statusRightRailWBScope: "对印相扫描结果进行调整。"
        case .reasonDecodeWBDisabled: "仅 RAW 图像支持调整解码白平衡。"
        case .reasonNonCustomSideLength: "选择“自定义”画幅后可修改边长。"
        case .reasonEffectOff: "开启该效果后可调节强度。"
        case .reasonPositiveFilmDisablesPaper: "正片无需相纸印相。选择负片后可使用相纸配置。"
        case .reasonEDRDisabledInScanFilm: "扩展动态范围仅适用于相纸印相。"

        // Settings ▸ Language
        case .setLanguage: "语言"
        case .setLanguageCaption:
            "胶片、相纸、相机与镜头名称以及技术缩写保持英文。切换立即生效，无需重新启动。"
        case .languageFollowSystem: "跟随系统"
        }
    }
}

// MARK: - the lookup

/// Look up `key` in the active language.
///
/// The read of `Localization.shared.resolved` is not an optimisation to be
/// hoisted — it **is** the mechanism. `resolved` is computed from the
/// `@Observable` `language` setting, so a call made inside a view's `body`
/// registers that view as a dependent of it, and assigning a new language is
/// what makes every label in the window repaint. A lookup that cached its
/// answer, or read a plain global, would leave the interface in the old
/// language until something else invalidated it.
///
/// Fallbacks, in order: the active language, then English, then the key's own
/// name. The switches in `S` have no `default:`, so a *missing* translation is
/// a build error and the only way to reach the fallback is an entry that was
/// deliberately or accidentally left blank — which is what the emptiness check
/// below is for. It never returns an empty string.
@MainActor
func L(_ key: S) -> String {
    switch Localization.shared.resolved {
    case .english:
        return key.english.nilIfEmpty ?? key.rawValue
    case .simplifiedChinese:
        return key.simplifiedChinese.nilIfEmpty
            ?? key.english.nilIfEmpty
            ?? key.rawValue
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - enums whose own `title` is a display string

//  Four enums carry their display name themselves rather than being given one
//  by a view. Two of them are **asserted by name in the test suite**
//  (`WhiteBalanceTests` pins `ExposureMethod.title`'s lowercase English, and
//  `title(forWire:)` falls back to the raw wire value for a method it does not
//  know), so none of them is rewritten here: the mapping to a key lives beside
//  the table instead, and a view asks for `L(x.key)`.
//
//  That also keeps `Model/` free of the main actor — every one of these is a
//  `nonisolated` computed property on a `Sendable` enum, which is what lets it
//  be read from a `PillMenu`'s `(T) -> String`.

extension AEMethod {
    /// The metering pill's name for this method.
    ///
    /// `ExposureMethod.title` is lowercase ("balanced") and the pill used to
    /// capitalise it; the table's English is already the capitalised form, so
    /// the call site needs no `capitalizedFirst`. The Chinese has no case, so
    /// nothing is lost by the two agreeing on one form.
    var key: S {
        switch self {
        case .custom: .meteringCustom
        case .metered(.balanced): .meteringBalanced
        case .metered(.center): .meteringCenter
        case .metered(.protectHighlights): .meteringProtectHighlights
        case .metered(.protectShadows): .meteringProtectShadows
        case .legacy: .meteringCenterWeightedLegacy
        }
    }
}

extension FilmSide {
    var key: S { self == .short ? .filmFormatShort : .filmFormatLong }
}

extension CropAspect {
    /// `nil` for a ratio. `1:1`, `3:2`, `16:9` and the rest are aspect ratios,
    /// which the spec keeps as they are; they have no translation and the view
    /// falls back to `label`.
    ///
    /// The ratio cases are written out rather than covered by a `default:` so
    /// that a new *translatable* case cannot arrive silently — it would have
    /// to be given a key or explicitly listed as English here.
    var key: S? {
        switch self {
        case .free: .cropAspectFree
        case .original, .originalPortrait: .cropAspectOriginal
        case .square, .r3x2, .r2x3, .r4x3, .r3x4,
             .r16x9, .r9x16, .r5x4, .r4x5, .r7x5, .r5x7: nil
        }
    }
}

extension CurveChannel {
    /// `nil` for `rgb`: RGB is on the spec's retain-English list, so the
    /// channel has no translation and shows its own `title`.
    var key: S? {
        switch self {
        case .luma: .curveLuma
        case .red: .curveRed
        case .green: .curveGreen
        case .blue: .curveBlue
        case .rgb: nil
        }
    }
}

// MARK: - catalogue group headers

//  Film and paper lists are grouped, and a group's title comes from the
//  catalogue rather than from the view — `StockCatalog.filmGroups` returns
//  "Positive"/"Negative" and `paperGroups` "Still"/"Cine". Those four are the
//  spec's rows, so they are translated.
//
//  The title is also the row's **identity** — `"__group_" + group.title` — so
//  nothing here renames a group. These take the catalogue's title and return a
//  *label*; the id keeps the English in every caller.
//
//  An unknown title comes back unchanged, which is a real branch rather than a
//  formality: a catalogue that grows a third group gets its own name in both
//  languages rather than an empty header or a crash.

/// A film-list group header — Positive / Negative.
@MainActor func L(filmGroup title: String) -> String {
    switch title {
    case "Positive": return L(.filmGroupPositive)
    case "Negative": return L(.filmGroupNegative)
    default: return title
    }
}

/// A paper-list group header — Still / Cine.
@MainActor func L(paperGroup title: String) -> String {
    switch title {
    case "Still": return L(.printGroupStill)
    case "Cine": return L(.printGroupCine)
    default: return title
    }
}
