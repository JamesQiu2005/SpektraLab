#include "PreviewController.hpp"
#include <QColorSpace>
#include <QMetaObject>
#include <cmath>

namespace {
namespace desktop=spk::desktop;
QString text(const std::string& s) { return QString::fromUtf8(s.data(),qsizetype(s.size())); }
std::filesystem::path path(const QUrl& u) { return std::filesystem::path(u.toLocalFile().toStdWString()); }
QVariantList list(const std::vector<desktop::Stock>& stocks) {
    QVariantList result;
    for(const auto& s:stocks) result.push_back(QVariantMap{{"id",text(s.id)},{"name",text(s.label)}});
    return result;
}
}
QImage PreviewController::imageFromFrame(const desktop::FramePtr& frame) {
    // QImage is implicitly shared; the cleanup holder keeps the independently
    // owned engine result and its display bytes alive on the scene-graph side.
    auto held=std::make_unique<desktop::FramePtr>(frame);
    QImage image(frame->bgra8.data(),int(frame->width()),int(frame->height()),
                 qsizetype(frame->width())*4,QImage::Format_ARGB32,
                 [](void* p){delete static_cast<desktop::FramePtr*>(p);},held.get());
    if(image.isNull()) throw std::runtime_error("Cannot create the display image");
    held.release();
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}

