#pragma once
#include "desktop/preview_host.hpp"
#include "FrameOutput.hpp"
#include "EditStore.hpp"
#include "Messages.hpp"
#include <QImage>
#include <QObject>
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
    Q_PROPERTY(QImage previewImage READ previewImage NOTIFY frameChanged)
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
public:
    using ImageFactory=std::function<QImage(const spk::desktop::FramePtr&)>;
    explicit PreviewController(std::filesystem::path resources, QObject* parent=nullptr, ImageFactory imageFactory={}, QString editDirectory={});
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
    Q_INVOKABLE void openFiles(const QVariantList& urls);
    Q_INVOKABLE void selectImage(int index);
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
    Q_INVOKABLE void resetSettings();
    Q_INVOKABLE void setDialogOpen(bool open);
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
signals:
    void filmEdgeChanged();
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
private:
    struct Reply {
        quint64 generation=0;
        quint64 settings_revision=0;
        QString operation, error;
        QString message;
        int library_index=-1;
        spk::desktop::output::Geometry geometry;
        spk::desktop::FramePtr frame;
        spk::desktop::Catalog catalog;
    };
    using Job = std::function<Reply(spk::desktop::PreviewHost&)>;
    void workerLoop(std::filesystem::path resources);
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
    };
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
    quint64 settings_revision_=0;
    QString active_operation_;
    QTimer auto_apply_;
    bool dialog_open_=false;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Job> jobs_;
    bool stopping_=false;
    std::thread worker_;
};
