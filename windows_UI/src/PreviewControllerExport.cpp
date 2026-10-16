// PreviewController's half of the export page: the recipe run and the proof.
// Kept apart from PreviewController.cpp so the export lane and the editor
// lanes touch different files; the members are declared in the header.
#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include "PostDevSurfaces.hpp"
#include "RecipeExport.hpp"
#include <QFileInfo>
#include <QJsonObject>
#include <QMetaObject>
#include <cmath>

namespace {
namespace desktop=spk::desktop;
namespace recipes=desktop::recipes;
namespace exporting=desktop::exporting;
QString text(const std::string& s) { return QString::fromUtf8(s.data(),qsizetype(s.size())); }
std::filesystem::path nativePath(const QUrl& u) { return std::filesystem::path(u.toLocalFile().toStdWString()); }
// The photograph's geometry as the host cuts a frame with it (Film Edge, Date
// Back on a cropped frame: preview_host.hpp EngineCut).
desktop::EngineCut engineCut(const desktop::output::Geometry& g) {
    return {g.crop.x(),g.crop.y(),g.crop.width(),g.crop.height(),g.quarterTurns,g.flipHorizontal,g.flipVertical,g.straightenDegrees};
}
bool sameRender(const desktop::RenderSettings& a,const desktop::RenderSettings& b) {
    auto x=a,y=b;
    const bool exposure=std::abs(x.print_exposure-y.print_exposure)<1e-12;
    x.print_exposure=y.print_exposure;
    return exposure&&x==y;
}
}

void PreviewController::exportWithRecipe(const QVariantMap& json) {
    if(!ready_||busy_)return;
    const auto recipe=recipes::Recipe::fromJson(QJsonObject::fromVariantMap(json));
    saveActiveSettings();
    std::vector<LibraryItem> items;
    for(const auto& item:library_)if(item.selected)items.push_back(item);
    if(items.empty()&&active_index_>=0)items.push_back(library_[active_index_]);
    if(items.empty())return;
    // Only one developed frame is held by the worker, however many photos.
    for(auto& item:items)item.thumbnail={};
    const auto held=frame_;const auto resources=resources_;
    const auto gen=++generation_;cancel_batch_=std::make_shared<std::atomic_bool>(false);
    const auto cancel=cancel_batch_;batch_progress_=0;batch_total_=int(items.size());
    const auto today=QDate::currentDate();
    submit([this,items=std::move(items),held,resources,gen,cancel,recipe,today](desktop::PreviewHost& host){
        Reply r;r.generation=gen;r.operation="batch-export";r.recipe=true;
        int done=0,skipped=0,errors=0,processed=0;
        QStringList written,problems,details;
        const bool di=recipe.format==recipes::Format::di;
        for(const auto& item:items) {
            if(cancel->load())break;
            const auto source=nativePath(item.url);
            const QString name=QFileInfo(item.url.toLocalFile()).fileName();
            try {
                // A frame cut for the engine (Film Edge, a date on a cropped
                // frame) is developed with the photograph's geometry, so the
                // shown frame serves only when it was cut with that geometry;
                // the file is that frame whole -- the strip -- with no geometry
                // over it (Session.printGeometry, Session+FilmEdge.swift:459).
                const auto cut=engineCut(item.geometry);
                const auto sameFraming=[&](const desktop::FramePtr& f) {
                    if(!f)return false;
                    desktop::PhotoInfo photo{f->metadata.shooting,f->decode_width,f->decode_height,cut};
                    const bool wanted=desktop::cuts_frame(item.settings,photo);
                    return wanted==f->cut&&(!wanted||f->geometry==cut);
                };
                const bool shown=held&&held->source==source&&held->decode_mode==item.mode&&
                                 sameRender(held->settings,item.settings)&&sameFraming(held);
                desktop::FramePtr frame;
                // A half-frame pair exports as one picture, the piece as the
                // canvas shows it (Exporter.swift; PreviewControllerPairs.cpp).
                if(item.pair) {
                    frame=developPair(host,item,held);
                    if(di)frame=host.render_digital_intermediate();
                } else if(di) {
                    // The DI comes from the session, so the session must be
                    // this photograph's, with its own settings and framing.
                    const auto current=host.current();
                    if(!current||current->source!=source||current->decode_mode!=item.mode||
                       !sameRender(current->settings,item.settings)||!sameFraming(current))
                        host.open_raw(source,item.mode,item.settings,cut);
                    frame=host.render_digital_intermediate();
                } else frame=shown?held:host.open_raw(source,item.mode,item.settings,cut);
                if(cancel->load())break;
                exporting::Job job;
                job.recipe=recipe;job.source=item.url.toLocalFile();job.resources=resources;
                job.geometry=frame->cut?desktop::output::Geometry{}:item.geometry;
                job.name.originalName=QFileInfo(job.source).completeBaseName();
                if(item.pair) {
                    // Its EXIF is its first frame's (PairComposer.decode sourceEXIF);
                    // its name the pair's own.
                    job.name.originalName=desktop::pairs::title(job.source);
                    const auto& first=item.pair->holes[0]?item.pair->holes[0]:item.pair->holes[1];
                    if(first)job.source=first->path;
                }
                job.name.filmStock=text(item.settings.film_stock);
                job.name.printStock=text(item.settings.print_stock);
                job.name.date=today;
                // Post-Dev on the uncropped frame before geometry (the Mac's
                // Exporter.filePixels); empty for an ungraded photograph, and
                // never applied to a DI (RecipeExport.cpp framed()).
                job.grade=desktop::postdev::exportGrade(item.postdev);
                const auto outcome=exporting::run(job,frame,host.engine());
                if(outcome.kind==exporting::Outcome::skipped) {
                    ++skipped;
                    problems.append(QFileInfo(outcome.files.value(0)).fileName()+QString::fromUtf8(" already exists — skipped."));
                } else {
                    ++done;written+=outcome.files;
                    if(!outcome.note.isEmpty()&&!problems.contains(outcome.note))problems.append(outcome.note);
                }
            } catch(const std::exception& e) {
                ++errors;
                const QString line=name+QStringLiteral(": ")+text(e.what());
                problems.append(line);details.append(line);
            }
            ++processed;
            QMetaObject::invokeMethod(this,[this,gen,processed]{if(generation_==gen){batch_progress_=processed;emit stateChanged();}},Qt::QueuedConnection);
        }
        const int total=int(items.size());
        if(cancel->load()&&processed<total)
            problems.append(QString::fromUtf8("Stopped — %1 of %2 not exported.").arg(total-processed).arg(total));
        r.files=written;
        QStringList images;
        for(const auto& f:written)if(!f.endsWith(QLatin1String(".cube"),Qt::CaseInsensitive))images.append(QFileInfo(f).fileName());
        QStringList parts{images.isEmpty()?QStringLiteral("Nothing was written."):QStringLiteral("Wrote ")+images.join(QStringLiteral(", "))};
        parts+=problems;
        r.warning=!problems.isEmpty();
        // On the worker thread: uiText reads only its constant table.
        const QString status=uiText(cancel->load()?"status.batchCancelled":"status.batchFinished",
                                    {QString::number(done),QString::number(skipped),QString::number(errors)});
        r.summary=parts.join(u'\n');
        r.message=status;
        if(errors)r.error=status+u'\n'+details.join(u'\n');
        return r;
    },uiText("status.batchExporting"),"batch-export");
}

