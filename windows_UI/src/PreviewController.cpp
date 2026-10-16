#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include "PostDevSurfaces.hpp"
#include <QElapsedTimer>
#include <QMetaObject>
#include <QDir>
#include <QFileInfo>
#include <QSet>
#include <QStandardPaths>
#include <algorithm>
#include <cmath>
#include <iterator>
#include <optional>
#include <type_traits>
#include <variant>

namespace {
namespace desktop=spk::desktop;
namespace output=desktop::output;
namespace editing=desktop::editing;
QString text(const std::string& s) { return QString::fromUtf8(s.data(),qsizetype(s.size())); }
std::filesystem::path path(const QUrl& u) { return std::filesystem::path(u.toLocalFile().toStdWString()); }
QVariantList list(const std::vector<desktop::Stock>& stocks) {
    QVariantList result;
    for(const auto& s:stocks) result.push_back(QVariantMap{{"id",text(s.id)},{"name",text(s.label)},{"positive",s.is_positive},
        {"monochrome",s.is_monochrome},{"cine",s.is_cine},{"targetPrint",text(s.target_print)}});
    return result;
}
int indexOf(const std::vector<desktop::Stock>& stocks,std::string_view id) {
    for(std::size_t i=0;i<stocks.size();++i)if(stocks[i].id==id)return int(i);
    return -1;
}
std::string initialText(const char* key) {return std::get<std::string>(desktop::find_setting(key)->initial);}
// macOS PrintProfileSection's sentinel row id for "No Print Profile": it is
// not a paper, so it can never be a print_stock value.
const QString noPrintProfileId=QStringLiteral("__scan_film__");
// The AE Method pill's metering intents (Params.swift ExposureMethod).
constexpr const char* meteringIntents[]={"balanced","center","protect_highlights","protect_shadows"};
bool sameSettings(desktop::RenderSettings a, desktop::RenderSettings b) {
    const bool exposure=std::abs(a.print_exposure-b.print_exposure)<1e-12;
    a.print_exposure=b.print_exposure;
    return exposure&&a==b;
}
bool sameState(const editing::State& a,const editing::State& b) {
    return sameSettings(a.settings,b.settings)&&a.mode==b.mode&&a.geometry==b.geometry&&a.postDev==b.postDev;
}
QImage visibleImage(const desktop::FramePtr& frame,const QImage& full,const output::Geometry& geometry) {
    if(geometry.quarterTurns==0&&!geometry.flipHorizontal&&!geometry.flipVertical&&geometry.straightenDegrees==0)
        return output::displayImage(full,geometry.crop);
    return output::displayFrame(frame,geometry);
}
output::ExportOptions exportOptions(int format,int quality,int maxEdge) {
    if(format<0||format>3||quality<1||quality>100||maxEdge<0||maxEdge>100000)
        throw std::runtime_error("Invalid export options");
    return {static_cast<output::Format>(format),quality,maxEdge};
}
// The camelCase names the first QML uses for adjustments/setAdjustment, each
// one wire key of the settings table. New controls use the wire name.
struct Alias { const char* qml; const char* key; };
constexpr Alias legacyAdjustments[]={
    {"filmExposureEv","exposure_compensation_ev"},{"filmFormatMm","film_format_mm"},
    {"grainActive","grain_active"},{"grainAmount","grain_amount"},
    {"halationActive","halation_active"},{"halationAmount","halation_amount"},
    {"glareActive","glare_active"},{"glareAmount","glare_amount"},
    {"yFilterShift","y_filter_shift"},{"mFilterShift","m_filter_shift"}};
QString wireKey(const QString& name) {
    for(const auto& alias:legacyAdjustments)if(name==QLatin1String(alias.qml))return QLatin1String(alias.key);
    return name;
}
// Gestures and undo steps are keyed by wire name, so one drag stays one step
// whichever of the legacy or generic setters the control calls.
QString canonicalEditKey(const QString& name) {
    if(name==QLatin1String("exposureEv"))return QStringLiteral("print_exposure");
    if(name==QLatin1String("filmIndex"))return QStringLiteral("film_stock");
    if(name==QLatin1String("paperIndex"))return QStringLiteral("print_stock");
    return wireKey(name);
}
QVariant variant(const desktop::SettingValue& value) {
    return std::visit([](const auto& v)->QVariant{
        if constexpr(std::is_same_v<std::decay_t<decltype(v)>,std::string>)return text(v);
        else return QVariant(v);
    },value);
}
// Strict, for the generic setter: a number row takes a number (not a bool or
// numeric text), a bool row a bool and a text row a string.
std::optional<desktop::SettingValue> settingValue(const desktop::SettingField& field,const QVariant& value) {
    switch(field.type) {
    case desktop::SettingType::boolean:
        if(value.typeId()==QMetaType::Bool)return value.toBool();
        break;
    case desktop::SettingType::number:
        switch(value.typeId()) {
        case QMetaType::Double: case QMetaType::Float: case QMetaType::Int: case QMetaType::UInt:
        case QMetaType::LongLong: case QMetaType::ULongLong: return value.toDouble();
        default: break;
        }
        break;
    case desktop::SettingType::text:
        if(value.typeId()==QMetaType::QString)return value.toString().toStdString();
        break;
    }
    return std::nullopt;
}
}
QImage PreviewController::imageFromFrame(const desktop::FramePtr& frame) {
    // Its own pixels (half floats, 8 bytes per pixel like the RGBA16 it came
    // from), so the image no longer holds the engine frame alive.
    return desktop::display::frameImage(frame);
}

PreviewController::Publication PreviewController::publish(const ImageFactory& factory,const desktop::FramePtr& frame,
                                                          const output::Geometry& geometry) {
    QElapsedTimer clock;clock.start();
    Publication p;p.geometry=geometry;
    p.full=factory(frame);
    if(p.full.isNull())throw std::runtime_error("Cannot create the display image");
    p.convert_ms=double(clock.nsecsElapsed())/1e6;
    p.visible=visibleImage(frame,p.full,geometry);
    p.navigator=desktop::display::navigatorImage(p.visible);
    const auto histogramStart=clock.nsecsElapsed();
    p.histogram=desktop::display::histogram(p.visible);
    p.uncropped_histogram=desktop::display::histogram(p.full);
    p.histogram_ms=double(clock.nsecsElapsed()-histogramStart)/1e6;
    p.total_ms=double(clock.nsecsElapsed())/1e6;
    return p;
}
QList<double> PreviewController::bins(const std::vector<float>& values) {
    QList<double> result;result.reserve(qsizetype(values.size()));
    for(const float v:values)result.append(v);
    return result;
}