PreviewController::PreviewController(std::filesystem::path resources,QObject* parent,ImageFactory factory)
    :QObject(parent),image_factory_(factory?std::move(factory):ImageFactory(imageFromFrame)) {
    worker_=std::thread([this,resources=std::move(resources)]{workerLoop(resources);});
}
PreviewController::~PreviewController() {
    ++generation_;
    {std::lock_guard lock(mutex_);stopping_=true;jobs_.clear();}
    wake_.notify_one();
    if(worker_.joinable()) worker_.join();
}
void PreviewController::workerLoop(std::filesystem::path resources) {
    std::unique_ptr<desktop::PreviewHost> host;
    Reply init;init.operation="init";
    try {host=std::make_unique<desktop::PreviewHost>(resources);init.catalog=host->catalog();}
    catch(const std::exception& e){init.error=text(e.what());}
    deliver(std::move(init));
    if(!host)return;
    for(;;) {
        Job job;
        {std::unique_lock lock(mutex_);wake_.wait(lock,[&]{return stopping_||!jobs_.empty();});
         if(stopping_)break;job=std::move(jobs_.front());jobs_.pop_front();}
        deliver(job(*host));
    }
}
void PreviewController::deliver(Reply reply) {
    QMetaObject::invokeMethod(this,[this,reply=std::move(reply)]() mutable {accept(std::move(reply));},Qt::QueuedConnection);
}
void PreviewController::submit(Job job,QString status) {
    busy_=true;failed_=false;status_=std::move(status);emit stateChanged();
    {std::lock_guard lock(mutex_);jobs_.push_back(std::move(job));}
    wake_.notify_one();
}
void PreviewController::accept(Reply reply) {
    if(reply.generation!=generation_)return; // a retired generation never replaces the canvas
    busy_=false;failed_=!reply.error.isEmpty();
    if(failed_) {
        status_=reply.error;
        if(frame_&&reply.operation!="export")restoreSettings();
    } else if(reply.operation=="init") {
        ready_=true;catalog_=std::move(reply.catalog);films_=list(catalog_.films);papers_=list(catalog_.papers);
        restoreSettings();emit catalogChanged();status_=QStringLiteral("就绪 · 打开 RAW 开始");
    } else if(reply.frame) {
        // Allocate the presentation wrapper before publishing any new UI state.
        try {auto next=image_factory_(reply.frame);if(next.isNull())throw std::runtime_error("Cannot create the display image");frame_=std::move(reply.frame);image_=std::move(next);}
        catch(const std::exception& e){failed_=true;status_=text(e.what());if(frame_)restoreSettings();}
        if(!failed_) {
            restoreSettings();
            status_=QStringLiteral("渲染完成 %1 秒%2 · 可导出 16 位 TIFF")
                .arg(frame_->timings.render_ms/1000,0,'f',2)
                .arg(frame_->reprint()?QStringLiteral(" · 已复用负片"):QString());
            emit frameChanged();if(reply.operation=="open")emit sourceOpened();
        }
    } else if(reply.operation=="export") status_=QStringLiteral("已导出当前画面的 16 位 TIFF");
    emit stateChanged();
    if(reply.operation=="init")emit initialized(!failed_);
    else emit operationFinished(reply.operation,!failed_);
}
desktop::RenderSettings PreviewController::settings() const {
    desktop::RenderSettings s;
    if(film_index_>=0&&std::size_t(film_index_)<catalog_.films.size())s.film_stock=catalog_.films[film_index_].id;
    if(paper_index_>=0&&std::size_t(paper_index_)<catalog_.papers.size())s.print_stock=catalog_.papers[paper_index_].id;
    s.print_exposure=std::exp2(-exposure_ev_);return s;
}
void PreviewController::restoreSettings() {
    const auto s=frame_?frame_->settings:desktop::RenderSettings{};
    for(std::size_t i=0;i<catalog_.films.size();++i)if(catalog_.films[i].id==s.film_stock)film_index_=int(i);
    for(std::size_t i=0;i<catalog_.papers.size();++i)if(catalog_.papers[i].id==s.print_stock)paper_index_=int(i);
    exposure_ev_=-std::log2(s.print_exposure);
    decode_mode_=frame_&&frame_->decode_mode==desktop::DecodeMode::headroom?1:0;
    emit settingsChanged();
}
bool PreviewController::dirty() const {
    if(!frame_)return false;
    const auto s=settings();return s.film_stock!=frame_->settings.film_stock||s.print_stock!=frame_->settings.print_stock||
        std::abs(s.print_exposure-frame_->settings.print_exposure)>1e-12||
        decode_mode_!=(frame_->decode_mode==desktop::DecodeMode::headroom?1:0);
}
QString PreviewController::fileName() const {return frame_?QString::fromStdWString(frame_->source.filename().wstring()):QString();}
QUrl PreviewController::sourceFolder() const {return frame_?QUrl::fromLocalFile(QString::fromStdWString(frame_->source.parent_path().wstring())):QUrl();}
QVariantMap PreviewController::metadata() const {
    if(!frame_)return {};
    return {{"width",frame_->width()},{"height",frame_->height()},
        {"camera",text(frame_->metadata.make+" "+frame_->metadata.model)},
        {"decodeMs",frame_->timings.decode_ms},{"renderMs",frame_->timings.render_ms},
        {"totalMs",frame_->timings.total_ms},{"cached",frame_->reprint()},
        {"mode",frame_->decode_mode==desktop::DecodeMode::headroom?"headroom":"compatible16"}};
}
void PreviewController::changed(){if(frame_)status_=QStringLiteral("设置已修改 · 点击“应用效果”更新画面");failed_=false;emit settingsChanged();emit stateChanged();}
void PreviewController::setFilmIndex(int v){if(busy_||v<0||v>=films_.size()||v==film_index_)return;film_index_=v;changed();}
void PreviewController::setPaperIndex(int v){if(busy_||v<0||v>=papers_.size()||v==paper_index_)return;paper_index_=v;changed();}
void PreviewController::setDecodeMode(int v){if(busy_||v<0||v>1||v==decode_mode_)return;decode_mode_=v;changed();}
void PreviewController::setExposureEv(double v){if(busy_||!std::isfinite(v)||v< -2||v>2||v==exposure_ev_)return;exposure_ev_=v;changed();}
void PreviewController::resetSettings(){if(busy_)return;for(int i=0;i<films_.size();++i)if(catalog_.films[i].id=="kodak_portra_400")film_index_=i;for(int i=0;i<papers_.size();++i)if(catalog_.papers[i].id=="kodak_portra_endura")paper_index_=i;decode_mode_=0;exposure_ev_=0;changed();}
void PreviewController::openRaw(const QUrl& url) {
    // Single flight is intentional in this first slice. Disabling conflicting
    // commands also prevents a superseded host session from diverging from the
    // last successfully displayed frame when a later open fails.
    if(!ready_||busy_||!url.isLocalFile())return;
    const auto p=path(url);const auto s=settings();const auto m=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    const auto gen=++generation_;
    submit([p,s,m,gen](auto& host){Reply r;r.generation=gen;r.operation="open";
        try{r.frame=host.open_raw(p,m,s);}catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在解码并渲染 RAW…"));
}
void PreviewController::apply() {
    if(!frame_||busy_)return;
    if(decode_mode_!=(frame_->decode_mode==desktop::DecodeMode::headroom?1:0)) {
        openRaw(QUrl::fromLocalFile(QString::fromStdWString(frame_->source.wstring())));return;
    }
    const auto s=settings();const auto shown=frame_;const auto gen=++generation_;
    submit([s,shown,gen](auto& host){Reply r;r.generation=gen;r.operation="render";
        try {
            // Publication can fail after a successful worker open (for example,
            // a display allocation failure). Reconcile against the image the
            // user is actually editing before reusing the worker's session.
            const auto active=host.current();
            r.frame=active&&active->source==shown->source&&active->decode_mode==shown->decode_mode
                ?host.render(s):host.open_raw(shown->source,shown->decode_mode,s);
        }catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在更新胶片效果…"));
}
void PreviewController::exportTiff(const QUrl& url) {
    if(!frame_||busy_||!url.isLocalFile())return;
    const auto p=path(url);const auto held=frame_;const auto gen=++generation_;
    submit([p,held,gen](auto& host){Reply r;r.generation=gen;r.operation="export";
        try{host.export_tiff(*held,p);}catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在导出当前画面…"));
}
