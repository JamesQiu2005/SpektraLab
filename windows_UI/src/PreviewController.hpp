#pragma once
#include "desktop/preview_host.hpp"
#include "desktop/raw_white_balance.hpp"
#include "FrameOutput.hpp"
#include "EditStore.hpp"
#include "Messages.hpp"
#include "PostDevSurfaces.hpp"
#include "Library.hpp"
#include "SettingsClipboard.hpp"
#include <QImage>
#include <QSet>
#include <QThreadPool>
#include <memory>
#include <optional>
#include <QPointF>
#include <QObject>
#include <QPointF>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>

class PreviewController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY stateChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY frameChanged)
    Q_PROPERTY(bool failed READ failed NOTIFY stateChanged)
    Q_PROPERTY(bool dirty READ dirty NOTIFY settingsChanged)
    Q_PROPERTY(bool settingsEditable READ settingsEditable NOTIFY stateChanged)
    Q_PROPERTY(bool filmIsPositive READ filmIsPositive NOTIFY settingsChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString fileName READ fileName NOTIFY frameChanged)
    Q_PROPERTY(QUrl sourceFolder READ sourceFolder NOTIFY frameChanged)
    // The canvas's picture: the developed frame after geometry, RGBX16FPx4
    // tagged with the session's encoding (FrameImage.hpp).
    Q_PROPERTY(QImage previewImage READ previewImage NOTIFY frameChanged)
    // previewImage reduced to a long edge of at most 1024 px (area average,
    // same tag), for the navigator: a second full-size texture is 264 MB at
    // 33 MP. Changes whenever previewImage does.
    Q_PROPERTY(QImage navigatorImage READ navigatorImage NOTIFY frameChanged)
    Q_PROPERTY(QVariantMap metadata READ metadata NOTIFY frameChanged)
    Q_PROPERTY(QVariantList films READ films NOTIFY catalogChanged)
    Q_PROPERTY(QVariantList papers READ papers NOTIFY catalogChanged)
    Q_PROPERTY(int filmIndex READ filmIndex WRITE setFilmIndex NOTIFY settingsChanged)
    Q_PROPERTY(int paperIndex READ paperIndex WRITE setPaperIndex NOTIFY settingsChanged)
    Q_PROPERTY(int decodeMode READ decodeMode WRITE setDecodeMode NOTIFY settingsChanged)
    // Print brightness in stops, brighter positive, -3..3 as macOS's Enlarger
    // slider (EnlargerSection.swift:34-37); print_exposure is 2^-stops.
    Q_PROPERTY(double exposureEv READ exposureEv WRITE setExposureEv NOTIFY settingsChanged)
    Q_PROPERTY(QVariantMap adjustments READ adjustments NOTIFY settingsChanged)
    // Every row of the desktop settings table (preview_host.hpp), by wire
    // name: the current wanted values, and each row's type, range, choices
    // and initial value. A new control binds to these and calls setParameter.
    Q_PROPERTY(QVariantMap parameters READ parameters NOTIFY settingsChanged)
    Q_PROPERTY(QVariantList parameterFields READ parameterFields CONSTANT)
    // The macOS Film and Print sections' lists, in its groups and order
    // (StockCatalog.filmGroups / paperGroups). `films`/`papers` above keep
    // their label order and indexes; each entry here names its `index` there.
    //   filmCatalog:  {id, name, group: "positive"|"negative"|"blackAndWhite",
    //                  positive, monochrome, cine, targetPrint, index}
    //   paperCatalog: {id, name, group: "still"|"cine"|"positive", monochrome,
    //                  cine, index, printable, enabled, declared, reason:
    //                  ""|"positiveFilm"|"silverPaper"|"colourPaper",
    //                  noPrintProfile} -- the last entry is macOS's "No Print
    //                  Profile" row, id "__scan_film__", group "positive".
    // A paper is `printable` by StockCatalog.canPrint and `enabled` when the
    // film is also not a slide; `declared` is the film's own paper.
    Q_PROPERTY(QVariantList filmCatalog READ filmCatalog NOTIFY catalogChanged)
    Q_PROPERTY(QVariantList paperCatalog READ paperCatalog NOTIFY settingsChanged)
    Q_PROPERTY(bool filmIsMonochrome READ filmIsMonochrome NOTIFY settingsChanged)
    // The print list's selected row: "__scan_film__" while the film is
    // scanned (a slide, or No Print Profile), else the paper's id.
    Q_PROPERTY(QString printSelection READ printSelection NOTIFY settingsChanged)
    Q_PROPERTY(bool noPrintProfile READ noPrintProfile NOTIFY settingsChanged)
    Q_PROPERTY(bool canUseFilmPaper READ canUseFilmPaper NOTIFY settingsChanged)
    // The Camera section's AE Method pill (Params.swift AEMethod): "custom" is
    // the meter switched off (auto_exposure false), the four intents meter
    // with auto_exposure_method, and "legacy" -- read only -- is a record
    // metered with an engine name the pill does not offer.
    Q_PROPERTY(QString aeMethod READ aeMethod WRITE setAeMethod NOTIFY settingsChanged)
    Q_PROPERTY(QStringList aeMethodChoices READ aeMethodChoices CONSTANT)
    Q_PROPERTY(QVariantList libraryItems READ libraryItems NOTIFY libraryChanged)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY libraryChanged)
    Q_PROPERTY(int selectedCount READ selectedCount NOTIFY libraryChanged)
    Q_PROPERTY(QImage uncroppedImage READ uncroppedImage NOTIFY frameChanged)
    Q_PROPERTY(QRectF cropRect READ cropRect WRITE setCropRect NOTIFY geometryChanged)
    Q_PROPERTY(bool batchExporting READ batchExporting NOTIFY stateChanged)
    Q_PROPERTY(int batchProgress READ batchProgress NOTIFY stateChanged)
    Q_PROPERTY(int batchTotal READ batchTotal NOTIFY stateChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY historyChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY historyChanged)
    Q_PROPERTY(QString persistenceWarning READ persistenceWarning NOTIFY stateChanged)
    Q_PROPERTY(QString savedStatus READ savedStatus NOTIFY stateChanged)
    Q_PROPERTY(int quarterTurns READ quarterTurns NOTIFY geometryChanged)
    Q_PROPERTY(bool flipHorizontal READ flipHorizontal NOTIFY geometryChanged)
    Q_PROPERTY(bool flipVertical READ flipVertical NOTIFY geometryChanged)
    Q_PROPERTY(double straightenDegrees READ straightenDegrees NOTIFY geometryChanged)
    // The export page's proof (ExportPage.swift's centre pane): the displayed
    // frame at navigator size, through the same conversion the file gets,
    // tagged with the destination space. exportProofInfo: {space, clipped,
    // identity, digitalIntermediate}.
    Q_PROPERTY(QImage exportProof READ exportProof NOTIFY exportProofChanged)
    Q_PROPERTY(QVariantMap exportProofInfo READ exportProofInfo NOTIFY exportProofChanged)
    // --- the Pre-Dev rail (PreviewControllerPredev.cpp) ---------------------
    // The Camera section's white balance (WhiteBalanceRows.swift): a decode
    // setting, so an edit re-decodes the RAW. {mode: as_shot|daylight|cloudy|
    // shade|tungsten|fluorescent|custom, temperature, tint (what the decode
    // uses: the camera's under As Shot), temperatureAsShot, tintAsShot (the
    // two boxes), asShotKnown, asShotTemperature, asShotTint, enabled (false
    // only for a camera LibRaw has no matrix for), boxesEnabled (a camera
    // pair is known), temperatureFrom/To 2000/12000, tintFrom/To -150/150
    // (macOS's sliders), temperatureZero/tintZero (their zero ticks: the
    // camera's pair, else 5500/0), pickAvailable}.
    Q_PROPERTY(QVariantMap whiteBalance READ whiteBalance NOTIFY settingsChanged)
    // The Camera menu's presets, macOS's order: [{id, label, kelvin (0 for
    // As Shot)}] -- every mode but Custom (CameraSection.swift:128-137).
    Q_PROPERTY(QVariantList whiteBalancePresets READ whiteBalancePresets CONSTANT)
    // Process (TopBar.swift:81, Session.solveNow): a frame shown, nothing in flight.
    Q_PROPERTY(bool canProcess READ canProcess NOTIFY stateChanged)
    // The meter's report for the frame on screen, from spk_solve after each
    // develop (Session.swift:2314-2329) and from Process: {available,
    // exposureEv (the session's metering intent; macOS's "auto +0.3 EV"),
    // label, byMethod {balanced, center, protect_highlights,
    // protect_shadows}, filters {c, m, y} (after Process: the neutral pack
    // the engine solved for this film and paper), solveMs}.
    Q_PROPERTY(QVariantMap metering READ metering NOTIFY settingsChanged)
    // The Latitude section (LatitudeSection.swift), for a QML Canvas:
    // {available, failure (why not, in the engine's words), failureKind:
    // ""|"unmeasurable"|"noLight"|"other", axisFrom -8, axisTo 8, centres[],
    // fractions[] (the frame after the committed placement), binWidth,
    // shadowEv, highlightEv, heldStops, below, within, above (0..1),
    // separation [{ev, strength 0..1}], hasCore, coreFrom, coreTo, under,
    // over (past the axis), summary ("4.31 stops held · ..."), film, paper,
    // scanned, analysisMs, current (measured on the very frame shown; false
    // while a newer render of the photograph is still being measured)}.
    Q_PROPERTY(QVariantMap latitude READ latitude NOTIFY settingsChanged)
    // Scene Placement (ParameterSections.swift:212-258): {enabled (a
    // measurement of these controls is in hand: false after a film, paper,
    // enlarger or decode edit until its render is measured; a placement
    // step itself keeps it), active, highlight, shadow (the
    // committed pull-backs, stops), from 0, to 8, highlightWindow,
    // shadowWindow ({hasSpan, from, to, below, above}: the band the Fit
    // takes, the other side held), highlightMessage, shadowMessage (why the
    // row stopped, or why no pull-back works; "" otherwise), refusal
    // ({code, side, message} or null)}.
    Q_PROPERTY(QVariantMap scenePlacement READ scenePlacement NOTIFY settingsChanged)
    // The Tone Mask section (ParameterSections.swift:272-323): {allowed
    // (Print Effects on), reason ("printEffectsOff" or ""), active,
    // rowsEnabled (allowed and active), highlights, shadows, core, scale,
    // radiusPercent (scale x 100, the Radius slider), radiusFrom 0.2,
    // radiusTo 12, curve [{x, y}] (x -6..6 stops of blurred negative, y the
    // change in paper exposure clamped to -3..3, ToneMaskPlot), isDefault}.
    Q_PROPERTY(QVariantMap toneMask READ toneMask NOTIFY settingsChanged)
    // --- canvas tools (FrameImage.hpp histogram / originalImage) ---
    // 4 x 256 normalised bins (R, G, B, luma) of what each surface shows: the
    // print as cropped (previewImage) -- not the uncropped print the Mac's
    // histogram counts (AGENTS.md trap 33) -- and the whole source the crop
    // editor shows (uncroppedImage). Made on the worker with the images, and
    // on the GUI thread from the new previewImage after a geometry edit.
    // With a Post-Dev grade, the histogram counts the graded navigator image
    // (PreviewControllerPostDev.cpp), as the canvas shows it graded.
    Q_PROPERTY(QList<double> histogram READ histogram NOTIFY histogramChanged)
    Q_PROPERTY(QList<double> uncroppedHistogram READ uncroppedHistogram NOTIFY frameChanged)
    // The Original (macOS TopBar "Original", Space, and the left of the
    // before/after split): the decode before any film simulation, tagged like
    // the print and with the print's geometry, so the two share size, crop,
    // turn and display transform. Made on the worker, on demand: while the
    // canvas wants it (originalWanted), it is kept current with the frame
    // and the geometry; originalPending while a new one is on its way.
    Q_PROPERTY(bool originalWanted READ originalWanted WRITE setOriginalWanted NOTIFY originalChanged)
    Q_PROPERTY(QImage originalImage READ originalImage NOTIFY originalChanged)
    Q_PROPERTY(bool originalReady READ originalReady NOTIFY originalChanged)
    Q_PROPERTY(bool originalPending READ originalPending NOTIFY originalChanged)
    Q_PROPERTY(QList<double> originalHistogram READ originalHistogram NOTIFY originalChanged)
    // Film Edge and Date Back (FilmEdgeSection.swift, DateBackSection.swift).
    // Their controls are settings rows (overscan_*, date_imprint_*,
    // date_back_*, read through `parameters` and written with setParameter);
    // these are what the sections show beside them:
    //   filmFormats  the Format menu: {id, title, group: "135"|"120"|
    //                "panoramic", gate ("36 x 24"), ratio, stripCost, filedCost}
    //   filmEdge     {active, edgeText, fNumber, pictureWidth, pictureHeight,
    //                filmWidth, filmHeight, filmMeasured, upright, gateRatio,
    //                shown, canvasWidth, canvasHeight, gates: [[8 numbers]]} --
    //                the picture's pixels and the film around them (measured
    //                from spk_overscan_geometry once a render of this framing
    //                has landed, else macOS's FilmCanvasEstimate); `gates` are
    //                the gate quads normalised to the shown frame
    //   dateBack     {camera, cameraTitle, cameraFromEdge, hasBack, effective,
    //                printsInMargin, prints: {lcd, dots, data}, onCamera:
    //                {lcd, dots, data}, exifDate, hasExifDate, examples:
    //                {japan, us}, printed, dataText, dataPrintable, turned,
    //                sizeMax}
    //   frameIsCut   the shown frame carries the crop (the engine was handed
    //                the picture cut by it): no geometry is applied over it
    //   geometryInNegative  the wanted settings cut the frame: a crop, turn or
    //                flip re-develops instead of re-sampling the print
    //   cropLockRatio  the gate's width / height in source pixels while a film
    //                edge holds the crop (0: free), for the crop editor's drag
    Q_PROPERTY(QVariantList filmFormats READ filmFormats CONSTANT)
    Q_PROPERTY(QVariantMap filmEdge READ filmEdge NOTIFY filmEdgeChanged)
    Q_PROPERTY(QVariantMap dateBack READ dateBack NOTIFY filmEdgeChanged)
    Q_PROPERTY(bool frameIsCut READ frameIsCut NOTIFY frameChanged)
    Q_PROPERTY(bool geometryInNegative READ geometryInNegative NOTIFY filmEdgeChanged)
    Q_PROPERTY(double cropLockRatio READ cropLockRatio NOTIFY filmEdgeChanged)
    // --- Post-Dev, Layer 2 (PreviewControllerPostDev.cpp) -------------------
    // The open photograph's grade in the edit store's `state.postDev` shape
    // (PostDev.hpp; the Mac sidecar's `adjustments`): enabled, temperature,
    // tint, exposure, contrast, brightness, saturation, highlights, shadows,
    // blackPoint, whitePoint, curves {rgb, luma, red, green, blue: {points:
    // [[x, y], ...]}}, colorBalance {master, shadows, midtones, highlights:
    // {hue, saturation, luminance}}, vignette {amount, midpoint}. FrameCanvas
    // takes it as is (its `postDev`).
    Q_PROPERTY(QVariantMap postDev READ postDev NOTIFY postDevChanged)
    Q_PROPERTY(bool postDevEnabled READ postDevEnabled NOTIFY postDevChanged)
    // Every field at its default, `enabled` aside (Adjustments.isNeutral).
    Q_PROPERTY(bool postDevNeutral READ postDevNeutral NOTIFY postDevChanged)
    // Where previewImage (and navigatorImage) sit on the uncropped source:
    // FrameCanvas's `sourceMap` (PostDevView.hpp), for the vignette.
    Q_PROPERTY(QVariantList postDevSourceMap READ postDevSourceMap NOTIFY frameChanged)
    // The scalar controls: [{path, from, to, initial, snap}] (postdev::fields).
    Q_PROPERTY(QVariantList postDevFields READ postDevFields CONSTANT)
    // --- half-frame pairs (PreviewControllerPairs.cpp) -----------------------
    // The pair on the canvas (HalfFramePair.swift, PairSection.swift), or
    // {active: false}: {active, title, turned, spacing (the gap used), userSpacing,
    // onStrip, complete, filled, layer: "film"|"first"|"second", cameraSide
    // ("first"|"second"|""), placing (crop mode inside a hole), holes: [{side,
    // filled, exists, name, path, rect: {x, y, width, height} normalised to the
    // shown frame, placement: {scale, x, y, quarterTurns}, ownPrint, printScope,
    // exposureScope: "frame"|"film", metered}] x2, drag: {active, side, scale,
    // offsetX, offsetY} (the gesture's motion of the hole's picture, u -> u*scale
    // + offset), candidates: [{index, name, used}] (the folder's photographs)}.
    Q_PROPERTY(QVariantMap pair READ pair NOTIFY pairChanged)
    // New Half-Frame Pair (Ctrl+J) and Enter Half-Frame Pair (Film Edge on Half).
    Q_PROPERTY(bool canMakePair READ canMakePair NOTIFY pairChanged)
    Q_PROPERTY(bool canEnterPair READ canEnterPair NOTIFY pairChanged)
    // What the canvas and the navigator grade with: postDev, except on a pair
    // whose frames grade for themselves -- its picture (previewImage) is then
    // graded frame by frame already and the canvas adds none (Session.swift
    // canvasAdjustments :2604-2607, pairLayered :5117-5159).
    Q_PROPERTY(QVariantMap canvasPostDev READ canvasPostDev NOTIFY postDevChanged)
    // --- the library and the settings clipboard (PreviewControllerLibrary.cpp)
    // The Settings Clipboard section's boxes (ClipboardSection.swift): each
    // {id, ticked} in the section's order, ticked = what the next Copy or
    // Sync takes; persisted beside the edits.
    Q_PROPERTY(QVariantList clipboardGroups READ clipboardGroups NOTIFY clipboardChanged)
    // What the section reads off the clipboard and the selection: holds,
    // source, groups (held), canCopy, canPaste, canSync, pasteTargets,
    // syncTargets (Session.canCopySettings ... syncTargets, :3736-3770).
    Q_PROPERTY(QVariantMap clipboard READ clipboardState NOTIFY clipboardChanged)
    // How many library items still wait for their file's own picture.
    Q_PROPERTY(int previewsPending READ previewsPending NOTIFY libraryChanged)
    // The filmstrip reads one item at a time (libraryItem): the count is its
    // model, and the revision -- bumped by every libraryChanged -- what makes
    // each cell read its item again, without rebuilding the whole list per
    // cell or recreating the cells (a drag in flight keeps its own).
    Q_PROPERTY(int libraryCount READ libraryCount NOTIFY libraryChanged)
    Q_PROPERTY(int libraryRevision READ libraryRevision NOTIFY libraryChanged)
