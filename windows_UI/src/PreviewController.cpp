#include "PreviewController.hpp"
#include <QColorSpace>
#include <QCryptographicHash>
#include <QDateTime>
#include <QFile>
#include <QMetaObject>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QUuid>
#include <cmath>

namespace {
namespace desktop=spk::desktop;
namespace output=desktop::output;
namespace editing=desktop::editing;
QString text(const std::string& s) { return QString::fromUtf8(s.data(),qsizetype(s.size())); }
std::filesystem::path path(const QUrl& u) { return std::filesystem::path(u.toLocalFile().toStdWString()); }
QVariantList list(const std::vector<desktop::Stock>& stocks) {
    QVariantList result;
    for(const auto& s:stocks) result.push_back(QVariantMap{{"id",text(s.id)},{"name",text(s.label)},{"positive",s.is_positive}});
    return result;
}
bool sameSettings(desktop::RenderSettings a, desktop::RenderSettings b) {
    const bool exposure=std::abs(a.print_exposure-b.print_exposure)<1e-12;
    a.print_exposure=b.print_exposure;
    return exposure&&a==b;
}
bool sameState(const editing::State& a,const editing::State& b) {
    return sameSettings(a.settings,b.settings)&&a.mode==b.mode&&a.geometry==b.geometry;
}
QImage visibleImage(const desktop::FramePtr& frame,const QImage& full,const output::Geometry& geometry) {
    if(geometry.quarterTurns==0&&!geometry.flipHorizontal&&!geometry.flipVertical&&geometry.straightenDegrees==0)
        return output::displayImage(full,geometry.crop);
    return output::displayFrame(frame,geometry);
}
output::ExportOptions exportOptions(int format,int quality,int maxEdge,int space,int copyMetadata,
                                    const QString& metadata={}) {
    if(format<0||format>4||quality<1||quality>100||maxEdge<0||maxEdge>100000||space<0||space>3)
        throw std::runtime_error("Invalid export options");
    return {static_cast<output::Format>(format),quality,maxEdge,
        static_cast<output::OutputSpace>(space),bool(copyMetadata),copyMetadata?metadata:QString()};
}
desktop::RenderSettings defaultSettings() {
    desktop::RenderSettings s;
    s.advanced=desktop::default_advanced_settings();
    return s;
}
QVariant settingVariant(const desktop::SettingValue& value) {
    return std::visit([](const auto& v) {
        if constexpr(std::is_same_v<std::decay_t<decltype(v)>,std::string>)
            return QVariant(QString::fromStdString(v));
        return QVariant::fromValue(v);
    }, value);
}
}
QImage PreviewController::imageFromFrame(const desktop::FramePtr& frame) {
    auto image=output::workingFrame(frame).convertToFormat(QImage::Format_ARGB32);
    if(image.isNull()) throw std::runtime_error("Cannot create the display image");
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}