PreviewController::PreviewController(std::filesystem::path resources,QObject* parent,ImageFactory factory,QString editDirectory,
                                     QString outputColorSpace)
    :QObject(parent),resources_(resources),
     edit_store_(editDirectory.isEmpty()?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+"/Edits":editDirectory),
     image_factory_(factory?std::move(factory):ImageFactory(imageFromFrame)) {
    auto_apply_.setSingleShot(true);auto_apply_.setInterval(180);
    connect(&auto_apply_,&QTimer::timeout,this,[this]{if(dirty())apply();});
    save_timer_.setSingleShot(true);save_timer_.setInterval(350);
    connect(&save_timer_,&QTimer::timeout,this,&PreviewController::flushEdits);
    // The canvas is fed from pixels() (publish), so the host's 8-bit copy
    // would be 132 MB per 33 MP frame nobody reads.
    desktop::HostOptions options;options.bgra8_display=false;
    if(!outputColorSpace.isEmpty())options.output_color_space=outputColorSpace.toStdString();
    setupPostDev();
    worker_=std::thread([this,resources=std::move(resources),options]{workerLoop(resources,options);});
}
PreviewController::~PreviewController() {
    auto_apply_.stop();
    endEditGesture();flushEdits();
    if(cancel_batch_)cancel_batch_->store(true);
    ++generation_;
    {std::lock_guard lock(mutex_);stopping_=true;jobs_.clear();}
    wake_.notify_one();
    if(worker_.joinable()) worker_.join();
}
void PreviewController::workerLoop(std::filesystem::path resources,desktop::HostOptions options) {
    std::unique_ptr<desktop::PreviewHost> host;
    Reply init;init.operation="init";
    try {host=std::make_unique<desktop::PreviewHost>(resources,std::move(options));init.catalog=host->catalog();}
    catch(const std::exception& e){init.error=text(e.what());}
    deliver(std::move(init));
    if(!host)return;
    for(;;) {
        Job job;
        {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stopping_||!jobs_.empty();});
         if(stopping_)break;job=std::move(jobs_.front());jobs_.pop_front();}
        deliver(job(*host));
        analyse(*host); // the Pre-Dev rail's readings of a new frame (PreviewControllerPredev.cpp)
    }
}
void PreviewController::deliver(Reply reply) {
    QMetaObject::invokeMethod(this,[this,reply=std::move(reply)]() mutable {accept(std::move(reply));},Qt::QueuedConnection);
}
void PreviewController::submit(Job job,QString status,QString operation) {
    auto_apply_.stop();active_operation_=std::move(operation);
    busy_=true;failed_=false;status_=std::move(status);emit stateChanged();emit historyChanged();
    {std::lock_guard lock(mutex_);jobs_.push_back(std::move(job));}
    wake_.notify_one();
}
void PreviewController::accept(Reply reply) {
    // A proof is not an operation: it changes no state but its own picture.
    if(reply.operation=="proof"){acceptProof(std::move(reply));return;}
    // The Original rides the same worker but is no operation: it neither
    // holds the controller busy nor reports one finished.
    if(reply.operation=="original"){acceptOriginal(std::move(reply));return;}
    if(reply.generation!=generation_)return; // a retired generation never replaces the canvas
    const bool superseded=reply.operation=="render"&&reply.settings_revision!=settings_revision_;
    busy_=false;active_operation_.clear();failed_=!superseded&&!reply.error.isEmpty();
    if(superseded) {
        // The worker may finish an earlier choice after the next click. Keep
        // both the displayed frame and the newest desired controls; never flash
        // the retired result or restore its settings over the user's last edit.
        status_=uiText(dirty()?"status.updatingPreview":"status.previewCurrent");
    } else if(failed_) {
        status_=reply.error;
        if(frame_&&reply.operation!="export"&&reply.operation!="batch-export")restoreSettings();
    } else if(reply.operation=="init") {
        ready_=true;catalog_=std::move(reply.catalog);films_=list(catalog_.films);papers_=list(catalog_.papers);
        restoreSettings();emit catalogChanged();status_=uiText("status.ready");
    } else if(reply.frame) {
        // The worker made the images; publish no new UI state unless all are
        // in hand.
        try {
            auto published=std::move(reply.publication);
            if(published.full.isNull())throw std::runtime_error("Cannot create the display image");
            const auto geometry=reply.operation=="open"?reply.geometry:geometry_;
            // A render that is not superseded was submitted with today's
            // geometry (an undo during it supersedes it). Should that ever
            // not hold, show the right crop rather than the worker's.
            if(published.geometry!=geometry) {
                published.visible=visibleImage(reply.frame,published.full,geometry);
                published.navigator=desktop::display::navigatorImage(published.visible);
                published.histogram=desktop::display::histogram(published.visible);
            }
            // A new decode (another photo, or another decode mode) makes the
            // held Original stale; a re-render of the same decode does not.
            const bool decodeChanged=!frame_||frame_->source!=reply.frame->source||
                frame_->decode_mode!=reply.frame->decode_mode||reply.operation=="open";
            frame_=std::move(reply.frame);full_image_=std::move(published.full);
            image_=std::move(published.visible);navigator_=std::move(published.navigator);
            histogram_=std::move(published.histogram);uncropped_histogram_=std::move(published.uncropped_histogram);
            convert_ms_=published.convert_ms;publish_ms_=published.total_ms;histogram_ms_=published.histogram_ms;
            geometry_=geometry;
            if(reply.operation=="open"){active_index_=reply.library_index;loadPostDev();}
            refreshOriginal(decodeChanged);
        }
        catch(const std::exception& e){failed_=true;status_=text(e.what());if(frame_)restoreSettings();}
        if(!failed_) {
            restoreSettings();
            updateThumbnail();
            status_=uiText(frame_->reprint()?"status.renderedReusedNegative":"status.rendered",
                           {QString::number(frame_->timings.render_ms/1000,'f',2)});
            emit frameChanged();emit geometryChanged();if(reply.operation=="open")emit sourceOpened();
        }
    } else if(reply.operation=="export") status_=uiText("status.exported");
    else if(reply.operation=="batch-export")status_=reply.message;
    if(failed_&&reply.operation=="open"&&reply.library_index>=0&&reply.library_index<int(library_.size()))
        library_[reply.library_index].error=status_;
    if(failed_&&reply.operation!="export"&&reply.operation!="batch-export"&&active_index_>=0){
        auto& history=library_[active_index_].undo;
        while(!history.empty()&&sameState(history.back(),currentState()))history.pop_back();
    }
    if(reply.operation=="batch-export")cancel_batch_.reset();
    emit libraryChanged();
    emit historyChanged();
    emit stateChanged();
    // The recipe's result first, so a listener to operationFinished sees it.
    if(reply.recipe)emit exportFinished(reply.summary,reply.warning||failed_,reply.files);
    if(reply.operation=="init")emit initialized(!failed_);
    else emit operationFinished(reply.operation,!failed_);
    // Export holds an immutable displayed frame. An edit made just before it
    // began still needs applying, including after an overwrite refusal.
    if((superseded||reply.operation=="export"||reply.operation=="batch-export")&&!busy_)schedulePreview();
}
desktop::RenderSettings PreviewController::settings() const {
    desktop::RenderSettings s=extra_settings_;
    if(film_index_>=0&&std::size_t(film_index_)<catalog_.films.size())s.film_stock=catalog_.films[film_index_].id;
    if(paper_index_>=0&&std::size_t(paper_index_)<catalog_.papers.size())s.print_stock=catalog_.papers[paper_index_].id;
    s.print_exposure=std::exp2(-exposure_ev_);return s;
}
void PreviewController::restoreSettings() {
    const auto s=frame_?frame_->settings:desktop::RenderSettings{};
    loadSettings(s,frame_?frame_->decode_mode:desktop::DecodeMode::compatible16);
    saveActiveSettings();
}
void PreviewController::loadSettings(const desktop::RenderSettings& s,desktop::DecodeMode mode) {
    extra_settings_=s;
    for(std::size_t i=0;i<catalog_.films.size();++i)if(catalog_.films[i].id==s.film_stock)film_index_=int(i);
    for(std::size_t i=0;i<catalog_.papers.size();++i)if(catalog_.papers[i].id==s.print_stock)paper_index_=int(i);
    exposure_ev_=-std::log2(s.print_exposure);
    decode_mode_=mode==desktop::DecodeMode::headroom?1:0;
    emit settingsChanged();
}
bool PreviewController::dirty() const {
    if(!frame_)return false;
    return !sameSettings(settings(),frame_->settings)||
        decode_mode_!=(frame_->decode_mode==desktop::DecodeMode::headroom?1:0);
}
bool PreviewController::filmIsPositive() const {
    return film_index_>=0&&std::size_t(film_index_)<catalog_.films.size()&&catalog_.films[film_index_].is_positive;
}
QString PreviewController::fileName() const {return frame_?QString::fromStdWString(frame_->source.filename().wstring()):QString();}
QUrl PreviewController::sourceFolder() const {return frame_?QUrl::fromLocalFile(QString::fromStdWString(frame_->source.parent_path().wstring())):QUrl();}
QVariantMap PreviewController::metadata() const {
    if(!frame_)return {};
    return {{"width",image_.width()},{"height",image_.height()},
        {"sourceWidth",frame_->width()},{"sourceHeight",frame_->height()},
        {"camera",text(frame_->metadata.make+" "+frame_->metadata.model)},
        {"decodeMs",frame_->timings.decode_ms},{"renderMs",frame_->timings.render_ms},
        {"totalMs",frame_->timings.total_ms},{"cached",frame_->reprint()},{"scanFilm",frame_->scan_film},
        {"mode",frame_->decode_mode==desktop::DecodeMode::headroom?"headroom":"compatible16"},
        {"colorSpace",text(frame_->encoding.color_space)},{"transferEncoded",frame_->encoding.cctf_encoding},
        {"convertMs",convert_ms_},{"publishMs",publish_ms_},{"histogramMs",histogram_ms_},
        {"originalDecodeMs",original_decode_ms_},{"originalMs",original_ms_},{"originalError",original_error_}};
}
void PreviewController::setOriginalWanted(bool wanted) {
    if(wanted==original_wanted_)return;
    original_wanted_=wanted;
    if(wanted&&original_.isNull()&&!original_pending_)requestOriginal();
    emit originalChanged();
}
void PreviewController::refreshOriginal(bool decodeChanged) {
    const bool stale=decodeChanged||original_geometry_!=geometry_||
        (!original_full_.isNull()&&frame_&&original_full_.size()!=QSize(int(frame_->width()),int(frame_->height())));
    if(decodeChanged)original_full_={};
    if(stale||!frame_) {
        // Retire anything in flight: its image no longer fits this frame.
        ++original_token_;original_pending_=false;
        original_={};original_histogram_.clear();
    }
    if(original_wanted_&&original_.isNull())requestOriginal();
    emit originalChanged();
}
void PreviewController::requestOriginal() {
    if(!frame_)return;
    const auto token=++original_token_;original_pending_=true;original_error_.clear();
    const auto whole=original_full_;const auto geometry=geometry_;const auto encoding=frame_->encoding;
    const auto source=frame_->source;const auto mode=frame_->decode_mode;
    const QSize size(int(frame_->width()),int(frame_->height()));
    {std::lock_guard lock(mutex_);
     jobs_.push_back([whole,geometry,encoding,source,mode,size,token](desktop::PreviewHost& host){
        Reply r;r.operation="original";r.original_token=token;r.original_geometry=geometry;
        try {
            QElapsedTimer clock;clock.start();
            auto full=whole;
            if(full.isNull()) {
                // Only the decode this frame was developed from: the host
                // may have moved on (another photo, a failed publication).
                const auto current=host.current();
                if(!current||current->source!=source||current->decode_mode!=mode)
                    throw std::runtime_error("The decode behind this photo is no longer held");
                full=desktop::display::originalImage(host.decoded(),encoding);
                if(full.size()!=size)throw std::runtime_error("The Original does not match the developed frame's size");
                r.original_full=full;r.original_decode_ms=double(clock.nsecsElapsed())/1e6;
            }
            // The print's own geometry function, on the same pixel edges
            // (FrameOutput.hpp displayImage), so the two share every crop,
            // turn, flip and straighten.
            r.original=output::displayImage(full,geometry);
            r.original_histogram=desktop::display::histogram(r.original);
            r.original_ms=double(clock.nsecsElapsed())/1e6;
        }catch(const std::exception& e){r.original={};r.original_full={};r.error=text(e.what());}
        return r;});}
    wake_.notify_one();
}
void PreviewController::acceptOriginal(Reply reply) {
    if(reply.original_token!=original_token_||!frame_)return;
    original_pending_=false;
    if(!reply.error.isEmpty()){original_error_=reply.error;emit originalChanged();return;}
    if(!reply.original_full.isNull()){original_full_=std::move(reply.original_full);original_decode_ms_=reply.original_decode_ms;}
    original_=std::move(reply.original);original_histogram_=std::move(reply.original_histogram);
    original_geometry_=reply.original_geometry;original_ms_=reply.original_ms;
    emit originalChanged();
}
void PreviewController::schedulePreview(){if(!dialog_open_&&gesture_key_!="straightenDegrees"&&frame_&&dirty()&&!auto_apply_.isActive())auto_apply_.start();}
void PreviewController::setDialogOpen(bool open){
    if(dialog_open_==open)return;
    dialog_open_=open;
    if(open){endEditGesture();auto_apply_.stop();}else schedulePreview();
    emit stateChanged();emit historyChanged();
}
void PreviewController::changed(const QString& editKey){
    if(gesture_index_>=0&&gesture_key_!=canonicalEditKey(editKey))endEditGesture();
    saveActiveSettings(true);
    ++settings_revision_;auto_apply_.stop();schedulePreview();
    if(frame_)status_=uiText("status.updatingPreview");
    failed_=false;emit settingsChanged();emit stateChanged();
}
void PreviewController::setFilmIndex(int v){chooseFilm(v);}
void PreviewController::setPaperIndex(int v){choosePaper(v);}
void PreviewController::setDecodeMode(int v){if(!settingsEditable()||v<0||v>1||v==decode_mode_)return;decode_mode_=v;changed("decodeMode");}
void PreviewController::setExposureEv(double v){if(!settingsEditable()||filmIsPositive()||!std::isfinite(v)||v< -3||v>3||v==exposure_ev_)return;exposure_ev_=v;changed("print_exposure");}
const desktop::Stock* PreviewController::currentFilm() const {
    return film_index_>=0&&std::size_t(film_index_)<catalog_.films.size()?&catalog_.films[film_index_]:nullptr;
}
std::string PreviewController::currentPaper() const {
    return paper_index_>=0&&std::size_t(paper_index_)<catalog_.papers.size()?catalog_.papers[paper_index_].id:std::string();
}
bool PreviewController::scanFilmSetting() const {return std::get<bool>(extra_settings_.get("scan_film"));}
// Session.selectFilmStock (Session.swift:2988-3007): the film, and the paper
// it lands on, as one edit. macOS moves the paper even when the film was
// already chosen, so choosing it again returns to its own paper.
bool PreviewController::chooseFilm(int v) {
    if(!settingsEditable()||v<0||std::size_t(v)>=catalog_.films.size())return false;
    const auto& film=catalog_.films[std::size_t(v)];
    const int paper=indexOf(catalog_.papers,desktop::paper_for_film(catalog_,film.id,currentPaper(),initialText("print_stock")));
    if(v==film_index_&&(paper<0||paper==paper_index_))return true;
    film_index_=v;if(paper>=0)paper_index_=paper;
    changed("film_stock");return true;
}
// Session.selectPrintStock (Session.swift:2970-2983): no paper for a slide,
// silver film on silver paper, and a paper chosen is a paper printed on.
bool PreviewController::choosePaper(int v) {
    if(!settingsEditable()||filmIsPositive()||v<0||std::size_t(v)>=catalog_.papers.size())return false;
    if(const auto* film=currentFilm();film&&!desktop::can_print(catalog_,film->id,catalog_.papers[std::size_t(v)].id))return false;
    const bool scanning=scanFilmSetting();
    if(v==paper_index_&&!scanning)return true;
    paper_index_=v;if(scanning)extra_settings_.set("scan_film",false);
    changed("print_stock");return true;
}
bool PreviewController::selectFilm(const QString& id){return chooseFilm(indexOf(catalog_.films,id.toStdString()));}
bool PreviewController::selectPaper(const QString& id) {
    if(id!=noPrintProfileId)return choosePaper(indexOf(catalog_.papers,id.toStdString()));
    // PrintProfileSection.swift:125-127: offered for any film, the paper kept.
    if(!settingsEditable())return false;
    if(!scanFilmSetting()){extra_settings_.set("scan_film",true);changed("scan_film");}
    return true;
}
bool PreviewController::useFilmPaper() {
    if(!settingsEditable()||!canUseFilmPaper())return false;
    const int paper=indexOf(catalog_.papers,currentFilm()->target_print);
    if(paper==paper_index_&&!scanFilmSetting())return true;
    paper_index_=paper;extra_settings_.set("scan_film",false);
    changed("print_stock");return true;
}
void PreviewController::resetFilmStock() {
    if(!settingsEditable())return;
    const auto film=initialText("film_stock");
    const int f=indexOf(catalog_.films,film);if(f<0)return;
    // Coming back from a black-and-white film, its paper cannot stay.
    const int p=desktop::can_print(catalog_,film,currentPaper())?paper_index_:indexOf(catalog_.papers,initialText("print_stock"));
    if(f==film_index_&&(p<0||p==paper_index_))return;
    film_index_=f;if(p>=0)paper_index_=p;
    changed("film_stock");
}
void PreviewController::resetEnlarger() {
    if(!settingsEditable())return;
    auto next=extra_settings_;
    next.y_filter_shift=0;next.m_filter_shift=0;next.set("preflash_exposure",0.0);
    if(next==extra_settings_&&exposure_ev_==0)return;
    extra_settings_=std::move(next);exposure_ev_=0;
    changed("enlarger");
}
bool PreviewController::filmIsMonochrome() const {const auto* film=currentFilm();return film&&film->is_monochrome;}
bool PreviewController::noPrintProfile() const {return filmIsPositive()||scanFilmSetting();}
QString PreviewController::printSelection() const {return noPrintProfile()?noPrintProfileId:text(currentPaper());}
bool PreviewController::canUseFilmPaper() const {
    // Disabled for a slide, which declares no paper (PrintProfileSection.swift:206).
    const auto* film=currentFilm();
    return film&&!film->is_positive&&catalog_.paper(film->target_print);
}
QString PreviewController::aeMethod() const {
    if(!std::get<bool>(extra_settings_.get("auto_exposure")))return QStringLiteral("custom");
    const auto method=std::get<std::string>(extra_settings_.get("auto_exposure_method"));
    for(const char* intent:meteringIntents)if(method==intent)return QLatin1String(intent);
    return QStringLiteral("legacy");
}
QStringList PreviewController::aeMethodChoices() const {
    QStringList choices{QStringLiteral("custom")};
    for(const char* intent:meteringIntents)choices.append(QLatin1String(intent));
    return choices;
}
// AEMethod.apply (Params.swift:228-239): Custom leaves the intent alone, so
// turning the meter off and on again comes back to the intent it had.
void PreviewController::setAeMethod(const QString& value) {
    if(!settingsEditable())return;
    auto next=extra_settings_;
    if(value==QLatin1String("custom"))next.set("auto_exposure",false);
    else if(std::any_of(std::begin(meteringIntents),std::end(meteringIntents),[&](const char* i){return value==QLatin1String(i);})) {
        next.set("auto_exposure",true);next.set("auto_exposure_method",value.toStdString());
    } else return;
    if(next!=extra_settings_){extra_settings_=std::move(next);changed("auto_exposure");}
}
QVariantList PreviewController::filmCatalog() const {
    QVariantList result;
    for(const auto& group:desktop::film_groups(catalog_))
        for(const auto* s:group.stocks)
            result.push_back(QVariantMap{{"id",text(s->id)},{"name",text(s->label)},{"group",text(group.key)},
                {"positive",s->is_positive},{"monochrome",s->is_monochrome},{"cine",s->is_cine},
                {"targetPrint",text(s->target_print)},{"index",int(s-catalog_.films.data())}});
    return result;
}
// PrintProfileSection.swift:81-113: each paper greyed with its reason, then
// the Positive group's one row.
QVariantList PreviewController::paperCatalog() const {
    QVariantList result;
    const auto* film=currentFilm();const bool slide=filmIsPositive();
    for(const auto& group:desktop::paper_groups(catalog_))
        for(const auto* s:group.stocks) {
            const bool printable=!film||desktop::can_print(catalog_,film->id,s->id);
            const char* reason=slide?"positiveFilm":printable?"":s->is_monochrome?"silverPaper":"colourPaper";
            result.push_back(QVariantMap{{"id",text(s->id)},{"name",text(s->label)},{"group",text(group.key)},
                {"monochrome",s->is_monochrome},{"cine",s->is_cine},{"index",int(s-catalog_.papers.data())},
                {"printable",printable},{"enabled",!slide&&printable},{"declared",film&&film->target_print==s->id},
                {"reason",QLatin1String(reason)},{"noPrintProfile",false}});
        }
    result.push_back(QVariantMap{{"id",noPrintProfileId},{"name",QStringLiteral("No Print Profile")},{"group",QStringLiteral("positive")},
        {"monochrome",false},{"cine",false},{"index",-1},{"printable",true},{"enabled",true},{"declared",false},
        {"reason",QString()},{"noPrintProfile",true}});
    return result;
}
void PreviewController::resetSettings(){
    if(!settingsEditable())return;
    // Post-Dev returns to the pure print with the rest (one undo step);
    // Bypass stays as it was, as Session.resetAdjustments keeps it.
    if(!postdev_.isNeutral()){const bool enabled=postdev_.enabled;postdev_={};postdev_.enabled=enabled;emit postDevChanged();}
    loadSettings({},desktop::DecodeMode::compatible16);changed();
}
void PreviewController::openRaw(const QUrl& url) {
    // Changing sources and exporting remain single flight. Parameter edits
    // can be coalesced during a render, but cannot retarget an in-flight open.
    if(!ready_||busy_||!url.isLocalFile())return;
    saveActiveSettings();
    const int index=addFile(url);if(index<0)return;
    // A known photo restores its own saved settings. A genuinely new photo
    // still starts with the current preset; opening never overwrites a sidecar.
    openItem(index);
}
void PreviewController::openItem(int index) {
    endEditGesture();
    const auto item=library_.at(index);const auto p=path(item.url);
    const auto gen=++generation_;const auto factory=image_factory_;
    submit([p,item,gen,index,factory](auto& host){Reply r;r.generation=gen;r.operation="open";r.library_index=index;r.geometry=item.geometry;
        // A frame whose images cannot be made is not delivered: the reply
        // fails and the displayed frame stays (the host's session has moved
        // on; the next render reconciles it).
        try{r.frame=host.open_raw(p,item.mode,item.settings);r.publication=publish(factory,r.frame,item.geometry);}
        catch(const std::exception& e){r.frame=nullptr;r.error=text(e.what());}return r;},uiText("status.opening"),"open");
}
void PreviewController::apply() {
    if(!frame_||busy_||dialog_open_)return;
    const auto s=settings();const auto shown=frame_;const auto gen=++generation_;const auto revision=settings_revision_.load();
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    const auto factory=image_factory_;const auto geometry=geometry_;
    submit([this,s,shown,gen,revision,mode,factory,geometry](auto& host){Reply r;r.generation=gen;r.settings_revision=revision;r.operation="render";
        try {
            // Publication can fail after a successful worker open (for example,
            // a display allocation failure). Reconcile against the image the
            // user is actually editing before reusing the worker's session.
            const auto active=host.current();
            r.frame=active&&active->source==shown->source&&active->decode_mode==mode
                ?host.render(s):host.open_raw(shown->source,mode,s);
            // accept() drops a superseded result unseen; converting 33 MP
            // for it would only delay the render that replaces it.
            if(settings_revision_.load()==revision)r.publication=publish(factory,r.frame,geometry);
        }catch(const std::exception& e){r.frame=nullptr;r.error=text(e.what());}return r;},uiText("status.rendering"),"render");
}
void PreviewController::exportTiff(const QUrl& url) {
    exportImage(url,0,95,0);
}
void PreviewController::exportImage(const QUrl& url,int format,int quality,int maxLongEdge) {
    if(!frame_||busy_||!url.isLocalFile())return;
    const auto p=path(url);const auto held=frame_;const auto gen=++generation_;const auto geometry=geometry_;const auto resources=resources_;
    // Post-Dev on the uncropped frame before geometry, as every export path
    // grades (PostDevSurfaces.hpp; AGENTS.md trap 33).
    const auto grade=desktop::postdev::exportGrade(postdev_);
    submit([p,held,gen,geometry,resources,format,quality,maxLongEdge,grade](auto&){Reply r;r.generation=gen;r.operation="export";
        try{output::exportFrame(held,p,geometry,exportOptions(format,quality,maxLongEdge),resources,grade);}catch(const std::exception& e){r.error=text(e.what());}return r;},uiText("status.exporting"),"export");
}