public:
    // Makes the full display image of a frame. Called on the worker thread,
    // after the render and before the reply is queued; a throw fails the
    // operation and keeps the displayed frame (the self-test injects one).
    using ImageFactory=std::function<QImage(const spk::desktop::FramePtr&)>;
    // `outputColorSpace` empty: the host's display default (sRGB). Anything
    // else is requested of every session, for tests of the tagging path;
    // what the frame is tagged with is still what the engine reports.
    explicit PreviewController(std::filesystem::path resources, QObject* parent=nullptr, ImageFactory imageFactory={},
                               QString editDirectory={}, QString outputColorSpace={});
    static QImage imageFromFrame(const spk::desktop::FramePtr&);
    ~PreviewController() override;
    bool ready() const { return ready_; }
    bool busy() const { return busy_; }
    bool hasFrame() const { return bool(frame_); }
    bool failed() const { return failed_; }
    bool dirty() const;
    bool settingsEditable() const { return ready_&&!dialog_open_&&(!busy_||active_operation_=="render"); }
    bool filmIsPositive() const;
    QString status() const { return status_; }
    QString fileName() const;
    QUrl sourceFolder() const;
    QImage previewImage() const { return image_; }
    QImage navigatorImage() const { return navigator_; }
    QVariantMap metadata() const;
    QVariantList films() const { return films_; }
    QVariantList papers() const { return papers_; }
    int filmIndex() const { return film_index_; }
    int paperIndex() const { return paper_index_; }
    int decodeMode() const { return decode_mode_; }
    double exposureEv() const { return exposure_ev_; }
    QVariantMap adjustments() const;
    QVariantMap parameters() const;
    QVariantList parameterFields() const;
    QVariantList filmCatalog() const;
    QVariantList paperCatalog() const;
    bool filmIsMonochrome() const;
    QString printSelection() const;
    bool noPrintProfile() const;
    bool canUseFilmPaper() const;
    QString aeMethod() const;
    QStringList aeMethodChoices() const;
    void setAeMethod(const QString& value);
    QVariantList libraryItems() const;
    int activeIndex() const { return active_index_; }
    int selectedCount() const;
    // A cut frame's uncropped picture is the undeveloped decode (the guide
    // the crop editor frames over); any other frame's is the whole print.
    QImage uncroppedImage() const { return frame_&&frame_->cut&&!source_image_.isNull()?source_image_:full_image_; }
    QVariantList filmFormats() const;
    QVariantMap filmEdge() const;
    QVariantMap dateBack() const;
    bool frameIsCut() const { return frame_&&frame_->cut; }
    bool geometryInNegative() const;
    double cropLockRatio() const;
    QRectF cropRect() const { return geometry_.crop; }
    int quarterTurns() const { return geometry_.quarterTurns; }
    bool flipHorizontal() const { return geometry_.flipHorizontal; }
    bool flipVertical() const { return geometry_.flipVertical; }
    double straightenDegrees() const { return geometry_.straightenDegrees; }
    QList<double> histogram() const { return bins(graded_histogram_.empty()?histogram_:graded_histogram_); }
    QList<double> uncroppedHistogram() const { return bins(uncropped_histogram_); }
    bool originalWanted() const { return original_wanted_; }
    void setOriginalWanted(bool wanted);
    QImage originalImage() const { return original_; }
    bool originalReady() const { return !original_.isNull(); }
    bool originalPending() const { return original_pending_; }
    QList<double> originalHistogram() const { return bins(original_histogram_); }
    bool canUndo() const;
    bool canRedo() const;
    QString persistenceWarning() const;
    QString savedStatus() const;
    bool batchExporting() const { return busy_ && active_operation_=="batch-export"; }
    int batchProgress() const { return batch_progress_; }
    int batchTotal() const { return batch_total_; }
    void setFilmIndex(int value);
    void setPaperIndex(int value);
    void setDecodeMode(int value);
    void setExposureEv(double value);
    spk::desktop::FramePtr frame() const { return frame_; }
    Q_INVOKABLE void openRaw(const QUrl& path);
    // Files and folders (Session.open(urls:)): a folder brings every file it
    // holds that opens (Library.frames(at:): not its subfolders), in Finder's
    // order with the folder's kept order laid over it (FrameOrder), and the
    // first of them opens. Refused while anything runs, a batch export first.
    Q_INVOKABLE void openFiles(const QVariantList& urls);
    Q_INVOKABLE void openFolder(const QUrl& folder);
    // The photograph on the canvas, the picked set untouched (Session.select);
    // the filmstrip's clicks are clickPhoto.
    Q_INVOKABLE void selectImage(int index);
    // A left click on a thumbnail (Session.click, :1409-1444): a plain click
    // picks exactly this photograph and opens it; with Ctrl it joins or
    // leaves the picked set and the canvas stays where it is -- the open
    // photograph cannot leave the set. No-ops during a batch export.
    Q_INVOKABLE void clickPhoto(int index, bool command);
    // The chevrons and Left/Right (Session.selectRelative): a plain click on
    // the neighbour, clamped at the ends.
    Q_INVOKABLE void stepPhoto(int delta);
    // A thumbnail dragged along the strip (Session.moveFrame, :2629-2641):
    // `from` takes `to`'s place. itemOrderChanged() when it is let go keeps
    // the order for its folder (FrameOrder.save). Refused while anything runs.
    Q_INVOKABLE bool moveItem(int from, int to);
    Q_INVOKABLE void itemOrderChanged();
    // The settings clipboard (SettingsClipboard.swift, RFC-027).
    Q_INVOKABLE void setClipboardGroup(const QString& id, bool ticked);
    // Ctrl+Shift+C: the ticked groups of the photograph on the canvas.
    Q_INVOKABLE bool copySettings();
    // Ctrl+Shift+V: what the clipboard holds onto every picked photograph
    // (the open one live, as one undo step; the others in their records,
    // each with its own undo step), or onto the open one when none is
    // picked. Returns how many photographs changed.
    Q_INVOKABLE int pasteSettings();
    // Several settings rows as ONE edit -- one undo step, one render: the
    // QML actions that set more than one row at once (Film Exposure's As
    // Shot, Film Format's Reset and effect switches). Keys are wire names as
    // setParameter takes them; film_stock goes before print_stock, the rest
    // in the map's order. Every value's type, range and choices are checked
    // first: an unknown key or a bad value refuses the whole edit and changes
    // nothing. A row the editor's own rules then turn down (a paper the film
    // cannot print on, a print exposure for a slide) is skipped and the call
    // returns false; what did apply is still the one step.
    Q_INVOKABLE bool setParameters(const QVariantMap& values);
    // The C++ equivalent, in the order given.
    bool setSettingValues(const std::vector<std::pair<std::string, spk::desktop::SettingValue>>& values);
    Q_INVOKABLE QVariantMap libraryItem(int index) const;
    int libraryCount() const { return int(library_.size()); }
    int libraryRevision() const { return library_revision_; }
    QVariantList clipboardGroups() const;
    QVariantMap clipboardState() const;
    const std::optional<spk::desktop::clipboard::Clip>& heldClip() const { return clip_; }
    int previewsPending() const;
    Q_INVOKABLE void setItemSelected(int index, bool selected);
    Q_INVOKABLE void selectAllPhotos(bool selected);
    Q_INVOKABLE void syncSelectedSettings(bool includeCrop=false);
    // The first QML's camelCase names (adjustments); a wire name works too.
    Q_INVOKABLE void setAdjustment(const QString& name, const QVariant& value);
    // Any settings-table row by wire name. A value of the wrong type, out of
    // range or not among the row's choices is refused (false), as is any
    // edit while settings are locked. An accepted edit is an undo step like
    // any other: between beginEditGesture(key) and endEditGesture() a drag
    // is one step, and the legacy names share the gesture with their keys.
    Q_INVOKABLE QVariant parameter(const QString& key) const;
    Q_INVOKABLE bool setParameter(const QString& key, const QVariant& value);
    // The stock choices with macOS's rules, each one undo step however many
    // settings it moves (Session.swift selectFilmStock, selectPrintStock;
    // filmIndex/paperIndex and setParameter's stocks follow the same rules):
    //  - a film takes its own paper whenever it names one, and a film that
    //    cannot print on the paper it has (colour <-> black and white) takes
    //    its paper or the default one; a slide names none and keeps its paper;
    //  - a paper is refused for a slide film, and when it cannot print the
    //    film (StockCatalog.canPrint); choosing one turns No Print Profile off;
    //  - "__scan_film__" is No Print Profile: scan the film, keep the paper.
    // False when refused or locked.
    Q_INVOKABLE bool selectFilm(const QString& id);
    Q_INVOKABLE bool selectPaper(const QString& id);
    // The Print section's menu item "Use film's paper" (PrintProfileSection
    // .swift:198-207): the film's own paper, printed. Refused for a slide.
    Q_INVOKABLE bool useFilmPaper();
    // The Film section's reset (FilmSection.swift:65-73): Portra 400, and the
    // default paper if the one chosen cannot print it.
    Q_INVOKABLE void resetFilmStock();
    // The Enlarger section's reset (Session.resetEnlarger, HalfFramePair
    // .PrintTrim): brightness, both filter shifts and pre-flash to 0.
    Q_INVOKABLE void resetEnlarger();
    Q_INVOKABLE void setCropRect(const QRectF& crop);
    // The crop editor's commit: the rectangle and the straighten its line
    // gesture set, as one undo step.
    Q_INVOKABLE void setCropGeometry(const QRectF& crop, double straightenDegrees);
    Q_INVOKABLE void resetCrop();
    Q_INVOKABLE void setCropAspect(double ratio);
    Q_INVOKABLE void rotateClockwise();
    Q_INVOKABLE void rotateCounterClockwise();
    Q_INVOKABLE void setFlipHorizontal(bool value);
    Q_INVOKABLE void setFlipVertical(bool value);
    Q_INVOKABLE void setStraightenDegrees(double value);
    Q_INVOKABLE void resetGeometry();
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();
    Q_INVOKABLE void beginEditGesture(const QString& key);
    Q_INVOKABLE void endEditGesture();
    Q_INVOKABLE void flushEdits();
    Q_INVOKABLE void apply();
    Q_INVOKABLE void exportTiff(const QUrl& path);
    Q_INVOKABLE void exportImage(const QUrl& path, int format, int quality, int maxLongEdge);
    Q_INVOKABLE void exportBatch(const QUrl& folder, int format, int quality, int maxLongEdge);
    Q_INVOKABLE void cancelExport();
    // The export page's Export (ExportPage.run): every selected photo -- the
    // displayed one when none is -- under one recipe (ExportRecipe.hpp JSON),
    // one at a time on the worker, as a "batch-export" operation so the open
    // frame and the picked set hold still while it runs (AGENTS.md trap 34).
    // Ends with exportFinished.
    Q_INVOKABLE void exportWithRecipe(const QVariantMap& recipe);
    // Recompute exportProof for a recipe; coalesced, never marks the
    // controller busy.
    Q_INVOKABLE void requestExportProof(const QVariantMap& recipe);
    QImage exportProof() const { return export_proof_; }
    QVariantMap exportProofInfo() const { return export_proof_info_; }
    Q_INVOKABLE void resetSettings();
    Q_INVOKABLE void setDialogOpen(bool open);

    // --- the Pre-Dev rail (PreviewControllerPredev.cpp) ---------------------
    QVariantMap whiteBalance() const;
    QVariantList whiteBalancePresets() const;
    bool canProcess() const;
    QVariantMap metering() const;
    QVariantMap latitude() const;
    QVariantMap scenePlacement() const;
    QVariantMap toneMask() const;
    // White balance, each an undo step (a drag between beginEditGesture and
    // endEditGesture is one; the keys are "white_balance_temperature",
    // "white_balance_tint" and "white_balance"). False when refused: locked,
    // out of range (2000..50000 K, -150..150), an unknown preset, or a camera
    // with no matrix. Session.swift:2781-2814.
    Q_INVOKABLE bool setWhiteBalancePreset(const QString& id);
    Q_INVOKABLE bool setTemperature(double kelvin);
    Q_INVOKABLE bool setTint(double tint);
    Q_INVOKABLE bool setTemperatureAsShot(bool on);
    Q_INVOKABLE bool setTintAsShot(bool on);
    // The neutral picker (Session.pickNeutral): a point normalised to the
    // picture the canvas shows (after crop, straighten, turns and flips),
    // sampled in the decoded RAW (a radius-4 box) on the worker; the answer
    // becomes Custom, one undo step, and the RAW re-decodes. False when it
    // cannot start; neutralPicked reports the outcome.
    Q_INVOKABLE bool pickNeutral(double x, double y);
    // Process (Session.solveNow, :3884-3931): spk_solve "both" on the frame
    // shown -- the meter and the enlarger's neutral pack for this film and
    // paper -- then the Y/M filter shifts back to 0, one undo step, and a
    // reprint. False when it cannot start; processed reports the outcome.
    Q_INVOKABLE bool process();
    // Scene Placement's sliders (Session.placeScene, Latitude.swift:434-461):
    // `moving` is "highlight" or "shadow", the slider under the hand; its
    // value is brought into the band the Fit takes, the curve is solved by
    // the engine's own Fit on the last measurement and committed, an undo
    // step (key "scene_placement"). False while scenePlacement.enabled is
    // false, or when the side that is not moving no longer fits (nothing
    // changes).
    Q_INVOKABLE bool placeScene(double highlight, double shadow, const QString& moving);
    // The sections' resets (ParameterSections.swift:222-225, :282-286).
    Q_INVOKABLE void resetScenePlacement();
    Q_INVOKABLE void resetToneMask();
    // The section switches: switching on takes the crop into the gate (and
    // keeps the user's own to give back), a Date Back switched on takes the
    // first face the camera can print (FilmEdgeSection.setActive,
    // DateBackSection.setActive). setParameter on the same rows does the same.
    Q_INVOKABLE bool setFilmEdgeActive(bool on);
    Q_INVOKABLE bool setDateBackActive(bool on);
    // The Framing row's glyph: the gate upright or across, the picture
    // unturned (Session.flipFilmEdgeGate).
    Q_INVOKABLE void flipFilmEdgeGate();
    // The dice: another camera body (it becomes the user's body for new
    // frames) and another advance of this frame (FilmEdgeSection.swift:205-234).
    Q_INVOKABLE void anotherCameraBody();
    Q_INVOKABLE void anotherFrameAdvance();
    // The user's camera body: the camera seed a new frame takes, kept per user
    // beside the edit store (FilmEdgeSettings.bodySeed), drawn the first time.
    int bodySeed();

    // --- Post-Dev, Layer 2 (PreviewControllerPostDev.cpp) -------------------
    // Every edit is an undo step of the open photograph, saved with it, and
    // needs no render: the canvas grades on the GPU. Between
    // beginEditGesture(key) and endEditGesture() a drag is one step; the keys
    // the rail uses are "postDev.<path>" for a slider, "postDev.curves.<channel>"
    // for a curve drag and "postDev.colorBalance.<zone>" for a wheel drag.
    // False when refused: no photograph, settings locked, an unknown path or
    // channel, a value outside its range.
    spk::desktop::postdev::Params postDevParams() const { return postdev_; }
    QVariantMap postDev() const;
    bool postDevEnabled() const { return postdev_.enabled; }
    bool postDevNeutral() const { return postdev_.isNeutral(); }
    QVariantList postDevSourceMap() const;
    QVariantList postDevFields() const;
    // A scalar by its path ("temperature", "vignette.amount",
    // "colorBalance.shadows.luminance", ...) or "enabled" (a bool).
    Q_INVOKABLE bool setPostDev(const QString& path, const QVariant& value);
    // A wheel drag: one zone's hue and saturation together.
    Q_INVOKABLE bool setColorZone(const QString& zone, double hue, double saturation);
    // A wheel's double-click: the zone back to neutral (hue, saturation and
    // luminance 0), one step.
    Q_INVOKABLE bool resetColorZone(const QString& zone);
    // The section resets: "whiteBalance", "exposure", "curves",
    // "colorBalance", "vignette", or "" for all of it (`enabled` is kept, as
    // Session.resetAdjustments keeps it).
    Q_INVOKABLE void resetPostDev(const QString& group);
    // Bypass (the Mac's Shift-Command-B, Ctrl+Shift+B here): `enabled`
    // toggled, a stored edit that reaches the export too.
    Q_INVOKABLE void togglePostDevBypass();
    // The curve editor (CurveEditor.swift over postdev::Curve). Channels
    // "rgb", "luma", "red", "green", "blue"; points in the unit square, y up.
    Q_INVOKABLE QVariantList curveSamples(const QString& channel, int count) const;
    Q_INVOKABLE double curveValue(const QString& channel, double x) const;
    // The point within 10 px of (x, y) on a plot of width x height, or -1.
    Q_INVOKABLE int curvePointNear(const QString& channel, double x, double y, double width, double height) const;
    Q_INVOKABLE bool curvePointDeletable(const QString& channel, int index) const;
    // Inserted point's index, or -1 (32 points at most, or refused).
    Q_INVOKABLE int insertCurvePoint(const QString& channel, double x, double y);
    Q_INVOKABLE bool moveCurvePoint(const QString& channel, int index, double x, double y);
    Q_INVOKABLE bool removeCurvePoint(const QString& channel, int index);
    Q_INVOKABLE bool resetCurve(const QString& channel);
    // The colour wheel's arithmetic (ColorWheel.swift via postdev::wheel), so
    // QML draws and hit-tests with the model's own numbers. Left = the
    // saturation arc, right = the luminance arc.
    Q_INVOKABLE QVariantMap wheelZoneAt(double x, double y, double diameter) const;
    Q_INVOKABLE QPointF wheelPoint(double hue, double saturation, double diameter) const;
    Q_INVOKABLE double arcTheta(double fraction, bool left) const;
    Q_INVOKABLE double arcValue(double x, double y, double centreX, double centreY, bool left, double low, double high) const;
    Q_INVOKABLE double arcFraction(double value, double low, double high) const;
    // --- half-frame pairs (PreviewControllerPairs.cpp) -----------------------
    QVariantMap pair() const;
    bool canMakePair() const;
    bool canEnterPair() const;
    QVariantMap canvasPostDev() const;
    // Session.newPair (Ctrl+J): the selected photographs fill the holes in the
    // filmstrip's order -- two fill both, one the first, none leaves both
    // empty; the look is the first one's. Session.enterPair: the photograph on
    // the canvas becomes the first frame, its film edge kept on Half.
    Q_INVOKABLE bool newPair();
    Q_INVOKABLE bool enterPair();
    // Picks the film or a hole ("film", "first", "second"); a click on the
    // canvas at (x, y), normalised to the shown frame, picks what is under it.
    Q_INVOKABLE void setPairLayer(const QString& layer);
    Q_INVOKABLE QString pairHoleAt(double x, double y) const;
    Q_INVOKABLE void pairClicked(double x, double y);
    // The piece's edits, each one undo step: a photograph (its library index)
    // into a hole, or none; the two frames swapped; the camera turned; the gap;
    // a hole's picture turned, its crop reset, its scopes ("print" or
    // "exposure" to "frame" or "film").
    Q_INVOKABLE bool setPairFrame(const QString& side, int libraryIndex);
    Q_INVOKABLE void removePairFrame(const QString& side);
    Q_INVOKABLE void swapPairFrames();
    Q_INVOKABLE void setPairTurned(bool turned);
    Q_INVOKABLE void setPairSpacing(double mm);
    Q_INVOKABLE void turnPairPicture(const QString& side);
    Q_INVOKABLE void resetPairPlacement(const QString& side);
    Q_INVOKABLE void setPairScope(const QString& which, const QString& scope);
    // The crop mode inside a hole (Session.togglePairPlacing, placementBegan/
    // Moved/Ended, placementZoomed): a drag moves the picked frame's picture
    // under its hole, the wheel scales it about the pointer; points are
    // normalised to the shown frame. Written on release (a zoom when it rests)
    // as one undo step; until its develop lands the canvas draws the motion.
    Q_INVOKABLE void setPairPlacing(bool on);
    Q_INVOKABLE bool beginPairDrag(double x, double y);
    Q_INVOKABLE void movePairDrag(double x, double y);
    Q_INVOKABLE void endPairDrag();
    Q_INVOKABLE bool zoomPairPlacement(double factor, double x, double y);
    // The section's sliders: shown at once, written when they rest.
    Q_INVOKABLE void previewPairPlacement(const QString& side, double scale, double x, double y);
    Q_INVOKABLE void openPairFrameAlone(const QString& side);
    // Deletes a pair's record (the photographs it showed are untouched).
    Q_INVOKABLE bool deletePair(int index);
