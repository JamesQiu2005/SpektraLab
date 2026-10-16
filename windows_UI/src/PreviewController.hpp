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
    // --- canvas tools (FrameImage.hpp histogram / originalImage) ---
    // 4 x 256 normalised bins (R, G, B, luma) of what each surface shows: the
    // print as cropped (previewImage) -- not the uncropped print the Mac's
    // histogram counts (AGENTS.md trap 33) -- and the whole source the crop
    // editor shows (uncroppedImage). Made on the worker with the images, and
    // on the GUI thread from the new previewImage after a geometry edit.
    Q_PROPERTY(QList<double> histogram READ histogram NOTIFY frameChanged)
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
    QImage uncroppedImage() const { return full_image_; }
    QRectF cropRect() const { return geometry_.crop; }
    int quarterTurns() const { return geometry_.quarterTurns; }
    bool flipHorizontal() const { return geometry_.flipHorizontal; }
    bool flipVertical() const { return geometry_.flipVertical; }
    double straightenDegrees() const { return geometry_.straightenDegrees; }
    QList<double> histogram() const { return bins(histogram_); }
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
    Q_INVOKABLE void resetSettings();
    Q_INVOKABLE void setDialogOpen(bool open);
signals:
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
    void originalChanged();
private:
    // Everything the canvases show of one frame, made on the worker.
    struct Publication {
        QImage full, visible, navigator;
        std::vector<float> histogram, uncropped_histogram;  // of visible, of full
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
    void acceptOriginal(Reply reply);
    bool ready_=false, busy_=true, failed_=false;
    QString status_=uiText("status.startingEngine");
    QVariantList films_, papers_;
    spk::desktop::Catalog catalog_;
    int film_index_=0, paper_index_=0, decode_mode_=0;
    double exposure_ev_=0;
    spk::desktop::FramePtr frame_;
    QImage image_;
    QImage full_image_;
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
    spk::desktop::output::Geometry geometry_;
    spk::desktop::RenderSettings extra_settings_;
    struct LibraryItem {
        QUrl url;
        spk::desktop::RenderSettings settings;
        spk::desktop::DecodeMode mode=spk::desktop::DecodeMode::compatible16;
        spk::desktop::output::Geometry geometry;
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
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Job> jobs_;
    bool stopping_=false;
    std::thread worker_;
};
