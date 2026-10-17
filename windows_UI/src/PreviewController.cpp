#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include "PostDevSurfaces.hpp"
#include "RecipeExport.hpp"
#include <QElapsedTimer>
#include <QMetaObject>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <optional>
#include <type_traits>
#include <variant>

namespace {
namespace desktop=spk::desktop;
namespace output=desktop::output;
namespace editing=desktop::editing;
namespace library=desktop::library;
namespace clipboard=desktop::clipboard;
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
    return sameSettings(a.settings,b.settings)&&a.mode==b.mode&&a.geometry==b.geometry&&a.heldGeometry==b.heldGeometry&&
        a.postDev==b.postDev&&a.pair==b.pair;
}
// The editor's geometry as the host takes it for a cut frame, and back.
desktop::EngineCut toCut(const output::Geometry& g) {
    return {g.crop.x(),g.crop.y(),g.crop.width(),g.crop.height(),g.quarterTurns,g.flipHorizontal,g.flipVertical,g.straightenDegrees};
}
output::Geometry fromCut(const desktop::EngineCut& c) {
    return {QRectF(c.x,c.y,c.w,c.h),c.quarter_turns,c.flip_h,c.flip_v,c.straighten_deg};
}
QImage visibleImage(const desktop::FramePtr& frame,const QImage& full,const output::Geometry& geometry) {
    // A cut frame already carries the crop (and the film around it): the
    // canvas, the thumbnails and the export take it whole (macOS
    // Session.canvasGeometry, Session+FilmEdge.swift:456).
    if(frame&&frame->cut)return full;
    QImage shown=geometry.quarterTurns==0&&!geometry.flipHorizontal&&!geometry.flipVertical&&geometry.straightenDegrees==0
        ?output::displayImage(full,geometry.crop):output::displayFrame(frame,geometry);
    // A live frame's pixels stand for the full frame's: the canvas reads the
    // scale off the image (publish), so the crop carries it too.
    if(shown.devicePixelRatio()!=full.devicePixelRatio())shown.setDevicePixelRatio(full.devicePixelRatio());
    return shown;
}
// A cut frame's undeveloped whole decode (Frame::source_preview, encoded
// sRGB) as the canvases take every picture: RGBX16FPx4 tagged with its colour
// space (FrameImage.hpp), so the crop editor's guide is colour-managed like
// the print. Made on the worker, in publish().
QImage sourceImage(const desktop::FramePtr& frame) {
    if(!frame||!frame->source_preview)return {};
    const auto& preview=*frame->source_preview;
    QImage bytes(preview.bgra8.data(),int(preview.width),int(preview.height),qsizetype(preview.width)*4,QImage::Format_ARGB32);
    if(bytes.isNull())return {};
    bytes.setColorSpace(QColorSpace::SRgb);
    QImage image=bytes.convertToFormat(QImage::Format_RGBX16FPx4);  // a copy; the tag is kept
    if(image.isNull())throw std::runtime_error("Cannot create the framing guide image");
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}
// The size the engine's film canvas will be before it is measured: macOS
// FilmCanvasEstimate (Session+FilmEdge.swift:145-176), which errs large.
QSize filmCanvasEstimate(QSize picture,const desktop::FilmFormat& format,const QString& view) {
    const double w=picture.width(),h=picture.height();
    if(w<=0||h<=0)return {};
    const double px=std::max(format.long_mm,format.short_mm)/std::max(w,h);
    const double acrossMM=format.gauge=="135"?24.0:56.0;
    const bool vertical=std::abs(w*px-acrossMM)<std::abs(h*px-acrossMM)&&w!=h;
    const double alongPx=vertical?h:w;
    const double filmWidth=format.gauge=="135"?35.0:61.0;
    double marginMM,acrossCanvasMM;
    if(view==QLatin1String("filed")){marginMM=1.0;acrossCanvasMM=(vertical?w:h)*px+2.2;}
    else {
        marginMM=format.id=="135_half"?0.5:(format.perforated?0.95:2.35);
        acrossCanvasMM=filmWidth+(format.perforated?0:0.15);
    }
    const double along=alongPx+2*std::round(marginMM/px),across=std::round(acrossCanvasMM/px);
    return vertical?QSize(int(across),int(along)):QSize(int(along),int(across));
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
    // A live frame (Frame::full_tier false) is the full frame at fewer
    // pixels: its device pixel ratio is pixels over the full frame's, so its
    // device-independent size is the full frame's and the canvas keeps zoom,
    // 100 % and the Original's placement when the full frame replaces it --
    // the scale arriving with the image, never a frame behind it.
    if(frame->width()>0&&frame->logicalWidth()!=frame->width())
        p.full.setDevicePixelRatio(double(frame->width())/frame->logicalWidth());
    p.convert_ms=double(clock.nsecsElapsed())/1e6;
    p.visible=visibleImage(frame,p.full,geometry);
    p.navigator=desktop::display::navigatorImage(p.visible);
    // The strip's whole picture: the uncropped print (a cut frame's print is
    // its own framing already), reduced as the navigator is, then to the box.
    p.whole=desktop::display::thumbnailImage(p.visible.size()==p.full.size()&&p.visible.cacheKey()==p.full.cacheKey()
                                             ?p.navigator:desktop::display::navigatorImage(p.full));
    // A cut frame's undeveloped whole decode, for the crop editor: the same
    // tagged half floats as the print, so the canvas colour-manages it too.
    if(frame->source_preview)p.source=sourceImage(frame);
    const auto histogramStart=clock.nsecsElapsed();
    p.histogram=desktop::display::histogram(p.visible);
    // Of what the crop editor shows: a cut frame's framing guide, else the
    // whole print.
    p.uncropped_histogram=desktop::display::histogram(p.source.isNull()?p.full:p.source);
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
                                     QString outputColorSpace,int previewLongEdge)
    :QObject(parent),resources_(resources),preview_long_edge_(previewLongEdge>0?std::uint32_t(previewLongEdge):0u),
     edit_directory_(editDirectory.isEmpty()?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+"/Edits":editDirectory),
     edit_store_(edit_directory_),
     image_factory_(factory?std::move(factory):ImageFactory(imageFromFrame)) {
    // What the Film Edge and Date Back sections show follows the settings,
    // the frame and the crop.
    for(auto signal:{&PreviewController::settingsChanged,&PreviewController::frameChanged,&PreviewController::geometryChanged})
        connect(this,signal,this,&PreviewController::filmEdgeChanged);
    // The half-frame pair's view follows the frame, the library and the rails
    // (PreviewControllerPairs.cpp); a placement waits for its develop.
    for(auto signal:{&PreviewController::settingsChanged,&PreviewController::frameChanged,&PreviewController::libraryChanged,
                     &PreviewController::stateChanged})
        connect(this,signal,this,&PreviewController::pairChanged);
    connect(this,&PreviewController::frameChanged,this,&PreviewController::pairFrameLanded);
    pair_commit_.setSingleShot(true);pair_commit_.setInterval(280);
    connect(&pair_commit_,&QTimer::timeout,this,&PreviewController::commitPairDrag);
    // A pair's frames graded each as its own, once per pause in a drag.
    pair_grade_timer_.setSingleShot(true);pair_grade_timer_.setInterval(60);
    connect(&pair_grade_timer_,&QTimer::timeout,this,&PreviewController::regradePair);
    // The soft proof follows the frame's encoding (PreviewControllerExport.cpp).
    connect(this,&PreviewController::frameChanged,this,&PreviewController::refreshSoftProof);
    auto_apply_.setSingleShot(true);auto_apply_.setInterval(180);
    connect(&auto_apply_,&QTimer::timeout,this,[this]{if(dirty())apply();});
    // The full frame, once the edits have stopped (macOS starts its native
    // render 400 ms after the last edit, ARCHITECTURE.md §7.3).
    full_timer_.setSingleShot(true);full_timer_.setInterval(400);
    connect(&full_timer_,&QTimer::timeout,this,&PreviewController::renderFull);
    // One thread: a newer picture replaces the one not yet started, never
    // runs beside it (requestVisible).
    visible_pool_=std::make_unique<QThreadPool>();visible_pool_->setMaxThreadCount(1);
    save_timer_.setSingleShot(true);save_timer_.setInterval(350);
    connect(&save_timer_,&QTimer::timeout,this,&PreviewController::flushEdits);
    // The canvas is fed from pixels() (publish), so the host's 8-bit copy
    // would be 132 MB per 33 MP frame nobody reads.
    desktop::HostOptions options;options.bgra8_display=false;options.preview_long_edge=preview_long_edge_;
    options.output_color_space=outputColorSpace.isEmpty()?std::string(kWorkingSpace):outputColorSpace.toStdString();
    setupPostDev();
    setupLibrary();
    worker_=std::thread([this,resources=std::move(resources),options]{workerLoop(resources,options);});
}
PreviewController::~PreviewController() {
    // The preview readers post to this object: none may still be running
    // when it goes (a reply already queued is dropped with the object).
    if(preview_pool_){preview_pool_->clear();preview_pool_->waitForDone();}
    if(visible_pool_){visible_pool_->clear();visible_pool_->waitForDone();}
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
    {std::lock_guard lock(host_mutex_);host_=host.get();}
    for(;;) {
        Job job;
        {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stopping_||!jobs_.empty();});
         if(stopping_)break;job=std::move(jobs_.front());jobs_.pop_front();}
        deliver(job(*host));
        analyse(*host); // the Pre-Dev rail's readings of a new frame (PreviewControllerPredev.cpp)
    }
    // No cancel may reach the host once it starts going.
    std::lock_guard lock(host_mutex_);host_=nullptr;
}
void PreviewController::cancelFullRender() {
    std::lock_guard lock(host_mutex_);
    if(host_)host_->cancel_full_render();
}
desktop::FramePtr PreviewController::fullFrame(desktop::PreviewHost& host,const desktop::FramePtr& held) {
    if(!held||held->full_tier)return held;
    // The session holds this photograph: the full tier of its settings (an
    // empty delta when they are the session's). Otherwise it is opened again.
    const auto current=host.current();
    if(current&&!current->pair&&current->source==held->source&&current->decode_mode==held->decode_mode)
        return host.render(held->settings,held->geometry,desktop::Tier::full);
    return host.open_raw(held->source,held->decode_mode,held->settings,held->geometry,desktop::Tier::full);
}
// The full frame follows a live one once the edits have stopped. Not for a
// pair, whose pieces render whole (PreviewControllerPairs.cpp).
void PreviewController::scheduleFullRender() {
    if(preview_long_edge_==0||!frame_||frame_->full_tier||frame_->pair||busy_||dialog_open_||dirty()){full_timer_.stop();return;}
    full_timer_.start();
}
void PreviewController::renderFull() {
    if(preview_long_edge_==0||!frame_||frame_->full_tier||frame_->pair||busy_||dialog_open_||dirty())return;
    const auto s=frame_->settings;const auto shown=frame_;const auto gen=++generation_;const auto revision=settings_revision_.load();
    const auto factory=image_factory_;const auto geometry=geometry_;
    full_job_=true;
    submit([this,s,shown,gen,revision,factory,geometry](auto& host){Reply r;r.generation=gen;r.settings_revision=revision;r.operation="render";r.geometry=geometry;
        try {
            const auto active=host.current();
            // Only on the session that made the live frame; anything else is
            // a newer state the next edit's render reconciles.
            if(!active||active->source!=shown->source||active->decode_mode!=shown->decode_mode)
                throw desktop::RenderCancelled();
            r.frame=host.render(s,shown->geometry,desktop::Tier::full);
            if(settings_revision_.load()==revision)r.publication=publish(factory,r.frame,geometry);
        }catch(const desktop::RenderCancelled&){r.frame=nullptr;r.cancelled=true;}
        catch(const std::exception& e){r.frame=nullptr;r.error=text(e.what());}return r;},uiText("status.renderingFull"),"render");
}
void PreviewController::requestVisible(VisibleJob make,VisibleTake take) {
    visible_next_=VisibleRequest{++visible_request_,std::move(make),std::move(take)};
    visible_current_pending_=true;
    if(!visible_running_)runVisible();
}
void PreviewController::retireVisible() {
    ++visible_request_;visible_next_.reset();visible_current_pending_=false;
    pair_grading_for_=nullptr;
}
void PreviewController::runVisible() {
    auto request=std::move(*visible_next_);visible_next_.reset();
    visible_running_=true;
    visible_pool_->start([this,request=std::move(request)]{
        Visible made;
        try{made=request.make();}catch(const std::exception& e){made={};made.error=text(e.what());}
        // Destroying the controller waits for this job, so `this` is alive;
        // a reply still queued then goes with the object.
        QMetaObject::invokeMethod(this,[this,id=request.id,take=request.take,made=std::move(made)]() mutable {
            visible_running_=false;
            if(id==visible_request_){visible_current_pending_=false;take(std::move(made));}
            if(visible_next_&&!visible_running_)runVisible();
        },Qt::QueuedConnection);
    });
}
void PreviewController::requestGeometryPicture() {
    if(!frame_)return;
    // A cut frame already carries the crop: its picture is the frame whatever
    // the geometry (visibleImage), and the render that follows replaces it.
    if(frame_->cut){retireVisible();return;}
    const auto frame=frame_;const auto full=full_image_;const auto geometry=geometry_;
    requestVisible([frame,full,geometry]{
        Visible v;
        v.image=visibleImage(frame,full,geometry);
        v.navigator=desktop::display::navigatorImage(v.image);
        v.histogram=desktop::display::histogram(v.image);
        return v;
    },[this](Visible v){
        if(!v.error.isEmpty()){failed_=true;status_=v.error;emit stateChanged();return;}
        image_=std::move(v.image);navigator_=std::move(v.navigator);histogram_=std::move(v.histogram);
        updateThumbnail();
        emit frameChanged();
    });
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
    if(reply.operation=="soft-proof"){acceptSoftProof(std::move(reply));return;}
    // The Original rides the same worker but is no operation: it neither
    // holds the controller busy nor reports one finished.
    if(reply.operation=="original"){acceptOriginal(std::move(reply));return;}
    if(reply.operation=="pair-analysis")return; // only asks the worker to measure the pair's frame again
    if(reply.operation=="render")full_job_=false;
    if(reply.generation!=generation_)return; // a retired generation never replaces the canvas
    // A full render the next edit cancelled is superseded too: that edit's
    // own render follows. A render whose picture was cut with a geometry no
    // longer wanted is not: a frame not cut is the same frame whatever the
    // crop (geometryEditable), so it lands and its picture is made again off
    // the GUI thread below. A cut frame's geometry edit supersedes by revision.
    const bool superseded=reply.operation=="render"&&(reply.settings_revision!=settings_revision_||reply.cancelled);
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
        bool repicture=false;
        try {
            auto published=std::move(reply.publication);
            if(published.full.isNull())throw std::runtime_error("Cannot create the display image");
            const bool opened=reply.operation=="open";
            auto geometry=opened?reply.geometry:geometry_;
            // A film edge holds the crop at its gate (Session.holdFilmEdgeCrop):
            // when the host had to reshape the crop it was asked for, that is
            // the framing -- on open, or for a render of the crop still wanted.
            const bool reshaped=reply.frame->cut&&fromCut(reply.frame->geometry)!=reply.geometry&&
                                (opened||geometry_==reply.geometry);
            if(reshaped)geometry=fromCut(reply.frame->geometry);
            // The worker's picture is cut with `geometry`: an open's own, or
            // today's for a render that is not superseded. A cut frame's
            // picture is the frame whichever crop it was asked for. A render
            // the geometry moved under while it developed (a straighten drag
            // through a live frame's full render) keeps its frame, and the
            // picture is made again with today's geometry (requestGeometryPicture).
            repicture=!reply.frame->cut&&published.geometry!=geometry;
            if(repicture&&opened)
                throw std::runtime_error("The developed picture does not match the crop");
            // A new decode (another photo, or another decode mode) makes the
            // held Original stale; a re-render of the same decode does not.
            const bool decodeChanged=!frame_||frame_->source!=reply.frame->source||
                frame_->decode_mode!=reply.frame->decode_mode||reply.operation=="open";
            // A picture still being made from the old frame no longer applies.
            retireVisible();
            frame_=std::move(reply.frame);full_image_=std::move(published.full);
            // A picture cut with an old geometry is never shown: the last
            // picture stays until today's lands (requestGeometryPicture below).
            if(!repicture) {
                image_=std::move(published.visible);navigator_=std::move(published.navigator);
                histogram_=std::move(published.histogram);
            }
            uncropped_histogram_=std::move(published.uncropped_histogram);
            source_image_=std::move(published.source);
            whole_thumb_=std::move(published.whole);
            convert_ms_=published.convert_ms;publish_ms_=published.total_ms;histogram_ms_=published.histogram_ms;
            geometry_=geometry;
            if(opened) {
                active_index_=reply.library_index;
                held_geometry_=active_index_>=0&&active_index_<int(library_.size())?library_[active_index_].held:std::nullopt;
                loadPostDev();
            }
            if(published.pair_grades)takePairGrades(*published.pair_grades);
            // The user's own crop, given back when the film edge goes off.
            if(reshaped&&!held_geometry_&&std::get<bool>(frame_->settings.get("overscan_active")))held_geometry_=reply.geometry;
            refreshOriginal(decodeChanged);
            if(repicture)requestGeometryPicture();
        }
        catch(const std::exception& e){failed_=true;status_=text(e.what());if(frame_)restoreSettings();}
        if(!failed_) {
            restoreSettings();
            updateThumbnail();
            status_=uiText(!frame_->full_tier?"status.renderedPreview":frame_->reprint()?"status.renderedReusedNegative":"status.rendered",
                           {QString::number(frame_->timings.render_ms/1000,'f',2)});
            // The frame lands with its picture: frameChanged then comes from
            // the picture made again, so the canvas never pairs the new
            // frame's scale with the last picture.
            if(!repicture)emit frameChanged();
            emit geometryChanged();if(reply.operation=="open")emit sourceOpened();
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
    // A live frame on screen and nothing left to apply: its full frame next.
    scheduleFullRender();
}
desktop::RenderSettings PreviewController::settings() const {
    desktop::RenderSettings s=extra_settings_;
    if(film_index_>=0&&std::size_t(film_index_)<catalog_.films.size())s.film_stock=catalog_.films[film_index_].id;
    if(paper_index_>=0&&std::size_t(paper_index_)<catalog_.papers.size())s.print_stock=catalog_.papers[paper_index_].id;
    s.print_exposure=std::exp2(-exposure_ev_);return s;
}
void PreviewController::restoreSettings() {
    // A pair's frame was developed with the engine's settings; the rails show
    // the film and the picked frame (HalfFramePair.hpp shown()).
    if(pairActive()&&frame_&&frame_->pair){loadSettings(pairShown(),frame_->decode_mode);saveActiveSettings();return;}
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
    if(pairActive())return pairDirty();
    // A frame cut for the engine is also stale when the geometry it was cut
    // with is not the one wanted, or when the frame should (not) be cut.
    const bool cut=wantsCut(geometry_);
    return !sameSettings(settings(),frame_->settings)||
        decode_mode_!=(frame_->decode_mode==desktop::DecodeMode::headroom?1:0)||
        cut!=frame_->cut||(cut&&toCut(geometry_)!=frame_->geometry);
}
bool PreviewController::filmIsPositive() const {
    return film_index_>=0&&std::size_t(film_index_)<catalog_.films.size()&&catalog_.films[film_index_].is_positive;
}
QString PreviewController::fileName() const {return frame_?QString::fromStdWString(frame_->source.filename().wstring()):QString();}
QUrl PreviewController::sourceFolder() const {return frame_?QUrl::fromLocalFile(QString::fromStdWString(frame_->source.parent_path().wstring())):QUrl();}
QVariantMap PreviewController::metadata() const {
    if(!frame_)return {};
    // The source is the whole decode the crop is drawn in, also while the
    // frame is the film around a cut picture.
    const auto source=decodeSize();
    // A TIFF, JPEG or PNG was decoded at the door (raw_white_balance.hpp):
    // `input` says what it was read as ("TIFF, Adobe RGB (1998)").
    const bool raw=pairActive()||library::rawFile(QString::fromStdWString(frame_->source.wstring()));
    // The picture's size at full resolution, also while a live frame is shown.
    const double k=frameScale();
    return {{"width",int(std::lround(image_.width()*k))},{"height",int(std::lround(image_.height()*k))},{"fullResolution",fullResolution()},
        {"sourceWidth",source.width()},{"sourceHeight",source.height()},
        {"camera",text(frame_->metadata.make+" "+frame_->metadata.model).trimmed()},
        {"raw",raw},{"input",raw?QString():text(frame_->metadata.decoder_name)},
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
    // original_full_ is the whole decode, also behind a cut frame (Film Edge,
    // a date on a cropped frame), whose Original follows the frame itself.
    const bool stale=decodeChanged||original_geometry_!=geometry_||
        (!original_full_.isNull()&&frame_&&original_full_.size()!=decodeSize())||
        (frame_&&frame_->cut&&original_for_!=frame_.get());
    if(decodeChanged)original_full_={};
    if(stale||!frame_) {
        // Retire anything in flight: its image no longer fits this frame.
        ++original_token_;original_pending_=false;
        original_={};original_histogram_.clear();
    }
    if(original_wanted_&&original_.isNull())requestOriginal();
    emit originalChanged();
}
// A cut frame's picture in the strip's pixels: the picture the engine was
// handed, centred where spk_overscan_geometry puts the gate (the canvas
// centre without a film edge -- the date alone cuts no strip around it).
QRectF PreviewController::cutPictureRect() const {
    if(!frame_||!frame_->cut)return {};
    // In the strip's pixels at full resolution, the picture's own unit, also
    // while a live frame is shown (frameScale).
    const double sw=frame_->logicalWidth(),sh=frame_->logicalHeight();
    const auto layout=QJsonDocument::fromJson(QByteArray::fromStdString(frame_->overscan_geometry)).object();
    const auto quad=layout.value("gates").toArray().first().toArray();
    double cx=sw/2,cy=sh/2;
    if(quad.size()==8){cx=cy=0;for(int i=0;i<4;++i){cx+=quad[2*i].toDouble()*sw/4;cy+=quad[2*i+1].toDouble()*sh/4;}}
    const double pw=frame_->picture_width,ph=frame_->picture_height;
    return QRectF(std::round(cx-pw/2),std::round(cy-ph/2),pw,ph);
}void PreviewController::requestOriginal() {
    if(!frame_)return;
    const auto token=++original_token_;original_pending_=true;original_error_.clear();
    const auto whole=original_full_;const auto geometry=geometry_;const auto encoding=frame_->encoding;
    const auto source=frame_->source;const auto mode=frame_->decode_mode;
    const QSize size=decodeSize();
    // A cut frame's print is the film around the picture the engine was
    // handed: the Original is that picture -- the decode cut by the frame's
    // own geometry -- in the gate's place on a canvas the strip's size, so
    // the two still share size and placement (before/after, Space).
    const bool cut=frame_->cut;const auto cutGeometry=fromCut(frame_->geometry);
    // The strip at full resolution: the Original is the full decode, and the
    // canvas draws a live print and it in the same full-size rectangle.
    const QSize strip(int(frame_->logicalWidth()),int(frame_->logicalHeight()));
    const QPoint gate=cut?cutPictureRect().topLeft().toPoint():QPoint();
    original_for_=frame_.get();
    {std::lock_guard lock(mutex_);
     jobs_.push_back([whole,geometry,encoding,source,mode,size,token,cut,cutGeometry,strip,gate](desktop::PreviewHost& host){
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
            if(cut) {
                const auto picture=output::displayImage(full,cutGeometry);
                QImage canvas(strip,picture.format());
                if(canvas.isNull())throw std::runtime_error("Cannot allocate the Original");
                canvas.fill(Qt::black);canvas.setColorSpace(picture.colorSpace());
                const int x0=std::clamp(gate.x(),0,std::max(0,strip.width()-picture.width()));
                const int y0=std::clamp(gate.y(),0,std::max(0,strip.height()-picture.height()));
                const int w=std::min(picture.width(),strip.width()-x0),bpp=picture.depth()/8;
                for(int y=0;y<std::min(picture.height(),strip.height()-y0);++y)
                    std::memcpy(canvas.scanLine(y0+y)+qsizetype(x0)*bpp,picture.constScanLine(y),std::size_t(w)*bpp);
                r.original=canvas;
            } else r.original=output::displayImage(full,geometry);
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
    // Inside setParameters every row is part of the one edit (beginBatchEdit).
    if(!batch_edit_&&gesture_index_>=0&&gesture_key_!=canonicalEditKey(editKey))endEditGesture();
    saveActiveSettings(true);
    ++settings_revision_;auto_apply_.stop();schedulePreview();
    // The full frame of the previous state is no longer wanted.
    full_timer_.stop();if(full_job_)cancelFullRender();
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
    if(pairActive()){resetPairEnlarger();return;} // the picked frame's print, or the film's (PreviewControllerPairs.cpp)
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
    // A new photograph's settings, but this frame keeps its film edge seeds,
    // and a film edge switched off gives the crop back.
    desktop::RenderSettings fresh;
    for(const char* key:{"overscan_camera_seed","overscan_frame_seed","overscan_frame_number","film_edge_seeded"})
        fresh.set(key,extra_settings_.get(key));
    auto geometry=geometry_;auto held=held_geometry_;
    if(!pairActive())filmEdgeWillChange(extra_settings_,fresh,geometry,held);
    const bool moved=geometry!=geometry_;
    geometry_=geometry;held_geometry_=held;
    if(moved)requestGeometryPicture();  // the picture follows, with frameChanged
    loadSettings(fresh,desktop::DecodeMode::compatible16);changed();
    if(moved)emit geometryChanged();
}
void PreviewController::openRaw(const QUrl& url) {
    // Changing sources and exporting remain single flight. Parameter edits
    // can be coalesced during a render, but cannot retarget an in-flight open.
    if(!ready_||busy_||!url.isLocalFile())return;
    // A folder is a library to look through (Session.open(urls:)).
    if(QFileInfo(url.toLocalFile()).isDir()){openFiles({url});return;}
    saveActiveSettings();
    const int index=addFile(url);if(index<0)return;
    adoptPairs(); // the folder's half-frame pairs follow their first frames (never before `index`)
    requestPreviews();
    // A known photo restores its own saved settings. A genuinely new photo
    // still starts with the current preset; opening never overwrites a sidecar.
    openItem(index);
}
void PreviewController::openItem(int index) {
    endEditGesture();
    if(library_.at(index).pair){openPairItem(index);return;}
    const auto item=library_.at(index);const auto p=path(item.url);
    const auto gen=++generation_;const auto factory=image_factory_;
    const auto tier=preview_long_edge_?desktop::Tier::live:desktop::Tier::full;
    submit([p,item,gen,index,factory,tier](auto& host){Reply r;r.generation=gen;r.operation="open";r.library_index=index;r.geometry=item.geometry;
        // A frame whose images cannot be made is not delivered: the reply
        // fails and the displayed frame stays (the host's session has moved
        // on; the next render reconciles it). The geometry goes too: the host
        // cuts the picture with it when the settings ask for that.
        try{r.frame=host.open_raw(p,item.mode,item.settings,toCut(item.geometry),tier);r.publication=publish(factory,r.frame,item.geometry);}
        catch(const std::exception& e){r.frame=nullptr;r.error=text(e.what());}return r;},uiText("status.opening"),"open");
}
void PreviewController::apply() {
    if(!frame_||busy_||dialog_open_)return;
    if(pairActive()){applyPair();return;}
    const auto s=settings();const auto shown=frame_;const auto gen=++generation_;const auto revision=settings_revision_.load();
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    // The geometry goes too: the host cuts the picture with it when the
    // settings ask for that (a film edge, a date on a cropped frame).
    const auto factory=image_factory_;const auto geometry=geometry_;const auto cut=toCut(geometry);
    const auto tier=preview_long_edge_?desktop::Tier::live:desktop::Tier::full;
    submit([this,s,shown,gen,revision,mode,factory,geometry,cut,tier](auto& host){Reply r;r.generation=gen;r.settings_revision=revision;r.operation="render";r.geometry=geometry;
        try {
            // Publication can fail after a successful worker open (for example,
            // a display allocation failure). Reconcile against the image the
            // user is actually editing before reusing the worker's session.
            const auto active=host.current();
            r.frame=active&&active->source==shown->source&&active->decode_mode==mode
                ?host.render(s,cut,tier):host.open_raw(shown->source,mode,s,cut,tier);
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
    // A cut frame is exported whole: with a film edge the file is the strip
    // (Session.printGeometry, Session+FilmEdge.swift:459).
    const auto p=path(url);const auto held=frame_;const auto gen=++generation_;const auto resources=resources_;
    const auto geometry=frame_->cut?output::Geometry{}:geometry_;
    // Post-Dev on the frame the engine returned, before geometry, as every
    // export path grades (PostDevSurfaces.hpp; AGENTS.md trap 33) -- for a
    // cut frame the whole film canvas, as the Mac grades it (Exporter
    // .filePixels: applyLayer2 on the engine's print, then printGeometry).
    const auto grade=pairActive()?pairExportGrade(library_[active_index_],held):desktop::postdev::exportGrade(postdev_);
    // A frame in the working space is converted into sRGB once before the
    // sRGB-tagged writers see it (RecipeExport.hpp exportLegacy).
    submit([p,held,gen,geometry,resources,format,quality,maxLongEdge,grade](auto& host){Reply r;r.generation=gen;r.operation="export";
        try{desktop::exporting::exportLegacy(fullFrame(host,held),p,geometry,exportOptions(format,quality,maxLongEdge),resources,grade,host.engine());}
        catch(const std::exception& e){r.error=text(e.what());}return r;},uiText("status.exporting"),"export");
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
    // Date Back switched on takes a face its camera can print.
    if(field.key=="date_imprint_active"&&std::get<bool>(next.get("date_imprint_active"))) {
        const auto photo=photoInfo(geometry_);
        if(!desktop::date_back_prints(next,photo,std::get<std::string>(next.get("date_imprint_style"))))
            for(const char* face:{"lcd","dots","data"})
                if(desktop::date_back_prints(next,photo,face)){next.set("date_imprint_style",std::string(face));break;}
    }
    return applySettings(std::move(next),text(field.key));
}
// One edit of the settings, with what macOS does around a Film Edge change
// (Session.filmEdgeWillChange, Session+FilmEdge.swift:396-417): the crop goes
// into the gate and comes back out with it, and the body the user picks is
// their body for new frames. Settings and crop move as one undo step.
bool PreviewController::applySettings(desktop::RenderSettings next,const QString& editKey) {
    if(next==extra_settings_)return true;
    auto geometry=geometry_;auto held=held_geometry_;
    // A pair's piece is already the gate's shape: no crop to hold
    // (Session+FilmEdge.swift:400-405).
    if(!pairActive())filmEdgeWillChange(extra_settings_,next,geometry,held);
    const double body=std::get<double>(extra_settings_.get("overscan_camera_seed"));
    const bool moved=geometry!=geometry_;
    extra_settings_=std::move(next);
    geometry_=geometry;held_geometry_=held;
    if(moved)requestGeometryPicture();  // the picture follows, with frameChanged
    const double nowBody=std::get<double>(extra_settings_.get("overscan_camera_seed"));
    if(nowBody!=body)setBodySeed(int(nowBody));
    changed(editKey);
    if(moved)emit geometryChanged();
    return true;
}
QSize PreviewController::decodeSize() const {
    if(!frame_)return {};
    return frame_->decode_width&&frame_->decode_height?QSize(int(frame_->decode_width),int(frame_->decode_height))
                                                      :QSize(int(frame_->logicalWidth()),int(frame_->logicalHeight()));
}
desktop::PhotoInfo PreviewController::photoInfo(const output::Geometry& g) const {
    desktop::PhotoInfo photo;
    if(frame_)photo.shooting=frame_->metadata.shooting;
    const auto size=decodeSize();
    photo.decode_width=std::uint32_t(std::max(0,size.width()));photo.decode_height=std::uint32_t(std::max(0,size.height()));
    photo.geometry=toCut(g);
    photo.pair.active=pairActive(); // a pair's date back is a half-frame camera's; its piece is never cut
    return photo;
}
bool PreviewController::wantsCut(const output::Geometry& g) const {return desktop::cuts_frame(settings(),photoInfo(g));}
output::Geometry PreviewController::heldAtGate(const output::Geometry& g,const desktop::RenderSettings& s,int landscape) const {
    const auto size=decodeSize();
    if(size.isEmpty())return g;
    return fromCut(desktop::gate_framed(toCut(g),s,std::uint32_t(size.width()),std::uint32_t(size.height()),landscape));
}
void PreviewController::filmEdgeWillChange(const desktop::RenderSettings& from,const desktop::RenderSettings& to,
                                           output::Geometry& geometry,std::optional<output::Geometry>& held) const {
    const bool was=std::get<bool>(from.get("overscan_active")),now=std::get<bool>(to.get("overscan_active"));
    if(!was&&now) {
        held=geometry;
        geometry=heldAtGate(geometry,to,-1);
    } else if(was&&!now) {
        if(held)geometry=*held;
        held.reset();
    } else if(now&&from.get("overscan_format")!=to.get("overscan_format")) {
        geometry=heldAtGate(geometry,to,-1);
    }
}
bool PreviewController::setFilmEdgeActive(bool on){return setParameter("overscan_active",on);}
bool PreviewController::setDateBackActive(bool on){return setParameter("date_imprint_active",on);}
void PreviewController::flipFilmEdgeGate() {
    if(!std::get<bool>(extra_settings_.get("overscan_active")))return;
    const auto size=decodeSize();if(size.isEmpty())return;
    const bool landscape=geometry_.crop.width()*size.width()>=geometry_.crop.height()*size.height();
    setGeometry(heldAtGate(geometry_,extra_settings_,landscape?0:1),"filmEdgeGate");
}
void PreviewController::anotherCameraBody() {
    // Body numbers stay short enough to read as a serial plate (1...999).
    const int current=int(std::get<double>(extra_settings_.get("overscan_camera_seed")));
    int next=current;
    while(next==current)next=QRandomGenerator::global()->bounded(1,1000);
    setParameter("overscan_camera_seed",double(next));
}
void PreviewController::anotherFrameAdvance() {
    const auto current=std::get<double>(extra_settings_.get("overscan_frame_seed"));
    double next=current;
    while(next==current)next=double(QRandomGenerator::global()->bounded(1,2147483647));
    setParameter("overscan_frame_seed",next);
}
int PreviewController::bodySeed() {
    QSettings store(edit_directory_+"/preferences.ini",QSettings::IniFormat);
    const int stored=store.value("filmEdge/bodySeed",0).toInt();
    if(stored>0)return stored;
    const int drawn=QRandomGenerator::global()->bounded(1,1000);
    setBodySeed(drawn);
    return drawn;
}
void PreviewController::setBodySeed(int seed) {
    if(seed<=0)return;
    QDir().mkpath(edit_directory_);
    QSettings store(edit_directory_+"/preferences.ini",QSettings::IniFormat);
    store.setValue("filmEdge/bodySeed",seed);
}
bool PreviewController::geometryInNegative() const {return wantsCut(geometry_);}
double PreviewController::cropLockRatio() const {
    if(!std::get<bool>(extra_settings_.get("overscan_active")))return 0;
    const auto size=decodeSize();
    const bool landscape=size.isEmpty()||geometry_.crop.width()*size.width()>=geometry_.crop.height()*size.height();
    return desktop::gate_ratio(extra_settings_,landscape);
}
QVariantList PreviewController::filmFormats() const {
    QVariantList out;
    for(const auto& f:desktop::film_formats())
        out.push_back(QVariantMap{{"id",text(f.id)},{"title",text(f.title)},{"group",text(f.group)},
            {"gate",text(f.gate_label)},{"ratio",text(f.ratio)},{"stripCost",f.strip_cost},{"filedCost",f.filed_cost},
            {"perforated",f.perforated},{"longMm",f.long_mm},{"shortMm",f.short_mm}});
    return out;
}
QVariantMap PreviewController::filmEdge() const {
    const auto s=settings();
    const bool active=std::get<bool>(s.get("overscan_active"));
    const auto* format=desktop::film_format(std::get<std::string>(s.get("overscan_format")));
    QVariantMap out{{"active",active},
        {"edgeText",format?text(desktop::edge_text(catalog_,s.film_stock,format->gauge)):QString()},
        {"fNumber",frame_?frame_->metadata.shooting.f_number:0.0}};
    // The picture's own pixels: the crop at the decode's size (Session
    // .edgePicturePixels), and the film built around them.
    const auto size=decodeSize();
    std::uint32_t pw=0,ph=0;
    if(!size.isEmpty())desktop::cut_size(toCut(geometry_),std::uint32_t(size.width()),std::uint32_t(size.height()),pw,ph);
    out["pictureWidth"]=int(pw);out["pictureHeight"]=int(ph);
    out["upright"]=geometry_.crop.width()*std::max(1,size.width())<geometry_.crop.height()*std::max(1,size.height());
    out["gateRatio"]=cropLockRatio();
    // Measured: spk_overscan_geometry of the frame on screen, when it is a
    // film edge render of the framing wanted now.
    QJsonObject geometry;
    if(frame_&&frame_->cut)geometry=QJsonDocument::fromJson(QByteArray::fromStdString(frame_->overscan_geometry)).object();
    const bool valid=geometry.value("valid").toBool();
    const bool current=valid&&active&&frame_->geometry==toCut(geometry_)&&sameSettings(frame_->settings,s);
    QSize film;
    if(current)film=QSize(geometry.value("canvas_w").toInt(),geometry.value("canvas_h").toInt());
    else if(format&&pw&&ph)film=filmCanvasEstimate(QSize(int(pw),int(ph)),*format,QString::fromStdString(std::get<std::string>(s.get("overscan_mode"))));
    out["filmWidth"]=film.width();out["filmHeight"]=film.height();out["filmMeasured"]=current;
    out["shown"]=valid;
    out["canvasWidth"]=geometry.value("canvas_w").toInt();out["canvasHeight"]=geometry.value("canvas_h").toInt();
    QVariantList gates;
    for(const auto& quad:geometry.value("gates").toArray()) {
        QVariantList q;for(const auto& v:quad.toArray())q.push_back(v.toDouble());
        gates.push_back(q);
    }
    out["gates"]=gates;
    return out;
}
QVariantMap PreviewController::dateBack() const {
    const auto s=settings();
    const auto photo=photoInfo(geometry_);
    const auto* camera=desktop::date_back_camera(s,photo);
    QVariantMap prints,onCamera;bool any=false;
    for(const char* face:{"lcd","dots","data"}) {
        const bool p=desktop::date_back_prints(s,photo,face);any=any||p;
        prints[face]=p;onCamera[face]=camera&&camera->has_date_back;
    }
    const auto& shooting=photo.shooting;
    const auto exif=desktop::date_text(shooting,std::get<std::string>(s.get("date_back_order")));
    // The menu's examples: this frame's date in each order, or the drawing's.
    spk::io::ShootingData example=shooting;
    if(example.year==0){example.year=2026;example.month=10;example.day=1;}
    std::uint32_t pw=0,ph=0;
    if(photo.decode_width)desktop::cut_size(photo.geometry,photo.decode_width,photo.decode_height,pw,ph);
    // A half frame held level is the portrait one (DateBackSection.cameraNote).
    const bool turned=camera&&pw&&ph&&((ph>pw)!=(camera->id=="135_half"));
    const bool halfData=std::get<std::string>(s.get("date_imprint_style"))=="data"&&camera&&camera->id=="135_half";
    return {{"camera",camera?text(camera->id):QString()},{"cameraTitle",camera?text(camera->title):QString()},
        {"cameraFromEdge",std::get<bool>(s.get("overscan_active"))},{"hasBack",any},
        {"effective",desktop::date_back_effective(s,photo)},{"printsInMargin",camera&&camera->prints_in_margin},
        {"panoramic",camera&&!camera->has_date_back},
        {"prints",prints},{"onCamera",onCamera},{"exifDate",text(exif)},{"hasExifDate",shooting.year!=0},
        {"examples",QVariantMap{{"japan",text(desktop::date_text(example,"japan"))},{"us",text(desktop::date_text(example,"us"))}}},
        {"printed",text(desktop::printed_date_text(s,shooting))},{"dataText",text(desktop::data_text(shooting))},
        {"dataPrintable",desktop::date_back_prints(s,photo,"data")},{"turned",turned},{"sizeMax",halfData?1.0:3.0},
        {"pictureKnown",pw>0}};
}
QVariantList PreviewController::libraryItems() const {
    QVariantList result;
    for(int i=0;i<int(library_.size());++i)result.push_back(libraryItem(i));
    return result;
}
QVariantMap PreviewController::libraryItem(int i) const {
    // A cell the strip has not dropped yet may ask past the end: an empty
    // item, with images QML can still assign.
    if(i<0||i>=int(library_.size()))return {{"strip",QImage()},{"thumbnail",QImage()}};
    const auto& item=library_[i];
    // `thumbnail`: the rendered print as the canvas shows it (cropped);
    // `strip`: the whole picture under the crop mask, what the filmstrip and
    // the export page draw (CropMaskedThumbnail.swift).
    return {{"name",item.pair?desktop::pairs::title(item.url.toLocalFile()):QFileInfo(item.url.toLocalFile()).fileName()},
        {"url",item.url},{"thumbnail",item.thumbnail},{"strip",stripImage(i)},{"active",i==active_index_},
        {"selected",item.selected},{"error",item.error},{"pair",item.pair.has_value()},
        {"rendered",!item.thumbnail.isNull()}};
}
int PreviewController::selectedCount() const {
    int count=0;for(const auto& item:library_)count+=item.selected;return count;
}
void PreviewController::saveActiveSettings(bool recordHistory) {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    if(library_[active_index_].pair){savePairSettings(recordHistory);return;}
    auto& item=library_[active_index_];const auto desired=settings();
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    // A saved pending edit has no rendered thumbnail yet. Do not let the
    // strip present an older look as if it represented the new settings.
    const bool changed=!sameSettings(item.settings,desired)||item.mode!=mode||item.geometry!=geometry_||item.held!=held_geometry_;
    // A Post-Dev change needs no render: the thumbnail is regraded, not dropped.
    const bool graded=item.postdev!=postdev_;
    if(changed||graded){
        if(recordHistory)recordEdit(item,itemState(item));
        if(changed){item.thumbnail={};item.whole={};}
        item.pending_save=true;
    }
    item.settings=desired;item.mode=mode;
    item.geometry=geometry_;item.held=held_geometry_;item.postdev=postdev_;
    if(changed||graded){scheduleSave();emit libraryChanged();emit historyChanged();}
}
void PreviewController::updateThumbnail() {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    auto& item=library_[active_index_];
    // From the navigator (at most 1024 px, already area-averaged), so this
    // stays cheap on the GUI thread and keeps 16-bit-class precision. None
    // while the picture is being made again: the navigator is the last one's.
    item.thumbnail=dirty()||navigator_.isNull()||!pictureSettled()?QImage{}
        :gradedThumbnail(desktop::display::thumbnailImage(navigator_));
    item.whole=item.thumbnail.isNull()?QImage{}:wholeThumbnail();
    item.whole_cut=frame_&&frame_->cut;
    item.error.clear();emit libraryChanged();
}
int PreviewController::addFile(const QUrl& url) {
    if(!url.isLocalFile())return -1;
    const QFileInfo info(url.toLocalFile());
    if(!info.isFile())return -1;
    if(desktop::pairs::isPairFile(info.filePath()))return addPairFile(info.canonicalFilePath());
    const auto local=QUrl::fromLocalFile(info.canonicalFilePath());
    for(int i=0;i<int(library_.size());++i)
        if(library_[i].url.toLocalFile().compare(local.toLocalFile(),Qt::CaseInsensitive)==0)return i;
    LibraryItem item;item.url=local;item.settings=settings();
    item.mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    const auto stored=edit_store_.load(local,catalog_);
    item.save_blocked=stored.blocked;item.save_warning=stored.warning;item.preserved=stored.preserved;
    if(stored.state){item.settings=stored.state->settings;item.mode=stored.state->mode;item.geometry=stored.state->geometry;
                     item.held=stored.state->heldGeometry;item.postdev=stored.state->postDev;item.has_stored=true;}
    // A frame's film edge seeds, the first time it is opened (Session
    // .seedFilmEdge): a frame seed of its own, the user's body, and its
    // number on the roll -- its place in the session. A new photo is seeded
    // even when its preset came from another photo; it has its own crop, so
    // a film edge it inherits holds nothing of the other photo's.
    if(!item.has_stored||!std::get<bool>(item.settings.get("film_edge_seeded"))) {
        const auto file=info.canonicalFilePath().toUtf8();
        desktop::seed_film_edge(item.settings,std::string_view(file.constData(),std::size_t(file.size())),
                                int(library_.size()),bodySeed());
        if(!item.has_stored)item.held=std::get<bool>(item.settings.get("overscan_active"))
            ?std::optional<output::Geometry>(output::Geometry{}):std::nullopt;
    }
    library_.push_back(std::move(item));emit libraryChanged();return int(library_.size())-1;
}
void PreviewController::openFiles(const QVariantList& urls) {
    if(!ready_||busy_)return;
    // Folders listed, files passed (Library.frames(from:)); one folder's files
    // come in the order kept for it (FrameOrder.applied).
    QList<QUrl> given;for(const auto& url:urls)given.push_back(url.toUrl());
    const auto files=order_.applied(library::expand(given));
    if(files.isEmpty()) {
        // Session.open(urls:): "Nothing openable in the selection."
        status_=uiText("status.nothingOpenable");emit stateChanged();return;
    }
    saveActiveSettings();int first=-1;
    const int before=int(library_.size());
    for(const auto& file:files){const int index=addFile(QUrl::fromLocalFile(file));if(first<0&&index>=0)first=index;}
    // The folders' half-frame pairs follow their first frames, then what was
    // added takes its folder's kept order with them; the first photograph is
    // found again after they are in.
    const QUrl opened=first>=0?library_[first].url:QUrl();
    adoptPairs();
    applyFolderOrder(before);
    for(int i=0;i<int(library_.size())&&first>=0;++i)if(library_[i].url==opened){first=i;break;}
    requestPreviews();
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
    // Session.selectAllFrames: the open photograph stays the sync source; a
    // library with none open opens its first.
    if(selected&&active_index_<0&&!library_.empty()&&ready_)openItem(0);
}
// Session.syncSettings (:3747-3762): a fresh snapshot of the open photograph,
// never the older clipboard, written with the ticked groups onto every other
// picked photograph. The source is left alone (its fitted Scene Placement,
// its history), and the clipboard too. Each recipient takes it as one undo
// step of its own; there is no batch undo (README "Select and sync photos").
void PreviewController::syncSelectedSettings(bool includeCrop) {
    if(!frame_||busy_||dialog_open_||clipboard_groups_.isEmpty())return;
    saveActiveSettings();
    // From a pair, what the rails show (the film and the picked frame).
    const clipboard::Clip clip{clipboard_groups_,settings(),fileName()};
    // The crop only when asked (it belongs to the photograph otherwise), and
    // never onto a pair, which has none.
    const auto crop=geometry_;
    int count=0;
    for(const int i:syncTargets())count+=pasteOffline(clip,i,includeCrop?&crop:nullptr);
    status_=count?uiText(includeCrop?"status.syncedWithCrop":"status.syncedKeepingCrops",{QString::number(count)})
                 :uiText("status.syncNothing");
    scheduleSave();emit libraryChanged();emit historyChanged();emit stateChanged();emit clipboardChanged();
}
void PreviewController::setCropRect(const QRectF& crop) {
    auto next=geometry_;next.crop=crop;setGeometry(next,"cropRect");
}
void PreviewController::setCropGeometry(const QRectF& crop,double straightenDegrees) {
    if(!std::isfinite(straightenDegrees))return;
    auto next=geometry_;next.crop=crop;next.straightenDegrees=std::clamp(straightenDegrees,-45.0,45.0);
    setGeometry(next,"cropRect");
}
void PreviewController::setGeometry(const output::Geometry& requested,const QString& editKey) {
    // Also while a frame not cut develops -- a live frame's full render runs
    // for seconds at 33 MP, and a straighten drag must not lose its steps.
    if(!geometryEditable()||dialog_open_)return;
    // A pair has no crop: its frames are placed under their holes instead.
    if(pairActive())return;
    // A film edge holds the crop at its gate's shape, in the crop's own
    // orientation (Geometry.lockedRatio, Session+FilmEdge.swift:375-390).
    const auto geometry=std::get<bool>(extra_settings_.get("overscan_active"))?heldAtGate(requested,extra_settings_,-1):requested;
    if(geometry==geometry_)return;
    try {
        // Refused before anything moves; the picture itself is made off the
        // GUI thread (requestGeometryPicture) and lands with frameChanged.
        if(!frame_->cut)output::validateGeometry(full_image_.size(),geometry);
        if(gesture_index_>=0&&gesture_key_!=editKey)endEditGesture();
        geometry_=geometry;saveActiveSettings(true);
        failed_=false;
        // In the negative (a film edge, a date on a cropped frame) the crop
        // is the framing in the gate: it re-develops, as a setting does.
        // The full frame of the previous state is then no longer wanted.
        if(frame_->cut||wantsCut(geometry_)) {
            ++settings_revision_;auto_apply_.stop();schedulePreview();
            full_timer_.stop();if(full_job_)cancelFullRender();
            status_=uiText("status.updatingPreview");emit settingsChanged();
        }
        requestGeometryPicture();updateThumbnail();refreshOriginal(false);
        emit geometryChanged();emit stateChanged();
    } catch(const std::exception& e){failed_=true;status_=text(e.what());emit stateChanged();}
}
void PreviewController::resetCrop(){setCropRect(QRectF(0,0,1,1));}
void PreviewController::setCropAspect(double ratio) {
    if(!frame_||!std::isfinite(ratio)||ratio<0)return;
    if(ratio==0){resetCrop();return;}
    // Ratios describe the displayed result, even after a quarter turn.
    if(geometry_.quarterTurns%2)ratio=1/ratio;
    const auto size=decodeSize();
    const double original=double(size.width())/size.height();
    double w=1,h=1;
    if(original>ratio)w=ratio/original;else h=original/ratio;
    setCropRect(QRectF((1-w)/2,(1-h)/2,w,h));
}
void PreviewController::cancelExport(){if(cancel_batch_)cancel_batch_->store(true);}

editing::State PreviewController::itemState(const LibraryItem& item) {
    return {item.settings,item.mode,item.geometry,item.held,item.postdev,item.pair};
}
editing::State PreviewController::currentState() const {
    if(pairActive())return pairState();
    return {settings(),decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16,geometry_,held_geometry_,postdev_};
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
        // Validate geometry before moving the history cursor: a refusal leaves
        // the frame and both stacks intact. The picture follows off the GUI
        // thread (requestGeometryPicture) and lands with frameChanged.
        const bool geometryChangedNow=target.geometry!=geometry_;
        if(geometryChangedNow&&!frame_->cut)output::validateGeometry(full_image_.size(),target.geometry);
        to.push_back(currentState());if(to.size()>64)to.erase(to.begin());from.pop_back();
        geometry_=target.geometry;held_geometry_=target.heldGeometry;
        if(geometryChangedNow){requestGeometryPicture();refreshOriginal(false);}
        const bool gradeChangedNow=target.postDev!=postdev_;postdev_=target.postDev;
        if(target.pair)restorePair(target); // the piece, its frames and their grades, then the rails from them
        else loadSettings(target.settings,target.mode);
        saveActiveSettings();
        if(gradeChangedNow)emit postDevChanged();
        ++settings_revision_;auto_apply_.stop();schedulePreview();updateThumbnail();
        failed_=false;status_=uiText(redo?"status.redone":"status.undone");
        if(geometryChangedNow)emit geometryChanged();
        emit settingsChanged();emit stateChanged();emit historyChanged();
    }catch(const std::exception& e){failed_=true;status_=text(e.what());emit stateChanged();}
}
void PreviewController::scheduleSave() {
    save_timer_.start();emit stateChanged();
}
void PreviewController::flushEdits() {
    save_timer_.stop();
    for(auto& item:library_)if(item.pending_save&&!item.save_blocked) {
        if(item.pair){savePair(item);continue;} // the pair's own record (HalfFramePair.hpp)
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
    for(auto& item:items)dropImages(item);
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
                        // The shown frame serves when it was developed from the
                        // same settings and, if cut, from the same framing.
                        bool useShown=held&&held->source==source&&held->decode_mode==item.mode&&sameSettings(held->settings,item.settings);
                        if(useShown) {
                            desktop::PhotoInfo photo{held->metadata.shooting,held->decode_width,held->decode_height,toCut(item.geometry)};
                            const bool cut=desktop::cuts_frame(item.settings,photo);
                            useShown=cut==held->cut&&(!cut||held->geometry==toCut(item.geometry));
                        }
                        const auto developed=item.pair?developPair(host,item,held) // one picture (Exporter.swift)
                            :useShown?fullFrame(host,held):host.open_raw(source,item.mode,item.settings,toCut(item.geometry));
                        desktop::exporting::exportLegacy(developed,target,developed->cut?output::Geometry{}:item.geometry,options,
                                                         resources,item.pair?pairExportGrade(item,developed):desktop::postdev::exportGrade(item.postdev),host.engine());++done;
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