QVariantMap PreviewController::adjustments() const {
    QVariantMap result;
    for(const auto& alias:legacyAdjustments)result.insert(QLatin1String(alias.qml),variant(extra_settings_.get(alias.key)));
    return result;
}
QVariantMap PreviewController::parameters() const {
    const auto s=settings();QVariantMap result;
    for(const auto& field:desktop::setting_fields())result.insert(text(field.key),variant(s.get(field.key)));
    return result;
}
QVariantList PreviewController::parameterFields() const {
    QVariantList result;
    for(const auto& field:desktop::setting_fields()) {
        // `sent` is false for a product row (print_effects), which shapes
        // other rows' wire values instead of being sent itself.
        QVariantMap row{{"key",text(field.key)},{"label",text(field.label)},{"initial",variant(field.initial)},
            {"layer",field.layer==desktop::SettingLayer::shoot?"shoot":"print"},{"sent",field.wire},
            {"type",field.type==desktop::SettingType::boolean?"bool":field.type==desktop::SettingType::number?"number":"text"}};
        if(field.type==desktop::SettingType::number){row["from"]=field.low;row["to"]=field.high;}
        if(field.type==desktop::SettingType::text) {
            if(field.choices==desktop::SettingChoices::listed) {
                QStringList choices;for(const auto& choice:field.listed)choices.append(text(choice));
                row["choices"]=choices;
            } else row["catalog"]=field.choices==desktop::SettingChoices::films?"films":"papers";
        }
        result.push_back(row);
    }
    return result;
}
QVariant PreviewController::parameter(const QString& key) const {
    const auto* field=desktop::find_setting(key.toStdString());
    return field?variant(settings().get(field->key)):QVariant();
}
bool PreviewController::setParameter(const QString& key,const QVariant& value) {
    const auto* field=desktop::find_setting(key.toStdString());
    if(!field)return false;
    auto converted=settingValue(*field,value);
    return converted&&applyParameter(*field,std::move(*converted));
}
void PreviewController::setAdjustment(const QString& name,const QVariant& value) {
    const auto* field=desktop::find_setting(wireKey(name).toStdString());
    if(!field)return;
    // The first QML's lenient conversions, kept for its callers: anything
    // reads as a bool, and text that parses as a number is a number.
    desktop::SettingValue converted;
    if(field->type==desktop::SettingType::boolean)converted=value.toBool();
    else if(field->type==desktop::SettingType::number) {
        bool ok=false;const double v=value.toDouble(&ok);if(!ok)return;converted=v;
    } else converted=value.toString().toStdString();
    applyParameter(*field,std::move(converted));
}
bool PreviewController::applyParameter(const desktop::SettingField& field,desktop::SettingValue value) {
    if(!settingsEditable()||!desktop::check_setting(field,value,&catalog_).empty())return false;
    // The stocks and the brightness keep their own state (catalogue indexes,
    // stops) and their own rules: the paper follows the film, no paper for a
    // slide, silver film on silver paper (selectFilm / selectPaper).
    if(field.key=="film_stock"||field.key=="print_stock") {
        const bool film=field.key=="film_stock";
        const int index=indexOf(film?catalog_.films:catalog_.papers,std::get<std::string>(value));
        return film?chooseFilm(index):choosePaper(index);
    }
    if(field.key=="print_exposure") {
        if(filmIsPositive())return false;
        // Stops, brighter positive: the wire value is 2^-stops (API-SPEC §2).
        const double ev=-std::log2(std::get<double>(value));
        if(ev!=exposure_ev_){exposure_ev_=ev;changed("print_exposure");}
        return true;
    }
    auto next=extra_settings_;
    next.set(field.key,std::move(value));
    if(next!=extra_settings_){extra_settings_=std::move(next);changed(text(field.key));}
    return true;
}
QVariantList PreviewController::libraryItems() const {
    QVariantList result;
    for(int i=0;i<int(library_.size());++i) {
        const auto& item=library_[i];
        result.push_back(QVariantMap{{"name",QFileInfo(item.url.toLocalFile()).fileName()},
            {"url",item.url},{"thumbnail",item.thumbnail},{"active",i==active_index_},
            {"selected",item.selected},{"error",item.error}});
    }
    return result;
}
int PreviewController::selectedCount() const {
    int count=0;for(const auto& item:library_)count+=item.selected;return count;
}
void PreviewController::saveActiveSettings(bool recordHistory) {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    auto& item=library_[active_index_];const auto desired=settings();
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    // A saved pending edit has no rendered thumbnail yet. Do not let the
    // strip present an older look as if it represented the new settings.
    const bool changed=!sameSettings(item.settings,desired)||item.mode!=mode||item.geometry!=geometry_;
    // A Post-Dev change needs no render: the thumbnail is regraded, not dropped.
    const bool graded=item.postdev!=postdev_;
    if(changed||graded){
        if(recordHistory)recordEdit(item,itemState(item));
        if(changed)item.thumbnail={};
        item.pending_save=true;
    }
    item.settings=desired;item.mode=mode;
    item.geometry=geometry_;item.postdev=postdev_;
    if(changed||graded){scheduleSave();emit libraryChanged();emit historyChanged();}
}
void PreviewController::updateThumbnail() {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    auto& item=library_[active_index_];
    // From the navigator (at most 1024 px, already area-averaged), so this
    // stays cheap on the GUI thread and keeps 16-bit-class precision.
    item.thumbnail=dirty()||navigator_.isNull()?QImage{}:gradedThumbnail(desktop::display::thumbnailImage(navigator_));
    item.error.clear();emit libraryChanged();
}
int PreviewController::addFile(const QUrl& url) {
    if(!url.isLocalFile())return -1;
    const QFileInfo info(url.toLocalFile());
    if(!info.isFile())return -1;
    const auto local=QUrl::fromLocalFile(info.canonicalFilePath());
    for(int i=0;i<int(library_.size());++i)
        if(library_[i].url.toLocalFile().compare(local.toLocalFile(),Qt::CaseInsensitive)==0)return i;
    LibraryItem item;item.url=local;item.settings=settings();
    item.mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    const auto stored=edit_store_.load(local,catalog_);
    item.save_blocked=stored.blocked;item.save_warning=stored.warning;item.preserved=stored.preserved;
    if(stored.state){item.settings=stored.state->settings;item.mode=stored.state->mode;item.geometry=stored.state->geometry;
        item.postdev=stored.state->postDev;item.has_stored=true;}
    library_.push_back(std::move(item));emit libraryChanged();return int(library_.size())-1;
}
void PreviewController::openFiles(const QVariantList& urls) {
    if(!ready_||busy_)return;
    saveActiveSettings();int first=-1;
    for(const auto& url:urls){const int index=addFile(url.toUrl());if(first<0&&index>=0)first=index;}
    if(first>=0)openItem(first);
}
void PreviewController::selectImage(int index) {
    if(!ready_||busy_||dialog_open_||index<0||index>=int(library_.size())||index==active_index_)return;
    saveActiveSettings();openItem(index);
}
void PreviewController::setItemSelected(int index,bool selected) {
    if(busy_||dialog_open_||index<0||index>=int(library_.size()))return;
    library_[index].selected=selected;emit libraryChanged();
}
void PreviewController::selectAllPhotos(bool selected) {
    if(busy_||dialog_open_)return;
    for(auto& item:library_)item.selected=selected;emit libraryChanged();
}
void PreviewController::syncSelectedSettings(bool includeCrop) {
    if(!frame_||busy_||dialog_open_)return;
    saveActiveSettings();int count=0;
    for(int i=0;i<int(library_.size());++i)if(i!=active_index_&&library_[i].selected){
        auto& item=library_[i];auto next=currentState();
        if(!includeCrop)next.geometry=item.geometry;
        // Post-Dev is not copied: the Mac's clipboard groups leave
        // `adjustments` out (SettingsClipboard.swift notCopied), and its Sync
        // writes exactly those groups (Session.syncSettings).
        next.postDev=item.postdev;
        next.settings=pastedPlacement(next.settings);
        if(sameState(itemState(item),next))continue;
        // Each recipient owns its own undo history, just like its settings.
        item.undo.push_back(itemState(item));if(item.undo.size()>64)item.undo.erase(item.undo.begin());item.redo.clear();
        item.settings=next.settings;item.mode=next.mode;item.geometry=next.geometry;item.pending_save=true;
        item.thumbnail={};item.error.clear();++count;
    }
    status_=uiText(includeCrop?"status.syncedWithCrop":"status.syncedKeepingCrops",{QString::number(count)});
    scheduleSave();emit libraryChanged();emit historyChanged();emit stateChanged();
}
void PreviewController::setCropRect(const QRectF& crop) {
    auto next=geometry_;next.crop=crop;setGeometry(next,"cropRect");
}
void PreviewController::setCropGeometry(const QRectF& crop,double straightenDegrees) {
    if(!std::isfinite(straightenDegrees))return;
    auto next=geometry_;next.crop=crop;next.straightenDegrees=std::clamp(straightenDegrees,-45.0,45.0);
    setGeometry(next,"cropRect");
}
void PreviewController::setGeometry(const output::Geometry& geometry,const QString& editKey) {
    if(!frame_||busy_||dialog_open_||geometry==geometry_)return;
    try {
        auto next=visibleImage(frame_,full_image_,geometry);
        auto navigator=desktop::display::navigatorImage(next);
        auto bins=desktop::display::histogram(next);
        if(gesture_index_>=0&&gesture_key_!=editKey)endEditGesture();
        image_=std::move(next);navigator_=std::move(navigator);histogram_=std::move(bins);
        geometry_=geometry;saveActiveSettings(true);updateThumbnail();
        failed_=false;refreshOriginal(false);emit geometryChanged();emit frameChanged();emit stateChanged();
    } catch(const std::exception& e){failed_=true;status_=text(e.what());emit stateChanged();}
}
void PreviewController::resetCrop(){setCropRect(QRectF(0,0,1,1));}
void PreviewController::setCropAspect(double ratio) {
    if(!frame_||!std::isfinite(ratio)||ratio<0)return;
    if(ratio==0){resetCrop();return;}
    // Ratios describe the displayed result, even after a quarter turn.
    if(geometry_.quarterTurns%2)ratio=1/ratio;
    const double original=double(frame_->width())/frame_->height();
    double w=1,h=1;
    if(original>ratio)w=ratio/original;else h=original/ratio;
    setCropRect(QRectF((1-w)/2,(1-h)/2,w,h));
}
void PreviewController::cancelExport(){if(cancel_batch_)cancel_batch_->store(true);}