PreviewController::PreviewController(std::filesystem::path resources,QObject* parent,ImageFactory factory,QString editDirectory)
    :QObject(parent),extra_settings_(defaultSettings()),resources_(resources),
     edit_store_(editDirectory.isEmpty()?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+"/Edits":editDirectory),
     image_factory_(factory?std::move(factory):ImageFactory(imageFromFrame)),
     // An injected edit directory owns its whole state. The default keeps the
     // catalogue beside, not inside, the Edits subdirectory.
     catalog_file_(QFileInfo(QDir(editDirectory.isEmpty()?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation):editDirectory).filePath("Library.json")).absoluteFilePath()),
     sources_file_(QFileInfo(catalog_file_).dir().filePath("sources.json")) {
    auto_apply_.setSingleShot(true);auto_apply_.setInterval(180);
    connect(&auto_apply_,&QTimer::timeout,this,[this]{if(dirty())apply();});
    save_timer_.setSingleShot(true);save_timer_.setInterval(350);
    connect(&save_timer_,&QTimer::timeout,this,&PreviewController::flushEdits);
    worker_=std::thread([this,resources=std::move(resources)]{workerLoop(resources);});
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
void PreviewController::submit(Job job,QString status,QString operation) {
    auto_apply_.stop();active_operation_=std::move(operation);
    busy_=true;failed_=false;status_=std::move(status);emit stateChanged();emit historyChanged();
    {std::lock_guard lock(mutex_);jobs_.push_back(std::move(job));}
    wake_.notify_one();
}
void PreviewController::accept(Reply reply) {
    if(reply.generation!=generation_)return; // a retired generation never replaces the canvas
    const bool superseded=reply.operation=="render"&&reply.settings_revision!=settings_revision_;
    busy_=false;active_operation_.clear();failed_=!superseded&&!reply.error.isEmpty();
    if(superseded) {
        // The worker may finish an earlier choice after the next click. Keep
        // both the displayed frame and the newest desired controls; never flash
        // the retired result or restore its settings over the user's last edit.
        status_=dirty()?QStringLiteral("正在更新预览…"):QStringLiteral("预览已是当前选择");
    } else if(failed_) {
        status_=reply.error;
        if(frame_&&reply.operation!="export"&&reply.operation!="batch-export")restoreSettings();
    } else if(reply.operation=="init") {
        ready_=true;catalog_=std::move(reply.catalog);films_=list(catalog_.films);papers_=list(catalog_.papers);
        loadSourceRegistry();
        loadCatalog();
        restoreSettings();emit catalogChanged();status_=QStringLiteral("就绪 · 打开 RAW 开始");
    } else if(reply.frame) {
        // Allocate the presentation wrapper before publishing any new UI state.
        try {
            auto next=image_factory_(reply.frame);
            if(next.isNull())throw std::runtime_error("Cannot create the display image");
            const auto geometry=reply.operation=="open"?reply.geometry:geometry_;
            auto visible=visibleImage(reply.frame,next,geometry);
            frame_=std::move(reply.frame);full_image_=std::move(next);image_=std::move(visible);
            geometry_=geometry;
            if(reply.operation=="open")active_index_=reply.library_index;
        }
        catch(const std::exception& e){failed_=true;status_=text(e.what());if(frame_)restoreSettings();}
        if(!failed_) {
            restoreSettings();
            updateThumbnail();
            status_=QStringLiteral("渲染完成 %1 秒%2")
                .arg(frame_->timings.render_ms/1000,0,'f',2)
                .arg(frame_->reprint()?QStringLiteral(" · 已复用胶片"):QString());
            emit frameChanged();emit geometryChanged();if(reply.operation=="open")emit sourceOpened();
        }
    } else if(reply.operation=="export") status_=QStringLiteral("已导出当前画面");
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
    if(extra_settings_.advanced.empty())extra_settings_.advanced=defaultSettings().advanced;
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
        {"mode",frame_->decode_mode==desktop::DecodeMode::headroom?"headroom":"compatible16"}};
}
void PreviewController::schedulePreview(){if(!dialog_open_&&gesture_key_!="straightenDegrees"&&frame_&&dirty()&&!auto_apply_.isActive())auto_apply_.start();}
void PreviewController::setDialogOpen(bool open){
    if(dialog_open_==open)return;
    dialog_open_=open;
    if(open){endEditGesture();auto_apply_.stop();}else schedulePreview();
    emit stateChanged();emit historyChanged();
}
void PreviewController::changed(const QString& editKey){
    if(gesture_index_>=0&&gesture_key_!=editKey)endEditGesture();
    saveActiveSettings(true);
    ++settings_revision_;auto_apply_.stop();schedulePreview();
    if(frame_)status_=QStringLiteral("正在更新预览…");
    failed_=false;emit settingsChanged();emit stateChanged();
}
void PreviewController::setFilmIndex(int v){if(!settingsEditable()||v<0||v>=films_.size()||v==film_index_)return;film_index_=v;changed("filmIndex");}
void PreviewController::setPaperIndex(int v){if(!settingsEditable()||filmIsPositive()||v<0||v>=papers_.size()||v==paper_index_)return;paper_index_=v;changed("paperIndex");}
void PreviewController::setDecodeMode(int v){if(!settingsEditable()||v<0||v>1||v==decode_mode_)return;decode_mode_=v;changed("decodeMode");}
void PreviewController::setExposureEv(double v){if(!settingsEditable()||filmIsPositive()||!std::isfinite(v)||v< -2||v>2||v==exposure_ev_)return;exposure_ev_=v;changed("exposureEv");}
void PreviewController::resetSettings(){if(!settingsEditable())return;loadSettings({},desktop::DecodeMode::compatible16);changed();}
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
    const auto pair=path(item.pair_url);
    const auto gen=++generation_;
    submit([p,pair,item,gen,index](auto& host){Reply r;r.generation=gen;r.operation="open";r.library_index=index;r.geometry=item.geometry;
        try{r.frame=item.pair_url.isEmpty()?host.open_raw(p,item.mode,item.settings):
            host.open_raw_pair(p,pair,item.mode,item.settings);}catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在解码并渲染 RAW…"),"open");
}
void PreviewController::apply() {
    if(!frame_||busy_||dialog_open_)return;
    const auto s=settings();const auto shown=frame_;const auto gen=++generation_;const auto revision=settings_revision_;
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    submit([s,shown,gen,revision,mode](auto& host){Reply r;r.generation=gen;r.settings_revision=revision;r.operation="render";
        try {
            // Publication can fail after a successful worker open (for example,
            // a display allocation failure). Reconcile against the image the
            // user is actually editing before reusing the worker's session.
            const auto active=host.current();
            r.frame=active&&active->source==shown->source&&active->decode_mode==mode
                ?host.render(s):host.open_raw(shown->source,mode,s);
        }catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在更新胶片效果…"),"render");
}
void PreviewController::exportTiff(const QUrl& url) {
    exportImage(url,0,95,0);
}
void PreviewController::exportImage(const QUrl& url,int format,int quality,int maxLongEdge) {
    exportImageWithRecipe(url,format,quality,maxLongEdge,0,false);
}
void PreviewController::exportImageWithRecipe(const QUrl& url,int format,int quality,
                                               int maxLongEdge,int outputSpace,bool copyMetadata) {
    if(!frame_||busy_||!url.isLocalFile())return;
    const auto p=path(url);const auto held=frame_;const auto gen=++generation_;const auto geometry=geometry_;const auto resources=resources_;
    submit([p,held,gen,geometry,resources,format,quality,maxLongEdge,outputSpace,copyMetadata](auto&){Reply r;r.generation=gen;r.operation="export";
        try{output::exportFrame(held,p,geometry,exportOptions(format,quality,maxLongEdge,outputSpace,copyMetadata),resources);}catch(const std::exception& e){r.error=text(e.what());}return r;},QStringLiteral("正在导出当前画面…"),"export");
}

QVariantMap PreviewController::adjustments() const {
    const auto& s=extra_settings_;
    QVariantMap result{{"filmExposureEv",s.film_exposure_ev},{"filmFormatMm",s.film_format_mm},
        {"grainActive",s.grain_active},{"grainAmount",s.grain_amount},
        {"halationActive",s.halation_active},{"halationAmount",s.halation_amount},
        {"glareActive",s.glare_active},{"glareAmount",s.glare_amount},
        {"yFilterShift",s.y_filter_shift},{"mFilterShift",s.m_filter_shift}};
    for(const auto& [name,value]:s.advanced)result.insert(QString::fromStdString(name),settingVariant(value));
    return result;
}
void PreviewController::setAdjustment(const QString& name,const QVariant& value) {
    if(!settingsEditable())return;
    auto next=extra_settings_;
    if(name=="grainActive")next.grain_active=value.toBool();
    else if(name=="halationActive")next.halation_active=value.toBool();
    else if(name=="glareActive")next.glare_active=value.toBool();
    else if(const auto found=next.advanced.find(name.toStdString());found!=next.advanced.end()) {
        if(std::holds_alternative<bool>(found->second)) {
            if(value.userType()!=QMetaType::Bool)return;
            found->second=value.toBool();
        } else if(std::holds_alternative<int>(found->second)) {
            bool ok=false;const double v=value.toDouble(&ok);
            if(!ok||!std::isfinite(v)||std::floor(v)!=v)return;
            found->second=int(v);
        } else if(std::holds_alternative<double>(found->second)) {
            bool ok=false;const double v=value.toDouble(&ok);
            if(!ok||!std::isfinite(v))return;
            found->second=v;
        } else {
            if(!value.canConvert<QString>())return;
            found->second=value.toString().toStdString();
        }
    } else {
        bool ok=false;const double v=value.toDouble(&ok);if(!ok||!std::isfinite(v))return;
        double* field=nullptr;double low=0,high=0;
        if(name=="filmExposureEv"){field=&next.film_exposure_ev;low=-8;high=8;}
        else if(name=="filmFormatMm"){field=&next.film_format_mm;low=4;high=200;}
        else if(name=="grainAmount"){field=&next.grain_amount;high=2;}
        else if(name=="halationAmount"){field=&next.halation_amount;high=4;}
        else if(name=="glareAmount"){field=&next.glare_amount;high=30;}
        else if(name=="yFilterShift"){field=&next.y_filter_shift;low=-1;high=1;}
        else if(name=="mFilterShift"){field=&next.m_filter_shift;low=-1;high=1;}
        else return;
        if(v<low||v>high)return;*field=v;
    }
    if(next==extra_settings_)return;
    extra_settings_=next;changed(name);
}
bool PreviewController::itemVisible(const LibraryItem& item) const {
    const auto key=QFileInfo(item.url.toLocalFile()).canonicalFilePath().toLower();
    if(collection_filter_==QStringLiteral("__trash__")) {
        if(!item.trashed)return false;
    } else {
        if(item.trashed)return false;
        const auto collection=std::find_if(collections_.begin(),collections_.end(),
            [this](const auto& value){return value.name==collection_filter_;});
        if(collection!=collections_.end()&&!collection->paths.contains(key))return false;
    }
    if(library_search_.trimmed().isEmpty())return true;
    const auto name=item.pair_name.isEmpty()?QFileInfo(item.url.toLocalFile()).fileName():item.pair_name;
    return name.contains(library_search_.trimmed(),Qt::CaseInsensitive);
}
std::vector<int> PreviewController::visibleIndices(bool sorted) const {
    std::vector<int> result;
    for(int i=0;i<int(library_.size());++i)if(itemVisible(library_[i]))result.push_back(i);
    if(!sorted||library_sort_==0)return result;
    const auto name=[](const LibraryItem& item) {
        return item.pair_name.isEmpty()?QFileInfo(item.url.toLocalFile()).fileName():item.pair_name;
    };
    std::stable_sort(result.begin(),result.end(),[&](int a,int b) {
        const auto& left=library_[a];const auto& right=library_[b];
        if(library_sort_==1)
            return name(left).compare(name(right),Qt::CaseInsensitive)>0;
        if(library_sort_==2&&left.rating!=right.rating)return left.rating>right.rating;
        if(library_sort_==3&&left.color_label!=right.color_label)return left.color_label<right.color_label;
        return name(left).compare(name(right),Qt::CaseInsensitive)<0;
    });
    return result;
}
int PreviewController::trashCount() const {
    return int(std::count_if(library_.begin(),library_.end(),
        [](const auto& item){return item.trashed;}));
}
QVariantList PreviewController::libraryItems() const {
    QVariantList result;
    for(const int i:visibleIndices()) {
        const auto& item=library_[i];
        const int variant_number=variantNumber(item),variant_total=variantCount(item);
        result.push_back(QVariantMap{{"name",item.pair_name.isEmpty()?QFileInfo(item.url.toLocalFile()).fileName():item.pair_name},
            {"url",item.url},{"thumbnail",item.thumbnail},{"active",i==active_index_},
            {"selected",item.selected},{"error",item.error},{"rating",item.rating},
            {"colorLabel",item.color_label},{"catalogIndex",i},{"isPair",!item.pair_url.isEmpty()},
            {"pairUrl",item.pair_url},{"variantNumber",variant_number},
            {"variantCount",variant_total},{"trashed",item.trashed}});
    }
    return result;
}
QVariantList PreviewController::librarySources() const {
    QVariantList result;
    for(int i=0;i<int(library_sources_.size());++i) {
        const auto& source=library_sources_[i];
        result.push_back(QVariantMap{{"name",source.name},{"path",source.path},
            {"root",source.root},{"kind",source.kind},{"selected",i==activeLibrarySource()}});
    }
    return result;
}
int PreviewController::activeLibrarySource() const {
    for(int i=0;i<int(library_sources_.size());++i)
        if(QFileInfo(library_sources_[i].path).absoluteFilePath()==catalog_file_)return i;
    return -1;
}
QString PreviewController::sourceName(const QString& catalogFile) const {
    const auto folder=QFileInfo(catalogFile).dir();
    auto name=folder.dirName();
    if(name.endsWith(".spkcatalog",Qt::CaseInsensitive))name.chop(11);
    return name.isEmpty()?QStringLiteral("默认目录"):name;
}
void PreviewController::loadSourceRegistry() {
    library_sources_.clear();
    QFile file(sources_file_);
    QString selected;
    if(file.open(QIODevice::ReadOnly)) {
        const auto root=QJsonDocument::fromJson(file.readAll()).object();
        selected=QFileInfo(root.value("selected").toString()).absoluteFilePath();
        for(const auto value:root.value("sources").toArray()) {
            const auto entry=value.toObject();
            if(entry.value("path").toString().isEmpty())continue;
            const auto path=QFileInfo(entry.value("path").toString()).absoluteFilePath();
            const auto same=[&](const auto& source){return source.path==path;};
            if(std::any_of(library_sources_.begin(),library_sources_.end(),same))continue;
            library_sources_.push_back({entry.value("name").toString(),path,
                qint64(entry.value("openedAt").toDouble()),
                entry.value("kind").toString(QStringLiteral("catalog")),entry.value("root").toString()});
        }
    }
    if(!selected.isEmpty()&&QFileInfo(selected).isFile())catalog_file_=selected;
    if(std::none_of(library_sources_.begin(),library_sources_.end(),
                    [&](const auto& source){return source.path==catalog_file_;}))
        library_sources_.push_back({sourceName(catalog_file_),catalog_file_,0});
}
bool PreviewController::saveSourceRegistry() {
    QJsonArray sources;
    for(const auto& source:library_sources_)
        sources.append(QJsonObject{{"name",source.name},{"path",source.path},
            {"openedAt",double(source.opened)},{"kind",source.kind},{"root",source.root}});
    QDir().mkpath(QFileInfo(sources_file_).absolutePath());
    QSaveFile file(sources_file_);
    if(!file.open(QIODevice::WriteOnly))return false;
    const QJsonObject root{{"version",2},{"sources",sources},
        {"selected",catalog_file_}};
    return file.write(QJsonDocument(root).toJson(QJsonDocument::Indented))>=0&&file.commit();
}
bool PreviewController::switchLibrarySource(int index) {
    if(index<0||index>=int(library_sources_.size()))return false;
    const auto path=library_sources_[index].path;
    if(path==catalog_file_)return true;
    if(!QFileInfo(path).isFile()) {
        status_=QStringLiteral("目录已移动或不可用");emit stateChanged();return false;
    }
    saveActiveSettings();flushEdits();
    catalog_file_=path;
    library_.clear();collections_.clear();export_recipes_.clear();collection_filter_.clear();
    active_index_=-1;frame_.reset();image_={};full_image_={};geometry_={};
    loadCatalog();
    library_sources_[index].opened=QDateTime::currentMSecsSinceEpoch();
    saveSourceRegistry();status_=QStringLiteral("已打开目录 · %1").arg(library_sources_[index].name);
    emit libraryChanged();emit frameChanged();emit geometryChanged();emit stateChanged();return true;
}
bool PreviewController::createLibraryCatalog(const QUrl& path) {
    if(!ready_||busy_||!path.isLocalFile())return false;
    QString folder=QFileInfo(path.toLocalFile()).absoluteFilePath();
    if(!folder.endsWith(".spkcatalog",Qt::CaseInsensitive))folder+=".spkcatalog";
    if(QFileInfo::exists(QDir(folder).filePath("Library.json"))||!QDir().mkpath(folder)) {
        status_=QStringLiteral("无法新建目录：目标已存在或不可写");emit stateChanged();return false;
    }
    saveActiveSettings();flushEdits();
    catalog_file_=QFileInfo(QDir(folder).filePath("Library.json")).absoluteFilePath();
    library_.clear();collections_.clear();export_recipes_.clear();collection_filter_.clear();
    active_index_=-1;frame_.reset();image_={};full_image_={};geometry_={};
    if(!saveCatalog())return false;
    library_sources_.push_back({sourceName(catalog_file_),catalog_file_,QDateTime::currentMSecsSinceEpoch()});
    saveSourceRegistry();status_=QStringLiteral("已新建目录 · %1").arg(library_sources_.back().name);
    emit libraryChanged();emit frameChanged();emit geometryChanged();emit stateChanged();return true;
}
bool PreviewController::openLibraryCatalog(const QUrl& folder) {
    if(!ready_||busy_||!folder.isLocalFile())return false;
    QFileInfo target(folder.toLocalFile());
    QString catalog=target.isFile()&&target.fileName().compare("Library.json",Qt::CaseInsensitive)==0
        ?target.absoluteFilePath():target.absoluteFilePath()+"/Library.json";
    QFile file(catalog);
    if(!file.open(QIODevice::ReadOnly)) {
        status_=QStringLiteral("所选文件夹不是 SpektraLab 目录");emit stateChanged();return false;
    }
    const auto root=QJsonDocument::fromJson(file.readAll()).object();
    if(root.value("version").toInt()<1||root.value("version").toInt()>3) {
        status_=QStringLiteral("目录格式不受支持");emit stateChanged();return false;
    }
    catalog=QFileInfo(catalog).absoluteFilePath();
    auto existing=std::find_if(library_sources_.begin(),library_sources_.end(),
        [&](const auto& source){return source.path==catalog;});
    if(existing==library_sources_.end()) {
        library_sources_.push_back({sourceName(catalog),catalog,QDateTime::currentMSecsSinceEpoch()});
        existing=std::prev(library_sources_.end());
    }
    return switchLibrarySource(int(existing-library_sources_.begin()));
}
bool PreviewController::addLinkedFolder(const QUrl& folder) {
    if(!ready_||busy_||!folder.isLocalFile())return false;
    const QFileInfo target(folder.toLocalFile());
    if(!target.isDir()) {
        status_=QStringLiteral("所选位置不是文件夹");emit stateChanged();return false;
    }
    const auto root=target.canonicalFilePath();
    for(int i=0;i<int(library_sources_.size());++i)
        if(library_sources_[i].kind==QStringLiteral("linked")&&
           QFileInfo(library_sources_[i].root).canonicalFilePath().compare(root,Qt::CaseInsensitive)==0)
            return switchLibrarySource(i);
    const auto key=QString::fromLatin1(QCryptographicHash::hash(
        root.toUtf8(),QCryptographicHash::Sha256).toHex().left(20));
    const auto linkedFolder=QFileInfo(sources_file_).dir().filePath("linked");
    if(!QDir().mkpath(linkedFolder))return false;
    saveActiveSettings();flushEdits();
    catalog_file_=QFileInfo(QDir(linkedFolder).filePath(key+".json")).absoluteFilePath();
    library_.clear();collections_.clear();export_recipes_.clear();collection_filter_.clear();
    active_index_=-1;frame_.reset();image_={};full_image_={};geometry_={};
    loadCatalog();
    const QString name=target.fileName().isEmpty()?root:target.fileName();
    int source=-1;
    for(int i=0;i<int(library_sources_.size());++i)
        if(library_sources_[i].path==catalog_file_) {source=i;break;}
    if(source<0) {
        library_sources_.push_back({name+QStringLiteral(" · 引用"),catalog_file_,
            QDateTime::currentMSecsSinceEpoch(),QStringLiteral("linked"),root});
        source=int(library_sources_.size())-1;
    }
    const QStringList suffixes{"arw","nef","nrw","dng","cr2","cr3","raf","rw2","orf","pef","srw"};
    int first=-1;
    for(const auto& entry:QDir(root).entryInfoList(QDir::Files|QDir::Readable,QDir::Name))
        if(suffixes.contains(entry.suffix().toLower())) {
            const int index=addFile(QUrl::fromLocalFile(entry.canonicalFilePath()));
            if(first<0)first=index;
        }
    saveCatalog();saveSourceRegistry();
    status_=first>=0?QStringLiteral("已链接文件夹 · %1").arg(name):
                     QStringLiteral("文件夹中没有可识别的 RAW");
    emit libraryChanged();emit frameChanged();emit geometryChanged();emit stateChanged();
    if(first>=0)openItem(first);
    return first>=0;
}
QVariantList PreviewController::collections() const {
    QVariantList result;
    for(const auto& collection:collections_)
        result.push_back(QVariantMap{{"name",collection.name},{"count",collection.paths.size()},
            {"active",collection.name==collection_filter_}});
    return result;
}
QVariantList PreviewController::exportRecipes() const {
    QVariantList result;
    for(const auto& recipe:export_recipes_)
        result.push_back(QVariantMap{{"name",recipe.name},{"format",recipe.format},
            {"quality",recipe.quality},{"maxLongEdge",recipe.max_long_edge},
            {"outputSpace",recipe.output_space},{"copyMetadata",recipe.copy_metadata},
            {"namingOriginal",recipe.naming_original},{"namingFilm",recipe.naming_film},
            {"namingPaper",recipe.naming_paper},{"namingDate",recipe.naming_date},
            {"namingOrder",recipe.naming_order},{"namingSeparator",recipe.naming_separator}});
    return result;
}
QVariantMap PreviewController::exportRecipe(int index) const {
    if(index<0||index>=int(export_recipes_.size()))return {};
    const auto& recipe=export_recipes_[index];
    return QVariantMap{{"name",recipe.name},{"format",recipe.format},
        {"quality",recipe.quality},{"maxLongEdge",recipe.max_long_edge},
        {"outputSpace",recipe.output_space},{"copyMetadata",recipe.copy_metadata},
        {"namingOriginal",recipe.naming_original},{"namingFilm",recipe.naming_film},
        {"namingPaper",recipe.naming_paper},{"namingDate",recipe.naming_date},
        {"namingOrder",recipe.naming_order},{"namingSeparator",recipe.naming_separator}};
}
bool PreviewController::saveExportRecipe(const QString& name,int format,int quality,
                                         int maxLongEdge,int outputSpace,bool copyMetadata) {
    const auto normalized=name.trimmed();
    if(normalized.isEmpty()||format<0||format>4||quality<1||quality>100||
       maxLongEdge<0||maxLongEdge>100000||outputSpace<0||outputSpace>3)return false;
    if(format==4&&outputSpace!=0)return false;
    const ExportRecipe recipe{normalized,format,quality,maxLongEdge,outputSpace,copyMetadata,
        export_naming_original_,export_naming_film_,export_naming_paper_,export_naming_date_,
        export_naming_order_,export_naming_separator_};
    const auto existing=std::find_if(export_recipes_.begin(),export_recipes_.end(),
        [&](const auto& value){return value.name.compare(normalized,Qt::CaseInsensitive)==0;});
    if(existing==export_recipes_.end())export_recipes_.push_back(recipe);else *existing=recipe;
    saveCatalog();emit libraryChanged();return true;
}
void PreviewController::deleteExportRecipe(int index) {
    if(index<0||index>=int(export_recipes_.size()))return;
    export_recipes_.erase(export_recipes_.begin()+index);saveCatalog();emit libraryChanged();
}
bool PreviewController::setExportNaming(bool originalName,bool film,bool paper,bool date,
                                         const QString& order,const QString& separator) {
    if(!(originalName||film||paper||date))return false;
    if(separator!=QStringLiteral("_")&&separator!=QStringLiteral("-")&&separator!=QStringLiteral(" "))
        return false;
    auto parts=order.split(',',Qt::SkipEmptyParts);
    for(auto& part:parts)part=part.trimmed();
    const QStringList required{"original","film","print","date"};
    if(parts.size()!=required.size()||
       std::any_of(required.begin(),required.end(),[&](const auto& part){return parts.count(part)!=1;}))
        return false;
    export_naming_original_=originalName;export_naming_film_=film;
    export_naming_paper_=paper;export_naming_date_=date;
    export_naming_order_=parts.join(',');
    export_naming_separator_=separator;
    emit libraryChanged();return true;
}
int PreviewController::selectedCount() const {
    int count=0;for(const int index:visibleIndices(false))count+=library_[index].selected;return count;
}
void PreviewController::setRating(int index,int rating) {
    if(index<0||index>=int(library_.size())||rating<0||rating>5)return;
    library_[index].rating=rating;saveCatalog();emit libraryChanged();
}
void PreviewController::setColorLabel(int index,int color) {
    if(index<0||index>=int(library_.size())||color<0||color>7)return;
    library_[index].color_label=color;saveCatalog();emit libraryChanged();
}
void PreviewController::createCollection(const QString& name) {
    const auto normalized=name.trimmed();
    if(normalized.isEmpty()||std::any_of(collections_.begin(),collections_.end(),
        [&](const auto& collection){return collection.name.compare(normalized,Qt::CaseInsensitive)==0;}))return;
    Collection collection;collection.name=normalized;
    const int current=active_index_;
    const bool useSelection=selectedCount()>0;
    for(int i=0;i<int(library_.size());++i)if(((useSelection&&library_[i].selected)||(!useSelection&&i==current))&&!library_[i].trashed)
        collection.paths.insert(QFileInfo(library_[i].url.toLocalFile()).canonicalFilePath().toLower());
    collections_.push_back(std::move(collection));
    collection_filter_=normalized;saveCatalog();emit libraryChanged();
}
void PreviewController::deleteCollection(const QString& name) {
    const auto count=std::erase_if(collections_,[&](const auto& collection){return collection.name==name;});
    if(!count)return;
    if(collection_filter_==name)collection_filter_.clear();
    saveCatalog();emit libraryChanged();
}
void PreviewController::setCollectionFilter(const QString& name) {
    if(name!=QStringLiteral("__trash__")&&!name.isEmpty()&&std::none_of(collections_.begin(),collections_.end(),
        [&](const auto& collection){return collection.name==name;}))return;
    if(collection_filter_==name)return;
    collection_filter_=name;
    for(auto& item:library_)item.selected=false;
    emit libraryChanged();
}
void PreviewController::setLibrarySearch(const QString& text) {
    if(library_search_==text)return;
    library_search_=text;
    for(auto& item:library_)item.selected=false;
    emit libraryChanged();
}
void PreviewController::setLibrarySort(int mode) {
    if(mode<0||mode>3||library_sort_==mode)return;
    library_sort_=mode;emit libraryChanged();
}
void PreviewController::moveToTrash(int index) {
    if(busy_||dialog_open_||index<0||index>=int(library_.size())||library_[index].trashed)return;
    saveActiveSettings();
    library_[index].trashed=true;library_[index].selected=false;
    saveCatalog();
    if(active_index_==index) {
        active_index_=-1;frame_.reset();image_={};full_image_={};geometry_={};
        const auto visible=visibleIndices();
        if(!visible.empty())openItem(visible.front());
        else {status_=QStringLiteral("目录中已没有照片");emit stateChanged();}
    }
    status_=QStringLiteral("已移到回收站，源文件保持不变");
    emit libraryChanged();emit frameChanged();emit geometryChanged();emit stateChanged();
}
void PreviewController::restoreFromTrash(int index) {
    if(busy_||dialog_open_||index<0||index>=int(library_.size())||!library_[index].trashed)return;
    library_[index].trashed=false;saveCatalog();
    status_=QStringLiteral("已从回收站恢复");
    emit libraryChanged();emit stateChanged();
}
void PreviewController::saveActiveSettings(bool recordHistory) {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    auto& item=library_[active_index_];const auto desired=settings();
    const auto mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    // A saved pending edit has no rendered thumbnail yet. Do not let the
    // strip present an older look as if it represented the new settings.
    const bool changed=!sameSettings(item.settings,desired)||item.mode!=mode||item.geometry!=geometry_;
    if(changed){
        if(recordHistory)recordEdit(item,itemState(item));
        item.thumbnail={};item.pending_save=true;
    }
    item.settings=desired;item.mode=mode;
    item.geometry=geometry_;
    if(changed){scheduleSave();emit libraryChanged();emit historyChanged();}
}
void PreviewController::updateThumbnail() {
    if(active_index_<0||active_index_>=int(library_.size()))return;
    auto& item=library_[active_index_];
    item.thumbnail=dirty()?QImage{}:image_.scaled(180,120,Qt::KeepAspectRatio,Qt::SmoothTransformation);
    item.error.clear();emit libraryChanged();
}
void PreviewController::loadCatalog() {
    QFile file(catalog_file_);
    if(!file.exists()||!file.open(QIODevice::ReadOnly))return;
    const auto document=QJsonDocument::fromJson(file.readAll());
    const auto root=document.object();
    if(!document.isObject()||root.value("version").toInt()<1||root.value("version").toInt()>3)return;
    for(const auto value:root.value("items").toArray()) {
        const auto entry=value.toObject();
        const QFileInfo info(entry.value("path").toString());
        const auto record_key=entry.value("recordKey").toString();
        if(entry.value("path").toString().isEmpty()||
           std::any_of(library_.begin(),library_.end(),[&](const auto& item){
               // Variants share a source path; their record key is what tells
               // them apart. Older catalogues without one fall back to path.
               if(!record_key.isEmpty())
                   return !item.record_key.isEmpty()&&item.record_key==record_key;
               return QFileInfo(item.url.toLocalFile()).absoluteFilePath().compare(info.absoluteFilePath(),Qt::CaseInsensitive)==0&&
                   item.pair_url.toLocalFile().compare(entry.value("path2").toString(),Qt::CaseInsensitive)==0;}))continue;
        LibraryItem item;item.url=QUrl::fromLocalFile(info.absoluteFilePath());
        const QFileInfo second(entry.value("path2").toString());
        if(!second.filePath().isEmpty()) {
            item.pair_url=QUrl::fromLocalFile(second.absoluteFilePath());
            item.record_key=QStringLiteral("pair:")+info.absoluteFilePath().toLower()+QChar('|')+second.absoluteFilePath().toLower();
            item.pair_name=entry.value("name").toString();
        } else item.record_key=entry.value("recordKey").toString();
        item.settings=defaultSettings();
        item.rating=std::clamp(entry.value("rating").toInt(),0,5);
        item.color_label=std::clamp(entry.value("colorLabel").toInt(),0,7);
        item.trashed=entry.value("trashed").toBool();
        item.selected=false;
        if(info.isFile()) {
            const auto stored=edit_store_.load(item.url,catalog_,item.record_key);
            item.save_blocked=stored.blocked;item.save_warning=stored.warning;
            if(stored.state){item.settings=stored.state->settings;item.mode=stored.state->mode;
                item.geometry=stored.state->geometry;item.has_stored=true;}
        } else item.error=QStringLiteral("源文件当前不可用");
        library_.push_back(std::move(item));
    }
    for(const auto value:root.value("exportRecipes").toArray()) {
        const auto entry=value.toObject();
        const auto name=entry.value("name").toString().trimmed();
        if(name.isEmpty())continue;
        export_recipes_.push_back({name,std::clamp(entry.value("format").toInt(),0,4),
            std::clamp(entry.value("quality").toInt(95),1,100),
            std::clamp(entry.value("maxLongEdge").toInt(),0,100000),
            std::clamp(entry.value("outputSpace").toInt(),0,3),
            entry.value("copyMetadata").toBool(),
            entry.value("namingOriginal").toBool(true),entry.value("namingFilm").toBool(false),
            entry.value("namingPaper").toBool(false),entry.value("namingDate").toBool(false),
            entry.value("namingOrder").toString(QStringLiteral("original,film,print,date")),
            entry.value("namingSeparator").toString(QStringLiteral("_"))});
    }
    for(const auto value:root.value("collections").toArray()) {
        const auto entry=value.toObject();Collection collection;
        collection.name=entry.value("name").toString().trimmed();
        if(collection.name.isEmpty())continue;
        for(const auto path:entry.value("paths").toArray())
            collection.paths.insert(QFileInfo(path.toString()).absoluteFilePath().toLower());
        collections_.push_back(std::move(collection));
    }
    if(!collections_.empty())collection_filter_.clear();
    emit libraryChanged();
}
bool PreviewController::saveCatalog() {
    QJsonArray items;
    for(const auto& item:library_)
        items.append(QJsonObject{{"path",QFileInfo(item.url.toLocalFile()).absoluteFilePath()},
            {"path2",item.pair_url.isLocalFile()?QFileInfo(item.pair_url.toLocalFile()).absoluteFilePath():QString()},
            {"name",item.pair_name},{"recordKey",item.record_key},
            {"rating",item.rating},{"colorLabel",item.color_label},{"trashed",item.trashed}});
    QJsonArray collections;
    for(const auto& collection:collections_) {
        QStringList paths(collection.paths.begin(),collection.paths.end());paths.sort();
        collections.append(QJsonObject{{"name",collection.name},{"paths",QJsonArray::fromStringList(paths)}});
    }
    QJsonArray recipes;
    for(const auto& recipe:export_recipes_)
        recipes.append(QJsonObject{{"name",recipe.name},{"format",recipe.format},
            {"quality",recipe.quality},{"maxLongEdge",recipe.max_long_edge},
            {"outputSpace",recipe.output_space},{"copyMetadata",recipe.copy_metadata},
            {"namingOriginal",recipe.naming_original},{"namingFilm",recipe.naming_film},
            {"namingPaper",recipe.naming_paper},{"namingDate",recipe.naming_date},
            {"namingOrder",recipe.naming_order},{"namingSeparator",recipe.naming_separator}});
    const QJsonObject root{{"version",3},{"items",items},{"collections",collections},
        {"exportRecipes",recipes}};
    QDir().mkpath(QFileInfo(catalog_file_).absolutePath());
    QSaveFile file(catalog_file_);
    if(!file.open(QIODevice::WriteOnly))return false;
    if(file.write(QJsonDocument(root).toJson(QJsonDocument::Indented))<0||!file.commit())return false;
    return true;
}
int PreviewController::addFile(const QUrl& url) {
    if(!url.isLocalFile())return -1;
    const QFileInfo info(url.toLocalFile());
    if(!info.isFile())return -1;
    const auto local=QUrl::fromLocalFile(info.canonicalFilePath());
    for(int i=0;i<int(library_.size());++i)
        if(library_[i].pair_url.isEmpty()&&
           library_[i].url.toLocalFile().compare(local.toLocalFile(),Qt::CaseInsensitive)==0)return i;
    LibraryItem item;item.url=local;item.settings=settings();
    item.mode=decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16;
    const auto stored=edit_store_.load(local,catalog_,item.record_key);
    item.save_blocked=stored.blocked;item.save_warning=stored.warning;
    if(stored.state){item.settings=stored.state->settings;item.mode=stored.state->mode;item.geometry=stored.state->geometry;item.has_stored=true;}
    library_.push_back(std::move(item));saveCatalog();emit libraryChanged();return int(library_.size())-1;
}
int PreviewController::variantNumber(const LibraryItem& item) const {
    if(!item.pair_url.isEmpty())return 1;
    const auto source=QFileInfo(item.url.toLocalFile()).absoluteFilePath().toCaseFolded();
    int number=0;
    for(const auto& candidate:library_) {
        if(candidate.pair_url.isEmpty()&&
           QFileInfo(candidate.url.toLocalFile()).absoluteFilePath().toCaseFolded()==source)
            ++number;
        if(&candidate==&item)return number;
    }
    return 1;
}
int PreviewController::variantCount(const LibraryItem& item) const {
    if(!item.pair_url.isEmpty())return 1;
    const auto source=QFileInfo(item.url.toLocalFile()).absoluteFilePath().toCaseFolded();
    return int(std::count_if(library_.begin(),library_.end(),[&](const auto& candidate){
        return candidate.pair_url.isEmpty()&&
            QFileInfo(candidate.url.toLocalFile()).absoluteFilePath().toCaseFolded()==source;
    }));
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
    for(const int index:visibleIndices(false))library_[index].selected=selected;
    emit libraryChanged();
}
void PreviewController::createPairFromSelection() {
    if(!ready_||busy_||dialog_open_||selectedCount()!=2)return;
    saveActiveSettings();
    std::vector<int> selected;
    for(int i=0;i<int(library_.size());++i)
        if(library_[i].selected&&library_[i].pair_url.isEmpty())selected.push_back(i);
    if(selected.size()!=2)return;
    const auto first=QFileInfo(library_[selected[0]].url.toLocalFile()).canonicalFilePath();
    const auto second=QFileInfo(library_[selected[1]].url.toLocalFile()).canonicalFilePath();
    const auto record_key=QStringLiteral("pair:")+first.toLower()+QChar('|')+second.toLower();
    for(int i=0;i<int(library_.size());++i)if(library_[i].record_key==record_key) {
        for(auto& item:library_)item.selected=false;
        library_[i].selected=true;emit libraryChanged();openItem(i);return;
    }
    LibraryItem pair;
    pair.url=QUrl::fromLocalFile(first);
    pair.pair_url=QUrl::fromLocalFile(second);
    pair.record_key=record_key;
    pair.pair_name=QFileInfo(first).fileName()+QStringLiteral(" + ")+QFileInfo(second).fileName();
    pair.settings=defaultSettings();
    pair.mode=desktop::DecodeMode::compatible16;
    pair.settings.advanced["overscan_pair"]=true;
    pair.settings.advanced["overscan_format"]=std::string("135_half");
    for(auto& item:library_)item.selected=false;
    pair.selected=true;
    library_.push_back(std::move(pair));
    const int index=int(library_.size())-1;
    saveCatalog();emit libraryChanged();openItem(index);
}
void PreviewController::createVariant(int index,bool clone) {
    if(!ready_||busy_||dialog_open_||index<0||index>=int(library_.size())||
       !library_[index].pair_url.isEmpty())return;
    saveActiveSettings();
    const auto base=library_[index];
    LibraryItem variant=base;
    variant.record_key=QStringLiteral("variant:")+
        QFileInfo(base.url.toLocalFile()).absoluteFilePath().toLower()+QChar(':')+
        QUuid::createUuid().toString(QUuid::WithoutBraces);
    if(!clone) {
        variant.settings=defaultSettings();
        variant.mode=desktop::DecodeMode::compatible16;
        variant.geometry={};
    }
    variant.undo.clear();variant.redo.clear();variant.selected=false;
    variant.pending_save=false;variant.has_stored=false;variant.save_blocked=false;variant.save_warning.clear();
    // A new variant sits beside the entry it came from, not after a run of
    // variants the user may have scrolled away from.
    const int insert=index+1;
    library_.insert(library_.begin()+insert,std::move(variant));
    if(active_index_>=insert)++active_index_;
    for(auto& item:library_)item.selected=false;
    library_[insert].selected=true;
    saveCatalog();emit libraryChanged();openItem(insert);
}
void PreviewController::deleteVariant(int index) {
    if(!ready_||busy_||dialog_open_||index<0||index>=int(library_.size())||
       !library_[index].pair_url.isEmpty()||variantCount(library_[index])<2)return;
    saveActiveSettings();
    const auto removed=library_[index];
    try {
        edit_store_.remove(removed.url,removed.record_key);
    } catch(const std::exception& e) {
        status_=text(e.what());emit stateChanged();return;
    }
    library_.erase(library_.begin()+index);
    if(active_index_==index) {
        const int next=std::min(index,int(library_.size())-1);
        active_index_=-1;frame_.reset();image_={};full_image_={};geometry_={};
        saveCatalog();emit libraryChanged();emit frameChanged();emit geometryChanged();
        if(next>=0)openItem(next);
        else {status_=QStringLiteral("目录中已没有照片");emit stateChanged();}
        return;
    }
    if(active_index_>index)--active_index_;
    saveCatalog();emit libraryChanged();status_=QStringLiteral("已删除变体，原文件保持不变");emit stateChanged();
}
void PreviewController::syncSelectedSettings(bool includeCrop) {
    if(!frame_||busy_||dialog_open_)return;
    saveActiveSettings();int count=0;
    for(int i=0;i<int(library_.size());++i)if(i!=active_index_&&library_[i].selected){
        auto& item=library_[i];auto next=currentState();
        if(!includeCrop)next.geometry=item.geometry;
        if(sameState(itemState(item),next))continue;
        // Each recipient owns its own undo history, just like its settings.
        item.undo.push_back(itemState(item));if(item.undo.size()>64)item.undo.erase(item.undo.begin());item.redo.clear();
        item.settings=next.settings;item.mode=next.mode;item.geometry=next.geometry;item.pending_save=true;
        item.thumbnail={};item.error.clear();++count;
    }
    status_=QStringLiteral("已将当前参数同步至 %1 张照片%2").arg(count)
        .arg(includeCrop?QStringLiteral("（含裁切）"):QStringLiteral("（各自保留裁切）"));
    scheduleSave();emit libraryChanged();emit historyChanged();emit stateChanged();
}
void PreviewController::setCropRect(const QRectF& crop) {
    auto next=geometry_;next.crop=crop;setGeometry(next,"cropRect");
}
void PreviewController::setGeometry(const output::Geometry& geometry,const QString& editKey) {
    if(!frame_||busy_||dialog_open_||geometry==geometry_)return;
    try {
        auto next=visibleImage(frame_,full_image_,geometry);
        if(gesture_index_>=0&&gesture_key_!=editKey)endEditGesture();
        image_=std::move(next);geometry_=geometry;saveActiveSettings(true);updateThumbnail();
        failed_=false;emit geometryChanged();emit frameChanged();emit stateChanged();
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
    return {item.settings,item.mode,item.geometry};
}
editing::State PreviewController::currentState() const {
    return {settings(),decode_mode_?desktop::DecodeMode::headroom:desktop::DecodeMode::compatible16,geometry_};
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
    endEditGesture();gesture_index_=active_index_;gesture_key_=key;gesture_recorded_=false;gesture_redo_=library_[active_index_].redo;
    if(key=="straightenDegrees")auto_apply_.stop();
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
        to.push_back(currentState());if(to.size()>64)to.erase(to.begin());from.pop_back();
        geometry_=target.geometry;image_=std::move(next);
        loadSettings(target.settings,target.mode);saveActiveSettings();
        ++settings_revision_;auto_apply_.stop();schedulePreview();updateThumbnail();
        failed_=false;status_=redo?QStringLiteral("已重做当前照片调整"):QStringLiteral("已撤销当前照片调整");
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
        try {edit_store_.save(item.url,itemState(item),item.record_key);item.pending_save=false;item.has_stored=true;item.save_warning.clear();}
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
    if(!persistenceWarning().isEmpty())return QStringLiteral("部分设置未保存，请查看下方提示");
    for(const auto& item:library_)if(item.pending_save)return QStringLiteral("正在自动保存设置…");
    if(active_index_>=0&&library_[active_index_].has_stored)return QStringLiteral("当前照片设置已自动保存");
    return QStringLiteral("调整将自动保存，重新打开照片时恢复");
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
    exportBatchWithRecipe(folder,format,quality,maxLongEdge,0,false);
}
void PreviewController::exportBatchWithRecipe(const QUrl& folder,int format,int quality,int maxLongEdge,
                                               int outputSpace,bool copyMetadata) {
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
    submit([this,items=std::move(items),held,resources,destination,gen,cancel,format,quality,maxLongEdge,outputSpace,copyMetadata](auto& host){
        Reply r;r.generation=gen;r.operation="batch-export";
        int done=0,skipped=0,errors=0,processed=0;QStringList details;
        try {
            const auto options=exportOptions(format,quality,maxLongEdge,outputSpace,copyMetadata);
            if(!std::filesystem::is_directory(destination))throw std::runtime_error("Export destination is not a folder");
            const QString extension=format==0?".tif":format==3?".jpg":format==4?".heic":".png";
            QSet<QString> names;
            for(const auto& item:items) {
                if(cancel->load())break;
                const auto source=path(item.url),second=path(item.pair_url);
                QString stem=QFileInfo(item.url.toLocalFile()).completeBaseName();
                const int variant=variantNumber(item);
                if(variant>1)stem+=QStringLiteral("-")+QString::number(variant);
                QString name=stem+extension;int suffix=2;
                while(names.contains(name.toCaseFolded()))name=stem+"-"+QString::number(suffix++)+extension;
                names.insert(name.toCaseFolded());
                const auto target=destination/std::filesystem::path(name.toStdWString());
                try {
                    if(std::filesystem::exists(target))++skipped;
                    else {
                        const bool pair=!item.pair_url.isEmpty();
                        const bool useShown=held&&held->source==source&&held->pair_sources.size()==(pair?2u:1u)&&
                            held->decode_mode==item.mode&&sameSettings(held->settings,item.settings);
                        const auto developed=useShown?held:
                            pair?host.open_raw_pair(source,second,item.mode,item.settings):
                            host.open_raw(source,item.mode,item.settings);
                        output::exportFrame(developed,target,item.geometry,options,resources);++done;
                    }
                }catch(const std::exception& e){++errors;details.append(name+": "+text(e.what()));}
                ++processed;
                QMetaObject::invokeMethod(this,[this,gen,processed]{if(generation_==gen){batch_progress_=processed;emit stateChanged();}},Qt::QueuedConnection);
            }
            r.message=QStringLiteral("%1：导出 %2 张，跳过已有 %3 张，失败 %4 张")
                .arg(cancel->load()?QStringLiteral("批量导出已取消"):QStringLiteral("批量导出完成")).arg(done).arg(skipped).arg(errors);
            if(errors)r.error=r.message+"\n"+details.join("\n");
        }catch(const std::exception& e){r.error=text(e.what());}
        return r;
    },QStringLiteral("正在批量导出…"),"batch-export");
}