void PreviewController::requestExportProof(const QVariantMap& json) {
    if(!ready_||!frame_)return;
    const auto recipe=recipes::Recipe::fromJson(QJsonObject::fromVariantMap(json));
    const auto frame=frame_;const auto navigator=navigator_;
    const auto gen=++proof_generation_;
    // The proof is the file: graded as the export grades (the navigator is
    // the cropped frame, so each pixel is graded at its source position).
    const auto grade=desktop::postdev::gradeFor(postdev_,navigator.colorSpace());
    const auto map=desktop::postdev::shownSourceMap(frame,geometry_);
    Job job=[this,gen,recipe,frame,navigator,grade,map](desktop::PreviewHost& host){
        Reply r;r.generation=gen;r.operation="proof";
        // A later request has already replaced this one: skip the work.
        if(proof_generation_.load()!=gen)return r;
        try {
            const bool di=recipe.format==recipes::Format::di;
            QImage graded=navigator;
            if(grade&&!di)desktop::postdev::gradeImage(graded,*grade,map);
            const QImage rgba64=graded.convertToFormat(QImage::Format_RGBA64);
            QVariantMap info{{"digitalIntermediate",di}};
            if(di) {
                // The DI holds Cineon codes, not colours; the page shows the
                // print and says so (ExportPage: no colour space to prove).
                r.proof=navigator;
                info["space"]=QStringLiteral("Cineon log (untagged)");info["identity"]=true;info["clipped"]=0.0;
            } else {
                bool fellBack=false;
                const auto space=recipe.engineSpace(&fellBack);
                const auto converted=exporting::convert(rgba64,frame->encoding,space,host.engine());
                r.proof=desktop::display::halfImage(converted.rgba64,desktop::display::colorSpace({space,true}));
                info["space"]=fellBack?QStringLiteral("Display P3"):recipe.colorSpaceName();
                info["identity"]=converted.identity;info["clipped"]=converted.clippedFraction;
            }
            r.proofInfo=info;
        } catch(const std::exception& e){r.error=text(e.what());}
        return r;
    };
    {std::lock_guard lock(mutex_);jobs_.push_back(std::move(job));}
    wake_.notify_one();
}

void PreviewController::acceptProof(Reply reply) {
    if(reply.generation!=proof_generation_.load())return;
    if(!reply.error.isEmpty()) {
        export_proof_={};export_proof_info_={{"error",reply.error}};
    } else if(!reply.proof.isNull()) {
        export_proof_=std::move(reply.proof);export_proof_info_=std::move(reply.proofInfo);
    } else return;
    emit exportProofChanged();
}