editing::State PreviewController::itemState(const LibraryItem& item) {
    return {item.settings,item.mode,item.geometry,item.postdev};
}
editing::State PreviewController::currentState() const {
    return {settings(),decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16,geometry_,postdev_};
}
bool PreviewController::canUndo() const {
    return settingsEditable()&&active_index_>=0&&!library_[active_index_].undo.empty();
}
bool PreviewController::canRedo() const {
    return settingsEditable()&&active_index_>=0&&!library_[active_index_].redo.empty();
}
void PreviewController::recordEdit(LibraryItem& item,const editing::State& before) {
    if(gesture_index_!=active_index_||!gesture_recorded_) {
        item.undo.push_back(before);
        if(item.undo.size()>64)item.undo.erase(item.undo.begin());
        item.redo.clear();
        if(gesture_index_==active_index_)gesture_recorded_=true;
    }
}
void PreviewController::beginEditGesture(const QString& key) {
    if(!settingsEditable()||active_index_<0||key.isEmpty())return;
    endEditGesture();gesture_index_=active_index_;gesture_key_=canonicalEditKey(key);gesture_recorded_=false;gesture_redo_=library_[active_index_].redo;
    if(gesture_key_=="straightenDegrees")auto_apply_.stop();
}
void PreviewController::endEditGesture() {
    const bool heldGeometry=gesture_key_=="straightenDegrees";
    if(gesture_index_>=0&&gesture_index_<int(library_.size())&&gesture_recorded_) {
        auto& item=library_[gesture_index_];
        // A drag returning to its starting value is not an undo step.
        if(!item.undo.empty()&&sameState(item.undo.back(),itemState(item))){item.undo.pop_back();item.redo=std::move(gesture_redo_);}
    }
    gesture_index_=-1;gesture_key_.clear();gesture_recorded_=false;gesture_redo_.clear();emit historyChanged();
    if(heldGeometry)schedulePreview();
}
void PreviewController::undo(){restoreHistory(false);}
void PreviewController::redo(){restoreHistory(true);}
void PreviewController::restoreHistory(bool redo) {
    if(!frame_||!settingsEditable()||active_index_<0)return;
    endEditGesture();
    auto& item=library_[active_index_];auto& from=redo?item.redo:item.undo;
    auto& to=redo?item.undo:item.redo;
    if(from.empty())return;
    const auto target=from.back();
    try {
        // Prepare geometry before moving the history cursor. Allocation or
        // validation failure leaves the frame and both stacks intact.
        const bool geometryChangedNow=target.geometry!=geometry_;
        auto next=geometryChangedNow?visibleImage(frame_,full_image_,target.geometry):image_;
        auto navigator=geometryChangedNow?desktop::display::navigatorImage(next):navigator_;
        auto bins=geometryChangedNow?desktop::display::histogram(next):histogram_;
        to.push_back(currentState());if(to.size()>64)to.erase(to.begin());from.pop_back();
        geometry_=target.geometry;image_=std::move(next);navigator_=std::move(navigator);histogram_=std::move(bins);
        if(geometryChangedNow)refreshOriginal(false);
        const bool gradeChangedNow=target.postDev!=postdev_;postdev_=target.postDev;
        loadSettings(target.settings,target.mode);saveActiveSettings();
        if(gradeChangedNow)emit postDevChanged();
        ++settings_revision_;auto_apply_.stop();schedulePreview();updateThumbnail();
        failed_=false;status_=uiText(redo?"status.redone":"status.undone");
        if(geometryChangedNow){emit geometryChanged();emit frameChanged();}
        emit settingsChanged();emit stateChanged();emit historyChanged();
    }catch(const std::exception& e){failed_=true;status_=text(e.what());emit stateChanged();}
}
void PreviewController::scheduleSave() {
    save_timer_.start();emit stateChanged();
}
void PreviewController::flushEdits() {
    save_timer_.stop();
    for(auto& item:library_)if(item.pending_save&&!item.save_blocked) {
        try {edit_store_.save(item.url,itemState(item));item.pending_save=false;item.has_stored=true;item.save_warning.clear();}
        catch(const std::exception& e){item.save_warning=text(e.what());}
    }
    emit stateChanged();
}
QString PreviewController::persistenceWarning() const {
    QStringList warnings;
    for(const auto& item:library_)if(!item.save_warning.isEmpty())
        warnings.append(QFileInfo(item.url.toLocalFile()).fileName()+": "+item.save_warning);
    return warnings.join("\n");
}
QString PreviewController::savedStatus() const {
    if(!persistenceWarning().isEmpty())return uiText("saved.unsaved");
    for(const auto& item:library_)if(item.pending_save)return uiText("saved.saving");
    const auto* active=active_index_>=0?&library_[active_index_]:nullptr;
    // A newer build's fields do not render here; say so rather than let the
    // photograph silently look different from that build's.
    const QString preserved=active&&!active->preserved.isEmpty()
        ?uiText("saved.newerFields",{QString::number(active->preserved.size())}):QString();
    return uiText(active&&active->has_stored?"saved.saved":"saved.automatic")+preserved;
}
// Flips are stored in output axes. Rotating the displayed image also swaps
// those axes; without this a mirrored photo would turn the opposite way.
void PreviewController::rotateClockwise(){auto next=geometry_;next.quarterTurns=(next.quarterTurns+1)%4;std::swap(next.flipHorizontal,next.flipVertical);setGeometry(next,"quarterTurns");}
void PreviewController::rotateCounterClockwise(){auto next=geometry_;next.quarterTurns=(next.quarterTurns+3)%4;std::swap(next.flipHorizontal,next.flipVertical);setGeometry(next,"quarterTurns");}
void PreviewController::setFlipHorizontal(bool value){auto next=geometry_;next.flipHorizontal=value;setGeometry(next,"flipHorizontal");}
void PreviewController::setFlipVertical(bool value){auto next=geometry_;next.flipVertical=value;setGeometry(next,"flipVertical");}
void PreviewController::setStraightenDegrees(double value){auto next=geometry_;next.straightenDegrees=value;setGeometry(next,"straightenDegrees");}
void PreviewController::resetGeometry(){setGeometry(output::Geometry{});}

