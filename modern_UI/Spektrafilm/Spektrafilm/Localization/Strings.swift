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
    case actionDeveloped, actionOriginal, actionProcess, actionRestart

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
    case helpAllEffectsOn, helpAllEffectsOff, helpFastFlip

    // MARK: status and disabled reasons
    case statusFull, statusFullPending, statusEmptyFilmstrip
    case statusEDRScope, statusRightRailWBScope
    case reasonDecodeWBDisabled, reasonNonCustomSideLength
    case reasonPositiveFilmDisablesPaper, reasonEDRDisabledInScanFilm

    // MARK: the Settings page's Language section
    case setLanguage, setLanguageCaption, languageFollowSystem
}

// MARK: - the table

extension S {
    /// English. Exhaustive, so this is also the list of what the app can say.
    var english: String {
        switch self {
        // rails and sections
        case .railDevelop: "Develop"
        case .railEdit: "Edit"
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
        case .helpFastFlip: "快速切换（使用预烘焙 LUT，不含耀光，忽略印相调整）"

        // status and reasons
        case .statusFull: "全分辨率"
        case .statusFullPending: "全分辨率处理中…"
        case .statusEmptyFilmstrip: "将文件夹或图像拖到此处，或按 ⌘O。"
        case .statusEDRScope: "影响渲染结果：画布、软打样和导出文件同步变化。"
        case .statusRightRailWBScope: "对印相扫描结果进行调整。"
        case .reasonDecodeWBDisabled: "仅 RAW 图像支持调整解码白平衡。"
        case .reasonNonCustomSideLength: "选择“自定义”画幅后可修改边长。"
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