signals:
    void clipboardChanged();
    void pairChanged();
    void filmEdgeChanged();
    void postDevChanged();
    void histogramChanged();
    void stateChanged();
    void catalogChanged();
    void settingsChanged();
    void frameChanged();
    void sourceOpened();
    void libraryChanged();
    void geometryChanged();
    void historyChanged();
    void initialized(bool success);
    void operationFinished(const QString& operation, bool success);
    // A recipe export ended: the page's result note (ExportPage.run's
    // "Wrote ..." plus the problems), whether any problem is in it, and the
    // files written (images, then any view LUTs).
    void exportFinished(const QString& summary, bool warning, const QStringList& files);
    void exportProofChanged();
    // The Pre-Dev rail's outcomes: `message` is "" on success, else why.
    void neutralPicked(bool success, const QString& message);
    void processed(bool success, const QString& message);
    void originalChanged();
private:
    // Everything the canvases show of one frame, made on the worker.
    struct Publication {
        QImage full, visible, navigator;
        std::vector<float> histogram, uncropped_histogram;  // of visible, of full
        QImage source;  // a cut frame's undeveloped decode (Frame::source_preview)
        // The whole print, unturned and uncropped, at the strip's size: what
        // the filmstrip masks with the crop (CropMaskedThumbnail.swift).
        QImage whole;
        spk::desktop::output::Geometry geometry;  // what `visible` applied
        double convert_ms=0, total_ms=0;           // factory alone; all three
        double histogram_ms=0;                     // both histograms
    };
    static QList<double> bins(const std::vector<float>& values);
    static Publication publish(const ImageFactory& factory, const spk::desktop::FramePtr& frame,
                               const spk::desktop::output::Geometry& geometry);
    struct Reply {
        quint64 generation=0;
        quint64 settings_revision=0;
        QString operation, error;
        QString message;
        int library_index=-1;
        spk::desktop::output::Geometry geometry;
        spk::desktop::FramePtr frame;
        Publication publication;
        spk::desktop::Catalog catalog;
        // A recipe export's result (exportFinished) and a proof's picture.
        bool recipe=false, warning=false;
        QString summary;
        QStringList files;
        QImage proof;
        QVariantMap proofInfo;
        // operation "original": the whole Original when it was made from the
        // decode (else empty), the visible one, its histogram and token.
        QImage original_full, original;
        std::vector<float> original_histogram;
        spk::desktop::output::Geometry original_geometry;
        quint64 original_token=0;
        double original_decode_ms=0, original_ms=0;
    };
    using Job = std::function<Reply(spk::desktop::PreviewHost&)>;
    void workerLoop(std::filesystem::path resources, spk::desktop::HostOptions options);
    void deliver(Reply reply);
    void accept(Reply reply);
    void submit(Job job, QString status, QString operation);
    spk::desktop::RenderSettings settings() const;
    void restoreSettings();
    void loadSettings(const spk::desktop::RenderSettings&, spk::desktop::DecodeMode);
    void saveActiveSettings(bool recordHistory=false);
    void setGeometry(const spk::desktop::output::Geometry&,const QString& editKey={});
    spk::desktop::editing::State currentState() const;
    void restoreHistory(bool redo);
    void scheduleSave();
    void updateThumbnail();
    int addFile(const QUrl&);
    void openItem(int index);
    void changed(const QString& editKey={});
    bool applyParameter(const spk::desktop::SettingField& field, spk::desktop::SettingValue value);
    const spk::desktop::Stock* currentFilm() const;
    std::string currentPaper() const;
    bool scanFilmSetting() const;
    bool chooseFilm(int index);
    bool choosePaper(int index);
    void schedulePreview();
    // The Original: drop what no longer matches the frame (a new decode) or
    // the geometry, and ask the worker for a new one while it is wanted.
    void refreshOriginal(bool decodeChanged);
    void requestOriginal();
    QRectF cutPictureRect() const;
    void acceptOriginal(Reply reply);
    // Film Edge: the frame's facts for the host's rules, the crop held at the
    // gate (Session.filmEdgeWillChange), and the image a frame is shown as.
    spk::desktop::PhotoInfo photoInfo(const spk::desktop::output::Geometry&) const;
    bool wantsCut(const spk::desktop::output::Geometry&) const;
    QSize decodeSize() const;
    void filmEdgeWillChange(const spk::desktop::RenderSettings& from,const spk::desktop::RenderSettings& to,
                            spk::desktop::output::Geometry& geometry,std::optional<spk::desktop::output::Geometry>& held) const;
    spk::desktop::output::Geometry heldAtGate(const spk::desktop::output::Geometry&,const spk::desktop::RenderSettings&,
                                              int landscape=-1) const;
    bool applySettings(spk::desktop::RenderSettings next,const QString& editKey);
    void setBodySeed(int seed);
    bool ready_=false, busy_=true, failed_=false;
    QString status_=uiText("status.startingEngine");
    QVariantList films_, papers_;
    spk::desktop::Catalog catalog_;
    int film_index_=0, paper_index_=0, decode_mode_=0;
    double exposure_ev_=0;
    spk::desktop::FramePtr frame_;
    QImage image_;
    QImage full_image_;
    QImage source_image_;
    QImage navigator_;
    double convert_ms_=0, publish_ms_=0;
    std::vector<float> histogram_, uncropped_histogram_;
    double histogram_ms_=0;
    QImage original_full_, original_;
    std::vector<float> original_histogram_;
    spk::desktop::output::Geometry original_geometry_;
    bool original_wanted_=false, original_pending_=false;
    quint64 original_token_=0;
    double original_decode_ms_=0, original_ms_=0;
    QString original_error_;
    // The frame a cut-frame Original was made for: a cut frame's Original is
    // the decode cut by that frame's own geometry, placed in its gate.
    const void* original_for_=nullptr;
    spk::desktop::output::Geometry geometry_;
    std::optional<spk::desktop::output::Geometry> held_geometry_;
    spk::desktop::RenderSettings extra_settings_;
    struct LibraryItem {
        QUrl url;
        spk::desktop::RenderSettings settings;
        spk::desktop::DecodeMode mode=spk::desktop::DecodeMode::compatible16;
        spk::desktop::output::Geometry geometry;
        std::optional<spk::desktop::output::Geometry> held;
        QImage thumbnail;
        QString error;
        bool selected=true;
        std::vector<spk::desktop::editing::State> undo,redo;
        bool pending_save=false,save_blocked=false,has_stored=false;
        QString save_warning;
        // A newer build's fields in this photo's record, kept by its saves.
        QStringList preserved;
        spk::desktop::postdev::Params postdev;   // its Post-Dev grade
        // A half-frame pair (its url is the pair's record): its piece and its
        // frames' own state; `settings` are then the film's.
        std::optional<spk::desktop::pairs::Pair> pair;
        // The filmstrip's picture (Filmstrip.swift, ThumbnailCache.swift): the
        // file's own preview -- a RAW's embedded JPEG, a flat file read small --
        // until the photograph has been rendered, then the rendered print,
        // whole; either is masked with the crop as the strip shows it.
        QImage preview;
        bool preview_requested=false;
        QImage whole;
        bool whole_cut=false;   // a cut frame's print already is its framing
        mutable QImage strip;
        mutable qint64 strip_source=0;
        mutable spk::desktop::output::Geometry strip_geometry;
    };
    // The per-item pictures a job snapshot does not need.
    static void dropImages(LibraryItem& item);
    static spk::desktop::editing::State itemState(const LibraryItem&);
    void recordEdit(LibraryItem&,const spk::desktop::editing::State& before);
    std::vector<LibraryItem> library_;
    int active_index_=-1;
    std::filesystem::path resources_;
    QString edit_directory_;
    spk::desktop::editing::Store edit_store_;
    QTimer save_timer_;
    int gesture_index_=-1;
    QString gesture_key_;
    bool gesture_recorded_=false;
    std::vector<spk::desktop::editing::State> gesture_redo_;
    int batch_progress_=0, batch_total_=0;
    std::shared_ptr<std::atomic_bool> cancel_batch_;
    ImageFactory image_factory_;
    quint64 generation_=0;
    // Written on the GUI thread only; the worker reads it to skip making
    // images for a render that is already superseded (it only ever grows,
    // so one stale there is stale when accept() sees it too).
    std::atomic<quint64> settings_revision_{0};
    QString active_operation_;
    QTimer auto_apply_;
    bool dialog_open_=false;
    QImage export_proof_;
    QVariantMap export_proof_info_;
    std::atomic<quint64> proof_generation_{0};   // the worker skips a superseded proof
    void acceptProof(Reply reply);
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Job> jobs_;
    bool stopping_=false;
    std::thread worker_;

    // --- the Pre-Dev rail (PreviewControllerPredev.cpp) -----------------------
    struct Analysis;  // one frame's meter and latitude, measured on the worker
    // On the worker after every job: once per frame the session renders.
    void analyse(spk::desktop::PreviewHost& host);
    void takeAnalysis(std::shared_ptr<const Analysis> analysis);
    void takeSolve(spk::desktop::FramePtr frame, std::string reply, QString error);
    void takeNeutral(spk::desktop::FramePtr frame, double kelvin, double tint, QString error);
    bool editWhiteBalance(const spk::desktop::WhiteBalance& next, const QString& editKey);
    void resolvePendingPlacement();
    // A synced photograph gets the placement's intent, not the curve fitted
    // to this one (RFC-027 §4.1, SettingsClipboard.swift:171-185).
    static spk::desktop::RenderSettings pastedPlacement(spk::desktop::RenderSettings settings);
    std::weak_ptr<const spk::desktop::Frame> analysed_;   // the worker's own
    std::shared_ptr<const Analysis> analysis_;            // the latest the UI took
    QVariantMap filters_;    // Process's pack, with the photograph, film and paper it is for
    QVariantMap refusal_;    // the last placement refusal

    // --- Post-Dev, Layer 2 (PreviewControllerPostDev.cpp) ---------------------
    void setupPostDev();     // the constructor's part
    void loadPostDev();      // the open photograph's grade becomes the current one
    bool editPostDev(const spk::desktop::postdev::Params& next, const QString& editKey);
    // At most every 100 ms after a grade or frame change: the histogram of the
    // graded navigator image and the active thumbnail, graded.
    void refreshPostDevSurfaces();
    QImage gradedThumbnail(QImage thumbnail) const;
    spk::desktop::postdev::Params postdev_;
    std::vector<float> graded_histogram_;   // empty: no grade, histogram_ is shown
    QTimer postdev_refresh_;
    // --- half-frame pairs (PreviewControllerPairs.cpp) -------------------------
    // The hooks the rest of the controller calls for a pair item.
    bool pairActive() const;
    spk::desktop::RenderSettings pairShown() const;
    spk::desktop::editing::State pairState() const;
    bool pairDirty() const;
    void savePairSettings(bool recordHistory);
    void openPairItem(int index);
    void applyPair();
    int addPairFile(const QString& path);
    void adoptPairs();
    void savePair(LibraryItem& item);
    void restorePair(const spk::desktop::editing::State& target);
    // A pair item's development for an export (the shown frame when it is
    // this pair as it is now); throws for an incomplete pair (answer B9).
    spk::desktop::FramePtr developPair(spk::desktop::PreviewHost& host, const LibraryItem& item,
                                       const spk::desktop::FramePtr& shown) const;
    // The Pre-Dev rail on a pair: the camera frame's own decode (its camera
    // white balance), what Scene Placement's measurement is compared with, the
    // Fit's region and pull-backs, and the camera frame's meter reading.
    const spk::io::RawMetadata* shotMetadata() const;
    spk::desktop::RenderSettings measurable(const spk::desktop::RenderSettings& shown) const;
    void pairFitRequest(const spk::desktop::FramePtr& frame, spk::Json& request);
    std::optional<QVariantMap> pairMetering() const;
    void editPair(const std::function<void(spk::desktop::pairs::Pair&, spk::desktop::RenderSettings&)>& change,
                  const QString& editKey);
    void makePair(int first, int second, spk::desktop::RenderSettings look, bool turned, bool keepFilmEdge);
    int insertItem(LibraryItem item, int at);
    void setPairLayerIndex(spk::desktop::pairs::Layer layer);
    void requestPairAnalysis();
    // Post-Dev on a pair (Session.layerAdjustments, pairIsLayered, pairLayered,
    // exportAdjustments, :4997-5112): the grade the rail shows and edits -- the
    // picked frame's own, else the film's; whether any frame grades for itself;
    // the picture graded frame by frame (the canvas then adds none); the
    // export's hook doing the same on the file's pixels.
    spk::desktop::postdev::Params pairShownGrade() const;
    bool pairGradeLayered(const LibraryItem& item) const;
    bool editPairGrade(const spk::desktop::postdev::Params& next, const QString& editKey);
    void regradePair();
    spk::desktop::postdev::Params canvasGrade() const;
    spk::desktop::postdev::FrameGrade pairExportGrade(const LibraryItem& item, const spk::desktop::FramePtr& frame) const;
    // The neutral picker on a pair: the hole under (x, y) of the shown frame
    // and the point on the piece the engine was handed.
    bool pairNeutralPoint(double x, double y, int& side, double& u, double& v) const;
    QTimer pair_grade_timer_;
    const void* pair_graded_for_ = nullptr;
    bool pair_graded_ = false;
    void resetPairEnlarger();
    void commitPairDrag();
    void pairFrameLanded();
    spk::desktop::PairRect pairHoleRect(int side) const;
    spk::desktop::pairs::Layer pair_layer_ = spk::desktop::pairs::Layer::film;
    int pair_camera_side_ = 0;
    bool pair_placing_ = false;
    struct PairDrag {
        int side = 0;
        QPointF start;
        spk::desktop::PairPlacement origin, live;
        double sourceWidth = 0, sourceHeight = 0;
        bool settling = false;   // written, waiting for its develop
    };
    std::optional<PairDrag> pair_drag_;
    QTimer pair_commit_;
    // The Fit's region and pull-backs for the worker's analysis of a pair.
    struct PairFit { int side = -1; double highlight = 0, shadow = 0; bool turned = false; double spacing = 1; };
    std::mutex pair_fit_mutex_;
    PairFit pair_fit_;

    // --- the library and the settings clipboard (PreviewControllerLibrary.cpp)
    void setupLibrary();     // the constructor's part
    // Asks the preview pool for every item's own picture still missing.
    void requestPreviews();
    void takePreview(const QUrl& url, QImage preview);
    // The item's strip picture: its whole print (else its file's preview),
    // masked with the crop the strip shows for it.
    QImage stripImage(int index) const;
    // The open photograph's whole print, thumbnail-sized, graded.
    QImage wholeThumbnail() const;
    // `items` (indices into library_) reordered by the folder's kept order.
    void applyFolderOrder(int from);
    // Moves library_[from] to `to`, keeping every index that names an item.
    void moveLibraryItem(int from, int to);
    // A clip written onto one photograph that is not open: its record, its
    // own undo step; false when nothing changed.
    // `crop`, when given, goes too (Sync with crop; never onto a pair).
    bool pasteOffline(const spk::desktop::clipboard::Clip& clip, int index,
                      const spk::desktop::output::Geometry* crop = nullptr);
    bool pasteLive(const spk::desktop::clipboard::Clip& clip);
    std::vector<int> syncTargets() const;
    std::vector<int> pasteTargets() const;
    QSet<spk::desktop::clipboard::Group> storedClipboardGroups() const;
    // setParameters' scope: the edits inside it are one gesture, one step.
    void beginBatchEdit();
    void endBatchEdit();
    QImage whole_thumb_;
    spk::desktop::library::FrameOrder order_;
    QSet<spk::desktop::clipboard::Group> clipboard_groups_;
    std::optional<spk::desktop::clipboard::Clip> clip_;
    std::unique_ptr<QThreadPool> preview_pool_;
    QTimer preview_flush_;
    int previews_running_=0;
    int batch_edit_=0;
    int library_revision_=0;
};