void PreviewController::exportBatch(const QUrl& folder,int format,int quality,int maxLongEdge) {
    if(!ready_||busy_||!folder.isLocalFile()||!selectedCount())return;
    saveActiveSettings();
    std::vector<LibraryItem> items;
    for(const auto& item:library_)if(item.selected)items.push_back(item);
    // Strip thumbnails from the job snapshot. Only one developed frame is
    // retained by the worker, regardless of the number of imported photos.
    for(auto& item:items)item.thumbnail={};
    const auto held=frame_;const auto resources=resources_;const auto destination=path(folder);
    const auto gen=++generation_;cancel_batch_=std::make_shared<std::atomic_bool>(false);
    const auto cancel=cancel_batch_;batch_progress_=0;batch_total_=int(items.size());
    submit([this,items=std::move(items),held,resources,destination,gen,cancel,format,quality,maxLongEdge](auto& host){
        Reply r;r.generation=gen;r.operation="batch-export";
        int done=0,skipped=0,errors=0,processed=0;QStringList details;
        try {
            const auto options=exportOptions(format,quality,maxLongEdge);
            if(!std::filesystem::is_directory(destination))throw std::runtime_error("Export destination is not a folder");
            const QString extension=format==0?".tif":format==3?".jpg":".png";
            QSet<QString> names;
            for(const auto& item:items) {
                if(cancel->load())break;
                const auto source=path(item.url);
                const QString stem=QFileInfo(item.url.toLocalFile()).completeBaseName();
                QString name=stem+extension;int suffix=2;
                while(names.contains(name.toCaseFolded()))name=stem+"-"+QString::number(suffix++)+extension;
                names.insert(name.toCaseFolded());
                const auto target=destination/std::filesystem::path(name.toStdWString());
                try {
                    if(std::filesystem::exists(target))++skipped;
                    else {
                        const bool useShown=held&&held->source==source&&held->decode_mode==item.mode&&sameSettings(held->settings,item.settings);
                        const auto developed=useShown?held:host.open_raw(source,item.mode,item.settings);
                        output::exportFrame(developed,target,item.geometry,options,resources,
                                            desktop::postdev::exportGrade(item.postdev));++done;
                    }
                }catch(const std::exception& e){++errors;details.append(name+": "+text(e.what()));}
                ++processed;
                QMetaObject::invokeMethod(this,[this,gen,processed]{if(generation_==gen){batch_progress_=processed;emit stateChanged();}},Qt::QueuedConnection);
            }
            // On the worker thread: uiText reads only its constant table.
            r.message=uiText(cancel->load()?"status.batchCancelled":"status.batchFinished",
                             {QString::number(done),QString::number(skipped),QString::number(errors)});
            if(errors)r.error=r.message+"\n"+details.join("\n");
        }catch(const std::exception& e){r.error=text(e.what());}
        return r;
    },uiText("status.batchExporting"),"batch-export");
}
