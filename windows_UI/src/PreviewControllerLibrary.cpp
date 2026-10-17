// PreviewController's library and settings clipboard: the macOS filmstrip's
// behaviours (Filmstrip.swift, Session.swift's library section) and the
// Settings Clipboard (SettingsClipboard.swift, ClipboardSection.swift), plus
// setParameters, several settings rows as one edit. Kept apart from
// PreviewController.cpp so the editor lanes touch different files; the
// members are declared in the header, and PreviewController.cpp calls in from
// the constructor (setupLibrary), openFiles (the folder order, the previews),
// libraryItems (the strip picture), updateThumbnail (the whole print), Sync
// (pasteOffline) and changed() (the batch edit's one gesture).
#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include "PostDevSurfaces.hpp"
#include "image_io.hpp"
#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QSettings>
#include <QThread>
#include <algorithm>
#include <cmath>

namespace {
namespace desktop=spk::desktop;
namespace output=desktop::output;
namespace editing=desktop::editing;
namespace clipboard=desktop::clipboard;
namespace library=desktop::library;
namespace postdev=desktop::postdev;

std::filesystem::path path(const QUrl& u) { return std::filesystem::path(u.toLocalFile().toStdWString()); }
int indexOf(const std::vector<desktop::Stock>& stocks,std::string_view id) {
    for(std::size_t i=0;i<stocks.size();++i)if(stocks[i].id==id)return int(i);
    return -1;
}
// PreviewController.cpp's comparisons: print exposure is stored as a power
// of two, so it is compared within rounding.
bool sameSettings(desktop::RenderSettings a,desktop::RenderSettings b) {
    const bool exposure=std::abs(a.print_exposure-b.print_exposure)<1e-12;
    a.print_exposure=b.print_exposure;
    return exposure&&a==b;
}
bool sameState(const editing::State& a,const editing::State& b) {
    return sameSettings(a.settings,b.settings)&&a.mode==b.mode&&a.geometry==b.geometry&&a.heldGeometry==b.heldGeometry&&
        a.postDev==b.postDev&&a.pair==b.pair;
}
// setParameter's strict conversion: a number row takes a number, a bool row
// a bool, a text row a string.
std::optional<desktop::SettingValue> strictValue(const desktop::SettingField& field,const QVariant& value) {
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
constexpr const char* kGroupsKey="clipboard/groups";
}  // namespace

void PreviewController::setupLibrary() {
    // Connected before any QML binding exists, so the strip's cells see the
    // new revision when they read their items again.
    connect(this,&PreviewController::libraryChanged,this,[this]{++library_revision_;});
    order_=library::FrameOrder(QDir(edit_directory_).filePath(QStringLiteral("Order")));
    clipboard_groups_=storedClipboardGroups();
    // A quarter of the cores, two to six readers: a RAW's preview is a small
    // embedded JPEG (image_io thumbnail picks it), a flat file a read, and
    // a folder of hundreds should fill the strip in seconds; the engine's
    // worker and LibRaw's demosaic keep the rest of the machine.
    preview_pool_=std::make_unique<QThreadPool>();
    preview_pool_->setMaxThreadCount(std::clamp(QThread::idealThreadCount()/4,2,6));
    // Previews land one by one; the strip is rebuilt at most every 60 ms.
    preview_flush_.setSingleShot(true);preview_flush_.setInterval(60);
    connect(&preview_flush_,&QTimer::timeout,this,&PreviewController::libraryChanged);
    // What the clipboard section reads follows the selection, the photograph
    // and whether an export runs.
    for(auto signal:{&PreviewController::libraryChanged,&PreviewController::frameChanged,&PreviewController::stateChanged})
        connect(this,signal,this,&PreviewController::clipboardChanged);
}

void PreviewController::dropImages(LibraryItem& item) {
    item.thumbnail={};item.preview={};item.whole={};item.strip={};item.strip_source=0;
}

// --- the strip's pictures ------------------------------------------------------

void PreviewController::requestPreviews() {
    for(auto& item:library_) {
        if(item.pair||item.preview_requested)continue;
        item.preview_requested=true;
        ++previews_running_;
        const QUrl url=item.url;const auto file=path(url);
        // ThumbnailCache.swift: the file's own picture, never the engine's,
        // off the GUI thread. A RAW's embedded preview (else a half-size
        // decode), a flat file read and reduced -- sRGB either way.
        preview_pool_->start([this,url,file]{
            QImage image;
            try {
                spkhost::Rgba8 rgba;std::string source,error;
                const auto box=desktop::display::kThumbnailBox;
                if(spkhost::thumbnail(file,std::uint32_t(2*std::max(box.width(),box.height())),rgba,source,error)&&
                   rgba.width&&rgba.height) {
                    QImage bytes(rgba.rgba.data(),int(rgba.width),int(rgba.height),int(rgba.width)*4,QImage::Format_RGBA8888);
                    image=bytes.convertToFormat(QImage::Format_RGBX8888)
                               .scaled(box,Qt::KeepAspectRatio,Qt::SmoothTransformation);
                    image.setColorSpace(QColorSpace::SRgb);
                }
            } catch(const std::exception&) {image={};}
            QMetaObject::invokeMethod(this,[this,url,image]{takePreview(url,image);},Qt::QueuedConnection);
        });
    }
}

void PreviewController::takePreview(const QUrl& url,QImage preview) {
    previews_running_=std::max(0,previews_running_-1);
    for(auto& item:library_)if(item.url==url){item.preview=std::move(preview);break;}
    if(!preview_flush_.isActive())preview_flush_.start();
}

int PreviewController::previewsPending() const {return previews_running_;}

QImage PreviewController::wholeThumbnail() const {
    if(whole_thumb_.isNull()||!frame_)return whole_thumb_;
    // Graded like the strip's other picture (gradedThumbnail), on the whole
    // frame: each pixel at its own place in the uncropped print.
    const auto grade=postdev::gradeFor(canvasGrade(),whole_thumb_.colorSpace());
    if(!grade)return whole_thumb_;
    QImage graded=whole_thumb_;
    try {postdev::gradeImage(graded,*grade,postdev::shownSourceMap(frame_,output::Geometry{}));}
    catch(const std::exception&) {return whole_thumb_;}
    return graded;
}

QImage PreviewController::stripImage(int index) const {
    const auto& item=library_[std::size_t(index)];
    // The rendered print once there is one for these settings (`thumbnail`
    // and `whole` are made together), else the file's own preview; a pair's
    // piece has no file preview and no crop.
    QImage source;bool framed=false;
    if(!item.thumbnail.isNull()&&!item.whole.isNull()){source=item.whole;framed=item.whole_cut;}
    else if(!item.preview.isNull())source=item.preview;
    else if(!item.thumbnail.isNull()){source=item.thumbnail;framed=true;}
    else return {};
    // Session.thumbnailGeometry(for:): the live geometry for the open frame,
    // the saved one for every other.
    const output::Geometry geometry=framed||item.pair?output::Geometry{}:index==active_index_?geometry_:item.geometry;
    if(item.strip.isNull()||item.strip_source!=source.cacheKey()||item.strip_geometry!=geometry) {
        try {item.strip=library::cropMasked(source,geometry);}
        catch(const std::exception&) {item.strip=source;}
        item.strip_source=source.cacheKey();item.strip_geometry=geometry;
    }
    return item.strip;
}

// --- the library -----------------------------------------------------------------

void PreviewController::openFolder(const QUrl& folder) {
    if(!folder.isLocalFile()||!QFileInfo(folder.toLocalFile()).isDir())return;
    openFiles({folder});
}

void PreviewController::moveLibraryItem(int from,int to) {
    auto item=std::move(library_[std::size_t(from)]);
    library_.erase(library_.begin()+from);
    library_.insert(library_.begin()+to,std::move(item));
    const auto remap=[&](int& i) {
        if(i<0)return;
        if(i==from)i=to;
        else if(from<to&&i>from&&i<=to)--i;
        else if(from>to&&i>=to&&i<from)++i;
    };
    remap(active_index_);remap(gesture_index_);
}

void PreviewController::applyFolderOrder(int from) {
    if(from<0||from>=int(library_.size()))return;
    QStringList paths;
    for(std::size_t i=std::size_t(from);i<library_.size();++i)paths.push_back(library_[i].url.toLocalFile());
    const auto ordered=order_.applied(paths);
    if(ordered==paths)return;
    endEditGesture();
    for(int target=0;target<ordered.size();++target) {
        const int at=int(paths.indexOf(ordered[target]));
        if(at<0||at==target)continue;
        moveLibraryItem(from+at,from+target);
        paths.move(at,target);
    }
}

void PreviewController::clickPhoto(int index,bool command) {
    if(!ready_||batchExporting()||dialog_open_||index<0||index>=int(library_.size()))return;
    if(command) {
        // Session.togglePick: one photograph in or out, the canvas unmoved;
        // the open one cannot leave the set (a batch without the frame it
        // proves is a state with nothing to read off it).
        auto& item=library_[std::size_t(index)];
        if(!item.selected)item.selected=true;
        else if(index!=active_index_)item.selected=false;
        emit libraryChanged();
        return;
    }
    // A plain click picks exactly this photograph and opens it -- only when
    // it can open now (selectImage waits for nothing).
    if(index!=active_index_&&busy_)return;
    for(auto& item:library_)item.selected=false;
    library_[std::size_t(index)].selected=true;
    emit libraryChanged();
    if(index!=active_index_)selectImage(index);
}

void PreviewController::stepPhoto(int delta) {
    if(active_index_<0||library_.empty())return;
    const int next=std::clamp(active_index_+delta,0,int(library_.size())-1);
    if(next!=active_index_)clickPhoto(next,false);
}

bool PreviewController::moveItem(int from,int to) {
    // An open in flight names its item by index; a batch holds its own copy.
    if(!ready_||busy_||from<0||to<0||from>=int(library_.size())||to>=int(library_.size())||from==to)return false;
    endEditGesture();
    moveLibraryItem(from,to);
    emit libraryChanged();
    return true;
}

void PreviewController::itemOrderChanged() {
    // FrameOrder.save for each folder the strip holds: its frames in the
    // strip's order, with the pairs between them (a pair belongs to the
    // folder of the frames beside it).
    QHash<QString,QStringList> folders;
    QStringList keys;
    for(const auto& item:library_) {
        if(item.pair)continue;
        const QString folder=QFileInfo(item.url.toLocalFile()).absolutePath().toCaseFolded();
        if(!folders.contains(folder))keys.push_back(folder);
        folders[folder];
    }
    for(const auto& item:library_) {
        const QString file=item.url.toLocalFile();
        if(item.pair){for(const auto& k:keys)folders[k].push_back(file);continue;}
        folders[QFileInfo(file).absolutePath().toCaseFolded()].push_back(file);
    }
    for(const auto& k:keys)order_.save(folders[k]);
}

// --- the settings clipboard ------------------------------------------------------

QSet<clipboard::Group> PreviewController::storedClipboardGroups() const {
    // All seven by default: what a paste copied before the groups existed
    // (Session.storedClipboardGroups, :827-831).
    QSettings store(edit_directory_+"/preferences.ini",QSettings::IniFormat);
    if(!store.contains(kGroupsKey))return clipboard::allGroups();
    QSet<clipboard::Group> out;
    for(const auto& id:store.value(kGroupsKey).toStringList())
        if(const auto group=clipboard::groupNamed(id))out.insert(*group);
    return out;
}

QVariantList PreviewController::clipboardGroups() const {
    QVariantList out;
    for(const auto group:clipboard::offered())
        out.push_back(QVariantMap{{"id",clipboard::name(group)},{"ticked",clipboard_groups_.contains(group)}});
    return out;
}

void PreviewController::setClipboardGroup(const QString& id,bool ticked) {
    const auto group=clipboard::groupNamed(id);
    if(!group||clipboard_groups_.contains(*group)==ticked)return;
    if(ticked)clipboard_groups_.insert(*group);else clipboard_groups_.remove(*group);
    QStringList stored;
    for(const auto g:clipboard_groups_)stored.push_back(clipboard::name(g));
    stored.sort();
    QDir().mkpath(edit_directory_);
    QSettings store(edit_directory_+"/preferences.ini",QSettings::IniFormat);
    store.setValue(kGroupsKey,stored);
    emit clipboardChanged();
}

std::vector<int> PreviewController::syncTargets() const {
    std::vector<int> out;
    for(int i=0;i<int(library_.size());++i)if(i!=active_index_&&library_[std::size_t(i)].selected)out.push_back(i);
    return out;
}

std::vector<int> PreviewController::pasteTargets() const {
    // Every picked photograph, which includes the open one whenever it was
    // clicked (togglePick), or that one alone (Session.pasteTargets).
    std::vector<int> out;
    for(int i=0;i<int(library_.size());++i)if(library_[std::size_t(i)].selected)out.push_back(i);
    if(out.empty()&&active_index_>=0)out.push_back(active_index_);
    return out;
}

QVariantMap PreviewController::clipboardState() const {
    const bool open=bool(frame_)&&active_index_>=0;
    const bool locked=batchExporting();
    const int paste=int(pasteTargets().size()),sync=int(syncTargets().size());
    QStringList held;
    if(clip_)for(const auto& g:clipboard::groups())if(clip_->groups.contains(g.group))held.push_back(QLatin1String(g.id));
    // canCopySettings / canPasteSettings / canSyncSettings (:3736-3742),
    // and the editor's own wait: a paste is an edit of the open photograph.
    return {{"holds",clip_.has_value()},{"source",clip_?clip_->sourceName:QString()},
            {"groupCount",clip_?int(clip_->groups.size()):0},{"groups",held},
            {"canCopy",open&&!clipboard_groups_.isEmpty()},
            {"canPaste",clip_.has_value()&&open&&!locked&&settingsEditable()},
            {"canSync",open&&!locked&&!busy_&&!dialog_open_&&!clipboard_groups_.isEmpty()&&sync>0},
            {"pasteTargets",paste},{"syncTargets",sync},{"locked",locked}};
}

bool PreviewController::copySettings() {
    if(!frame_||active_index_<0||clipboard_groups_.isEmpty())return false;
    // From a pair, what the rails show: the film and the picked frame.
    clip_=clipboard::Clip{clipboard_groups_,settings(),fileName()};
    status_=uiText("status.copied",{QString::number(clipboard_groups_.size()),QString::number(clipboard::groups().size()),fileName()});
    emit clipboardChanged();emit stateChanged();
    return true;
}

bool PreviewController::pasteOffline(const clipboard::Clip& clip,int index,const output::Geometry* crop) {
    // Session.pasteOffline (:3846-3860): written to the photograph's record
    // now, developed with it when it is opened; its old print goes from the
    // strip. Each recipient owns its undo history, as its settings.
    auto& item=library_[std::size_t(index)];
    const auto before=itemState(item);
    auto next=before;
    next.settings=clip.applied(item.settings);
    if(crop&&!item.pair)next.geometry=*crop;
    if(sameState(before,next))return false;
    item.undo.push_back(before);
    if(item.undo.size()>64)item.undo.erase(item.undo.begin());
    item.redo.clear();
    item.settings=next.settings;item.geometry=next.geometry;
    item.pending_save=true;item.thumbnail={};item.whole={};item.error.clear();
    return true;
}

bool PreviewController::pasteLive(const clipboard::Clip& clip) {
    // Session.pasteLive (:3799-3825): one undo step, then each side effect
    // the individual setters would have had -- a new decode for a white
    // balance, a reprint otherwise, and the pasted placement's own Fit once
    // this frame's develop lands (resolvePendingPlacement).
    const auto current=settings();
    const auto next=clip.applied(current);
    if(sameSettings(next,current))return false;
    if(const int f=indexOf(catalog_.films,next.film_stock);f>=0)film_index_=f;
    if(const int p=indexOf(catalog_.papers,next.print_stock);p>=0)paper_index_=p;
    exposure_ev_=-std::log2(next.print_exposure);
    extra_settings_=next;
    changed(QStringLiteral("paste"));
    resolvePendingPlacement();
    return true;
}

int PreviewController::pasteSettings() {
    if(!clip_||!frame_||active_index_<0||batchExporting()||!settingsEditable())return 0;
    saveActiveSettings();
    const auto clip=*clip_;
    const auto targets=pasteTargets();
    int written=0;
    for(const int i:targets)if(i!=active_index_)written+=pasteOffline(clip,i);
    if(std::find(targets.begin(),targets.end(),active_index_)!=targets.end())written+=pasteLive(clip);
    status_=written?uiText("status.pasted",{QString::number(clip.groups.size()),QString::number(written)})
                   :uiText("status.pasteNothing");
    scheduleSave();emit libraryChanged();emit historyChanged();emit stateChanged();
    return written;
}

// --- several rows, one edit ------------------------------------------------------

void PreviewController::beginBatchEdit() {
    if(batch_edit_++>0)return;
    // One gesture of its own: recordEdit keeps the state before the first
    // row, and endEditGesture drops the step if the rows changed nothing.
    endEditGesture();
    if(active_index_>=0&&active_index_<int(library_.size())) {
        gesture_index_=active_index_;gesture_key_=QStringLiteral("__batch");gesture_recorded_=false;
        gesture_redo_=library_[std::size_t(active_index_)].redo;
    }
}

void PreviewController::endBatchEdit() {
    if(--batch_edit_>0)return;
    if(gesture_key_==QLatin1String("__batch"))endEditGesture();
}

bool PreviewController::setParameters(const QVariantMap& values) {
    std::vector<std::pair<std::string,desktop::SettingValue>> rows;
    QStringList keys=values.keys();
    // The film first: choosing it moves the paper (Session.selectFilmStock),
    // so a paper in the same edit lands after it.
    for(const char* first:{"print_stock","film_stock"})
        if(keys.removeOne(QLatin1String(first)))keys.prepend(QLatin1String(first));
    for(const auto& key:keys) {
        const auto* field=desktop::find_setting(key.toStdString());
        if(!field)return false;
        auto value=strictValue(*field,values.value(key));
        if(!value)return false;
        rows.emplace_back(field->key,std::move(*value));
    }
    return setSettingValues(rows);
}

bool PreviewController::setSettingValues(const std::vector<std::pair<std::string,desktop::SettingValue>>& values) {
    if(!settingsEditable()||values.empty())return false;
    // Type, range and choices of every row before any is applied.
    for(const auto& [key,value]:values) {
        const auto* field=desktop::find_setting(key);
        if(!field||!desktop::check_setting(*field,value,&catalog_).empty())return false;
    }
    beginBatchEdit();
    bool all=true;
    for(const auto& [key,value]:values)all=applyParameter(*desktop::find_setting(key),value)&&all;
    endBatchEdit();
    return all;
}
