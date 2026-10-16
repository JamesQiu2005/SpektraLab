#include "PreviewController.hpp"
#include "ExportRecipeStore.hpp"
#include "AppSettings.hpp"
#include "AppShell.hpp"
#include "ShellCapture.hpp"
#include "CanvasMath.hpp"
#include "CanvasTools.hpp"
#include "ColorPipeline.hpp"
#include "FrameCanvas.hpp"
#include "FrameImage.hpp"
#include "Localizer.hpp"
#include "Messages.hpp"
#include <QCommandLineParser>
#include <QThread>
#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QStandardPaths>
#include <QWheelEvent>
#include <QStringList>
#include <functional>
#include <QTimer>
#include <QtCore/qfloat16.h>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

namespace {
namespace display=spk::desktop::display;
// The harness's own time, reported so a slow run can be split into what the
// app took and what the checks took.
double harnessHashMs=0;
struct HashClock {
    QElapsedTimer t;HashClock(){t.start();}~HashClock(){harnessHashMs+=double(t.nsecsElapsed())/1e6;}
};
// The engine frame's own RGBA16 rows (padding excluded): what must never
// change under a held FramePtr. Kept as a copy and compared byte for byte --
// stronger than a digest, and a 251 MB SHA-256 costs ~1.5 s on this machine.
std::vector<std::uint16_t> frameRows(const spk::desktop::FramePtr& frame) {
    const HashClock clock;
    const auto& pixels=frame->pixels();
    std::vector<std::uint16_t> rows(std::size_t(pixels.width)*pixels.height*4);
    for(std::uint32_t y=0;y<pixels.height;++y)
        std::memcpy(rows.data()+std::size_t(y)*pixels.width*4,pixels.rgba16+std::size_t(y)*pixels.row_stride_px*4,
                    std::size_t(pixels.width)*8);
    return rows;
}
bool sameRows(const spk::desktop::FramePtr& frame,const std::vector<std::uint16_t>& rows) {
    const HashClock clock;
    const auto& pixels=frame->pixels();
    if(rows.size()!=std::size_t(pixels.width)*pixels.height*4)return false;
    for(std::uint32_t y=0;y<pixels.height;++y)
        if(std::memcmp(rows.data()+std::size_t(y)*pixels.width*4,pixels.rgba16+std::size_t(y)*pixels.row_stride_px*4,
                       std::size_t(pixels.width)*8)!=0)return false;
    return true;
}
// An identity for the report, not a security claim: MD5 of the displayed
// half floats (row bytes, no padding).
QString imageHash(const QImage& image) {
    const HashClock clock;
    QCryptographicHash hash(QCryptographicHash::Md5);
    const auto rowBytes=qsizetype(image.width())*image.depth()/8;
    for(int y=0;y<image.height();++y)hash.addData(QByteArrayView(reinterpret_cast<const char*>(image.constScanLine(y)),rowBytes));
    return QString::fromLatin1(hash.result().toHex());
}
// Every channel of the published image is the frame's code/65535 to within
// half a half-float step, plus the float product's ulp (FrameImage rounds
// float(code)/65535 to the nearest half; spk_qt_frame_image pins it exactly).
bool imageHoldsFrame(const QImage& image,const spk::desktop::FramePtr& frame) {
    const auto& pixels=frame->pixels();
    if(image.format()!=QImage::Format_RGBX16FPx4||image.width()!=int(pixels.width)||image.height()!=int(pixels.height))return false;
    std::vector<float> row(std::size_t(pixels.width)*4);
    for(int y=0;y<image.height();++y) {
        qFloatFromFloat16(row.data(),reinterpret_cast<const qfloat16*>(image.constScanLine(y)),qsizetype(row.size()));
        const auto* source=pixels.rgba16+std::size_t(y)*pixels.row_stride_px*4;
        for(std::size_t i=0;i<row.size();++i) {
            const double expected=i%4==3?1.0:source[i]/65535.0;
            const double step=expected<std::ldexp(1.0,-14)?std::ldexp(1.0,-24):std::ldexp(1.0,std::ilogb(expected)-10);
            if(std::abs(double(row[i])-expected)>step*0.5+expected*std::ldexp(1.0,-23)+1e-12)return false;
        }
    }
    return true;
}
// Mean of each colour channel over an RGBX16FPx4 image.
std::array<double,3> meanColour(const QImage& image) {
    std::array<double,3> sum{};std::vector<float> row(std::size_t(image.width())*4);
    for(int y=0;y<image.height();++y) {
        qFloatFromFloat16(row.data(),reinterpret_cast<const qfloat16*>(image.constScanLine(y)),qsizetype(row.size()));
        for(std::size_t x=0;x<row.size();x+=4)for(int c=0;c<3;++c)sum[c]+=row[x+c];
    }
    for(auto& s:sum)s/=double(image.width())*image.height();
    return sum;
}

// This is an actual QML/controller/engine test with saved window captures. It
// deliberately makes no claim about physical monitor colour management or
// native file-dialog interaction; those need a separate interactive gate.
class SelfTest final:public QObject {
public:
    SelfTest(PreviewController& controller,QQuickWindow& window,QString input,QString reject,
             QString output,std::shared_ptr<std::atomic_bool> failDisplay,QString requestedSpace)
        :controller_(controller),window_(window),input_(std::move(input)),reject_(std::move(reject)),
         output_(std::move(output)),requested_space_(std::move(requestedSpace)),fail_display_(std::move(failDisplay)) {
        elapsed_.start();
        // The canvas dithers deep (half-float) frames by one output LSB, even
        // under the identity LUT; the pixel comparisons below are exact, so
        // this harness draws undithered.
        ColorPipeline::forWindow(&window_)->setDither(false);
        canvas_=window_.findChild<FrameCanvas*>("frameCanvas");
        QObject::connect(&controller_,&PreviewController::initialized,this,[this](bool ok){
            if(!require(ok,"engine_init"))return;
            if(!require(canvas_!=nullptr,"canvas_found"))return;
            controller_.openRaw(QUrl::fromLocalFile(input_));
        });
        QObject::connect(&controller_,&PreviewController::operationFinished,this,
            [this](const QString& operation,bool ok){++operations_finished_;step(operation,ok);});
        QObject::connect(&controller_,&PreviewController::frameChanged,this,[this]{++frame_publications_;});
        // A recipe export's files; emitted before its operationFinished.
        QObject::connect(&controller_,&PreviewController::exportFinished,this,
            [this](const QString& summary,bool,const QStringList& files){exported_=files;checks_["recipe_export_summary"]=summary;});
        QTimer::singleShot(180000,this,[this]{if(!done_)finish(false,"timeout");});
    }
private:
    bool require(bool value,const QString& name) {
        checks_[name]=value;if(!value){finish(false,name+": "+controller_.status());return false;}return true;
    }
    void later(std::function<void()> action,int delayMs=180){QTimer::singleShot(delayMs,this,[this,action=std::move(action)]{if(!done_)action();});}
    int filmIndex(const QString& id) const {
        const auto films=controller_.films();
        for(int i=0;i<films.size();++i)if(films[i].toMap().value("id").toString()==id)return i;
        return -1;
    }
    // The next paper the current (colour) film can print on: the silver
    // paper is refused for it (StockCatalog.canPrint).
    int nextColourPaper(int from) const {
        const auto papers=controller_.papers();
        int i=from;
        do i=(i+1)%int(papers.size());while(i!=from&&papers[i].toMap().value("monochrome").toBool());
        return i;
    }
    bool exposureIs(double ev) const {
        return std::abs(controller_.exposureEv()-ev)<1e-12&&
            std::abs(controller_.frame()->settings.print_exposure-std::exp2(-ev))<1e-12;
    }
    void checkpoint() {held_=controller_.frame();saved_publications_=frame_publications_;saved_operations_=operations_finished_;}
    void startSlides() {
        remembered_paper_=controller_.paperIndex();remembered_ev_=controller_.exposureEv();
        negative_film_=controller_.filmIndex();slide_index_=0;stage_=15;
        selectSlide();
    }
    void selectSlide() {
        const int index=filmIndex(slide_ids_[slide_index_]);
        if(!require(index>=0,"slide_in_catalog_"+slide_ids_[slide_index_]))return;
        controller_.setFilmIndex(index);
    }
    bool capture(const QString& name) {
        capture_=window_.grabWindow();
        return require(!capture_.isNull()&&capture_.save(output_+"/"+name+".png"),"capture_"+name);
    }
    // What the canvases receive for the opened frame: half floats tagged with
    // the space the session reported, the frame's own codes, a reduced
    // navigator and a 16-bit-class thumbnail.
    bool checkPublication() {
        const auto& encoding=original_->encoding;
        const auto metadata=controller_.metadata();
        checks_["output_color_space"]=QString::fromStdString(encoding.color_space);
        checks_["output_cctf_encoding"]=encoding.cctf_encoding;
        checks_["display_convert_ms"]=metadata.value("convertMs").toDouble();
        checks_["display_publish_ms"]=metadata.value("publishMs").toDouble();
        if(!require(QString::fromStdString(encoding.color_space)==requested_space_&&encoding.cctf_encoding,
                    "session_reports_requested_output_space"))return false;
        const auto shown=controller_.uncroppedImage(),preview=controller_.previewImage();
        // Independently of display::colorSpace, the two spaces this gate runs
        // in have a Qt name to land on.
        const QColorSpace named=requested_space_=="sRGB"?QColorSpace(QColorSpace::SRgb):
            requested_space_=="ProPhoto RGB"?QColorSpace(QColorSpace::ProPhotoRgb):display::colorSpace(encoding);
        if(!require(shown.format()==QImage::Format_RGBX16FPx4&&shown.colorSpace()==display::colorSpace(encoding)&&
                    shown.colorSpace()==named&&preview.colorSpace()==shown.colorSpace(),
                    "display_half_float_tagged_with_session_space"))return false;
        if(!require(imageHoldsFrame(shown,original_),"display_holds_frame_codes_within_half_precision"))return false;
        const auto navigator=controller_.navigatorImage();
        const int previewEdge=std::max(preview.width(),preview.height());
        const int navigatorEdge=std::max(navigator.width(),navigator.height());
        const auto previewMean=meanColour(preview),navigatorMean=meanColour(navigator);
        double meanError=0;for(int c=0;c<3;++c)meanError=std::max(meanError,std::abs(previewMean[c]-navigatorMean[c]));
        checks_["navigator_width"]=navigator.width();checks_["navigator_height"]=navigator.height();
        checks_["navigator_mean_error"]=meanError;
        if(!require(navigator.format()==QImage::Format_RGBX16FPx4&&navigator.colorSpace()==preview.colorSpace()&&
                    navigatorEdge==std::min(display::kNavigatorLongEdge,previewEdge)&&
                    std::abs(double(navigator.width())/navigator.height()-double(preview.width())/preview.height())<
                        2.0/std::min(navigator.width(),navigator.height())&&meanError<1e-3,
                    "navigator_reduced_same_tag_mean_kept"))return false;
        const auto items=controller_.libraryItems();
        const auto thumbnail=items.value(controller_.activeIndex()).toMap().value("thumbnail").value<QImage>();
        return require(thumbnail.format()==QImage::Format_RGBX16FPx4&&thumbnail.colorSpace()==preview.colorSpace()&&
                       thumbnail.width()<=display::kThumbnailBox.width()&&thumbnail.height()<=display::kThumbnailBox.height()&&
                       (thumbnail.width()==display::kThumbnailBox.width()||thumbnail.height()==display::kThumbnailBox.height()),
                       "thumbnail_half_float_fits_strip");
    }
    // A recipe in the export page's JSON (ExportRecipe.hpp): one folder, the
    // original name, nothing beside the original.
    static QVariantMap recipe(const char* format,const char* space,const QString& folder,bool exif) {
        return {{"name","self-test"},{"format",format},
                {"colorSpace",QVariantMap{{"builtIn",QVariantMap{{"_0",space}}}}},
                {"folder",QVariantMap{{"fixed",QVariantMap{{"path",folder}}}}},{"subfolder",""},
                {"naming",QVariantMap{{"order",QStringList{"originalName","filmStock","printStock","date"}},
                                      {"tokens",QStringList{"originalName"}},{"separator","_"}}},
                {"existing","skip"},{"quality",0.95},{"outputSize",QVariantMap{{"original",true}}},
                {"metadata",QVariantMap{{"exif",exif},{"fields",QStringList{"camera","lens","exposure","date"}}}}};
    }
    static QByteArray sha256(const QString& path) {
        QFile file(path);if(!file.open(QIODevice::ReadOnly))return {};
        QCryptographicHash hash(QCryptographicHash::Sha256);hash.addData(&file);return hash.result().toHex();
    }
    // The pending-preview hold while a file dialog is open (stage 2).
    void startDialogChecks() {
        stage_=2;controller_.setExposureEv(0.5);
        controller_.setDialogOpen(true);
        later([this]{
            if(!require(!controller_.busy()&&!controller_.settingsEditable()&&controller_.dirty()&&
                        controller_.frame()==original_,"file_dialog_suspends_pending_preview"))return;
            controller_.setExposureEv(1);
            if(!require(controller_.exposureEv()==0.5,"file_dialog_holds_selected_settings"))return;
            controller_.setDialogOpen(false);
        },400);
        // The reprint is ~0.3-1.5 s; 15 s (was 5) because a shared GPU busy
        // with another process's Vulkan work made it miss 5 s here, measured
        // (brightness_preview_after_ms in the report).
        dialog_checks_.start();
        QTimer::singleShot(15000,this,[this]{if(!done_&&stage_==2)finish(false,"automatic brightness preview did not run");});
    }
    void step(const QString& operation,bool ok) {
        if(done_)return;
        if(stage_==0) {
            if(!require(operation=="open"&&ok&&controller_.hasFrame(),"open_raw"))return;
            original_=controller_.frame();original_rows_=frameRows(original_);
            checks_["width"]=int(original_->width());checks_["height"]=int(original_->height());
            checks_["film_count"]=controller_.films().size();checks_["paper_count"]=controller_.papers().size();
            QElapsedTimer publicationCheck;publicationCheck.start();
            const bool published=checkPublication();
            checks_["harness_publication_check_ms"]=double(publicationCheck.nsecsElapsed())/1e6;
            if(!published)return;
            if(!original_->encoding.is_encoded_srgb()) {
                // A working-space session (--output-color-space): its frames
                // are tagged above; the writers embed sRGB.icc, so export
                // must refuse rather than mislabel. The rest assumes sRGB.
                stage_=30;
                later([this]{
                    if(!capture("working-space"))return;
                    controller_.exportTiff(QUrl::fromLocalFile(output_+"/working-space.tif"));
                });
                return;
            }
            stage_=1;
            later([this]{
                if(!capture("fit"))return;
                if(!require(canvas_->fit()&&canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"canvas_matches_published_frame"))return;
                canvas_->resetView(false);
                later([this]{
                    const auto rect=canvas_->imageRect();
                    const auto ratio=window_.effectiveDevicePixelRatio();
                    if(!require(std::abs(rect.width()*ratio-original_->width())<0.01&&std::abs(canvas_->scalePercent()-100)<1e-9,"physical_100_percent"))return;
                    if(!capture("100-percent"))return;
                    // Interior canvas samples prove the texture is displaying
                    // this frame at one physical pixel per source pixel. The
                    // image is half floats; pixel() rounds each to 8 bits
                    // (QRgbaFloat16::toArgb32), as the software scene graph's
                    // painter does into the 8-bit window, so this stays exact.
                    const auto origin=canvas_->mapToScene(QPointF());
                    bool exact=true;int samples=0;
                    for(double fx:{0.3,0.5,0.7})for(double fy:{0.3,0.5,0.7}) {
                        const int x=int(std::floor((origin.x()+canvas_->width()*fx)*ratio));
                        const int y=int(std::floor((origin.y()+canvas_->height()*fy)*ratio));
                        const int sx=int(std::floor(x+0.5-(origin.x()+rect.x())*ratio));
                        const int sy=int(std::floor(y+0.5-(origin.y()+rect.y())*ratio));
                        if(sx<0||sy<0||sx>=canvas_->image().width()||sy>=canvas_->image().height())continue;
                        exact=exact&&capture_.pixel(x,y)==canvas_->image().pixel(sx,sy);++samples;
                    }
                    if(!require(exact&&samples==9,"100_percent_source_pixels_exact"))return;
                    canvas_->panBy(1e9,1e9);const auto edge=canvas_->imageRect();
                    canvas_->panBy(-1,-1);const auto back=canvas_->imageRect();
                    if(!require((edge.width()<=canvas_->width()||std::abs(back.x()-edge.x()+1)<0.01)&&
                                (edge.height()<=canvas_->height()||std::abs(back.y()-edge.y()+1)<0.01),"pan_clamp_no_dead_zone"))return;
                    canvas_->resetView(true);
                    controller_.exportTiff(QUrl::fromLocalFile(output_+"/displayed-frame.tif"));
                    // While export is queued, commands that could replace the
                    // selected frame or mutate its settings must be rejected.
                    controller_.setExposureEv(1);controller_.openRaw(QUrl::fromLocalFile(reject_));
                    require(controller_.busy()&&controller_.frame()==original_&&controller_.exposureEv()==0,"export_single_flight");
                });
            });
        } else if(stage_==1) {
            if(!require(operation=="export"&&ok&&QFileInfo(output_+"/displayed-frame.tif").size()>0,"export_displayed_frame"))return;
            // The export page's path for the same frame and the same settings
            // (sRGB, TIFF, no EXIF): byte for byte the file above.
            stage_=40;
            controller_.exportWithRecipe(recipe("TIFF 16-bit","kCGColorSpaceSRGB",output_+"/recipe",false));
            controller_.openRaw(QUrl::fromLocalFile(reject_));
            require(controller_.batchExporting()&&controller_.frame()==original_,"recipe_export_holds_the_open_frame");
        } else if(stage_==40) {
            const QString recipeFile=output_+"/recipe/input.tif";
            if(!require(operation=="batch-export"&&ok&&exported_.size()==1&&QDir::cleanPath(exported_.first())==QDir::cleanPath(recipeFile),"recipe_export_srgb_tiff"))return;
            const bool same=sha256(recipeFile)==sha256(output_+"/displayed-frame.tif");
            checks_["recipe_srgb_tiff_sha256"]=QString::fromLatin1(sha256(recipeFile));
            if(!require(same,"recipe_srgb_export_byte_identical_to_old_export"))return;
            stage_=41;exported_.clear();
            controller_.exportWithRecipe(recipe("JPEG","kCGColorSpaceDisplayP3",output_+"/recipe",true));
        } else if(stage_==41) {
            const QString jpeg=output_+"/recipe/input.jpg";
            if(!require(operation=="batch-export"&&ok&&QDir::cleanPath(exported_.value(0))==QDir::cleanPath(jpeg),"recipe_export_p3_jpeg"))return;
            QFile file(jpeg);file.open(QIODevice::ReadOnly);const auto bytes=file.readAll();
            const auto make=QString::fromStdString(original_->metadata.make).toLatin1();
            QImageReader reader(jpeg);const auto space=reader.read().colorSpace();
            if(!require(bytes.contains(QByteArray("Exif\0\0",6))&&!make.isEmpty()&&bytes.contains(make)&&
                        space.isValid()&&space.description()=="Display P3"&&
                        space.primaries()==QColorSpace::Primaries::DciP3D65,"recipe_export_p3_jpeg_tagged_with_exif"))return;
            startDialogChecks();
        } else if(stage_==2) {
            checks_["brightness_preview_after_ms"]=double(dialog_checks_.elapsed());
            if(controller_.frame())checks_["brightness_render_ms"]=controller_.frame()->timings.render_ms;
            if(!require(operation=="render"&&ok&&controller_.frame()!=original_&&controller_.frame()->reprint(),"brightness_reprint"))return;
            if(!require(sameRows(original_,original_rows_),"old_frame_immutable"))return;
            held_=controller_.frame();stage_=3;controller_.openRaw(QUrl::fromLocalFile(reject_));
        } else if(stage_==3) {
            if(!require(operation=="open"&&!ok&&controller_.frame()==held_,"failed_raw_retains_frame"))return;
            checks_["rejected_message"]=controller_.status();
            stage_=4;controller_.setExposureEv(1);controller_.exportTiff(QUrl::fromLocalFile(output_+"/displayed-frame.tif"));
        } else if(stage_==4) {
            if(!require(operation=="export"&&!ok&&controller_.frame()==held_&&controller_.dirty()&&controller_.exposureEv()==1,"export_refuses_overwrite_and_retains_pending_settings"))return;
            // Fault injection at the publication boundary: host opens a
            // different decode mode successfully, QImage publication fails.
            stage_=5;*fail_display_=true;controller_.setDecodeMode(1);controller_.openRaw(QUrl::fromLocalFile(input_));
        } else if(stage_==5) {
            if(!require(operation=="open"&&!ok&&controller_.frame()==held_&&controller_.decodeMode()==0,"publication_failure_retains_frame_and_controls"))return;
            stage_=6;controller_.apply();
        } else if(stage_==6) {
            if(!require(operation=="render"&&ok&&controller_.frame()->source==held_->source&&
                        controller_.frame()->decode_mode==held_->decode_mode&&!controller_.frame()->reprint(),"publication_failure_reconciles_worker_session"))return;
            if(!require(sameRows(original_,original_rows_),"held_frame_still_immutable"))return;
            const int negative=filmIndex("kodak_ektar_100");
            if(!require(negative>=0,"negative_test_stock_in_catalog"))return;
            stage_=7;controller_.setFilmIndex(negative);
        } else if(stage_==7) {
            if(!require(operation=="render"&&ok&&!controller_.frame()->reprint()&&
                        controller_.frame()->settings.film_stock!=held_->settings.film_stock,"film_change_renders_selected_stock"))return;
            // macOS Session.selectFilmStock: the film brings its own paper.
            if(!require(controller_.frame()->settings.print_stock=="kodak_portra_endura","film_change_takes_its_own_paper"))return;
            film_paper_=controller_.frame()->settings.print_stock;
            stage_=8;controller_.setPaperIndex(nextColourPaper(controller_.paperIndex()));
        } else if(stage_==8) {
            if(!require(operation=="render"&&ok&&controller_.frame()->reprint()&&
                        controller_.frame()->settings.print_stock!=film_paper_,"paper_change_reprints_selected_stock"))return;
            checkpoint();stage_=9;
            controller_.setExposureEv(-0.2);controller_.setExposureEv(0.3);controller_.setExposureEv(0.8);
            if(!require(!controller_.busy()&&controller_.frame()==held_,"rapid_idle_edits_are_debounced"))return;
        } else if(stage_==9) {
            if(!require(operation=="render"&&ok&&exposureIs(0.8)&&!controller_.dirty()&&
                        frame_publications_==saved_publications_+1&&operations_finished_==saved_operations_+1,
                        "rapid_idle_edits_publish_only_final_settings"))return;
            stage_=10;
            later([this]{
                if(!require(!controller_.busy()&&!controller_.dirty()&&
                            frame_publications_==saved_publications_+1&&operations_finished_==saved_operations_+1,
                            "rapid_idle_edits_do_not_queue_extra_renders"))return;
                checkpoint();stage_=11;
                // Start synchronously, then edit before the event loop can
                // accept its reply. This exercises a real in-flight request
                // without timing guesses or a test-only worker delay.
                controller_.setExposureEv(1.1);controller_.apply();
                if(!require(controller_.busy()&&controller_.settingsEditable(),"render_allows_new_settings"))return;
                const int negative=filmIndex("kodak_portra_400");
                if(!require(negative>=0,"supersede_stock_in_catalog"))return;
                controller_.setFilmIndex(negative);controller_.setExposureEv(-0.4);
                if(!require(controller_.filmIndex()==negative&&std::abs(controller_.exposureEv()+0.4)<1e-12,
                            "in_flight_edits_record_latest_settings"))return;
            },650);
        } else if(stage_==11) {
            if(!require(operation=="render"&&ok&&controller_.frame()==held_&&
                        controller_.filmIndex()==filmIndex("kodak_portra_400")&&
                        std::abs(controller_.exposureEv()+0.4)<1e-12&&controller_.dirty()&&
                        frame_publications_==saved_publications_&&operations_finished_==saved_operations_+1,
                        "superseded_render_never_publishes_or_restores_controls"))return;
            stage_=12;
        } else if(stage_==12) {
            if(!require(operation=="render"&&ok&&controller_.frame()->settings.film_stock=="kodak_portra_400"&&
                        exposureIs(-0.4)&&!controller_.dirty()&&!controller_.busy()&&
                        frame_publications_==saved_publications_+1&&operations_finished_==saved_operations_+2,
                        "in_flight_edits_eventually_publish_latest_settings"))return;
            checkpoint();stage_=13;
            controller_.setExposureEv(0.4);controller_.apply();controller_.setExposureEv(-0.4);
            if(!require(controller_.busy()&&!controller_.dirty(),"return_to_displayed_settings_is_recorded"))return;
        } else if(stage_==13) {
            if(!require(operation=="render"&&ok&&controller_.frame()==held_&&exposureIs(-0.4)&&
                        !controller_.busy()&&!controller_.dirty()&&frame_publications_==saved_publications_&&
                        operations_finished_==saved_operations_+1,"return_to_displayed_settings_drops_old_result"))return;
            stage_=14;
            later([this]{
                if(!require(!controller_.busy()&&!controller_.dirty()&&controller_.frame()==held_&&
                            frame_publications_==saved_publications_&&operations_finished_==saved_operations_+1,
                            "return_to_displayed_settings_settles_without_render"))return;
                startSlides();
            },650);
        } else if(stage_==15) {
            const auto id=slide_ids_[slide_index_];
            const auto caseName=id+(headroom_slides_?QStringLiteral("-headroom"):QString());
            if(!require(operation=="render"&&ok&&controller_.frame()->scan_film&&controller_.filmIsPositive()&&
                        controller_.frame()->settings.film_stock==id.toStdString()&&!controller_.dirty(),
                        "slide_auto_scan_"+caseName))return;
            controller_.setPaperIndex((remembered_paper_+1)%controller_.papers().size());
            controller_.setExposureEv(remembered_ev_+0.5);
            if(!require(controller_.paperIndex()==remembered_paper_&&exposureIs(remembered_ev_)&&
                        !controller_.dirty()&&!controller_.busy(),"slide_ignores_print_controls_"+caseName))return;
            later([this,id,caseName]{
                const auto* brightness=window_.findChild<QObject*>("exposureSlider");
                if(!require(brightness&&!brightness->property("enabled").toBool(),"slide_brightness_control_disabled_"+caseName))return;
                if(!require(canvas_->image().cacheKey()==controller_.previewImage().cacheKey()&&
                            canvas_->image().width()==int(controller_.frame()->width())&&
                            canvas_->image().height()==int(controller_.frame()->height()),"slide_canvas_matches_frame_"+caseName))return;
                if(!capture("slide-"+caseName))return;
                slide_results_.append(QJsonObject{{"film",id},{"scan_film",controller_.frame()->scan_film},
                    {"decode_mode",headroom_slides_?"headroom":"compatible16"},
                    {"width",int(controller_.frame()->width())},{"height",int(controller_.frame()->height())},
                    {"display_rgbx16fp_md5",imageHash(canvas_->image())},
                    {"render_ms",controller_.frame()->timings.render_ms},
                    {"convert_ms",controller_.metadata().value("convertMs").toDouble()},
                    {"screenshot","slide-"+caseName+".png"}});
                if(++slide_index_<slide_ids_.size())selectSlide();
                else {stage_=16;controller_.setFilmIndex(negative_film_);}
            });
        } else if(stage_==16) {
            if(!require(operation=="render"&&ok&&!controller_.frame()->scan_film&&!controller_.filmIsPositive()&&
                        controller_.filmIndex()==negative_film_&&controller_.paperIndex()==remembered_paper_&&
                        exposureIs(remembered_ev_)&&!controller_.dirty(),headroom_slides_?
                        "negative_slide_negative_restores_print_controls_headroom":"negative_slide_negative_restores_print_controls"))return;
            if(headroom_slides_){stage_=18;controller_.setDecodeMode(0);}
            else {stage_=17;controller_.setDecodeMode(1);}
        } else if(stage_==17) {
            if(!require(operation=="render"&&ok&&controller_.decodeMode()==1&&
                        controller_.frame()->decode_mode==spk::desktop::DecodeMode::headroom&&
                        controller_.frame()->timings.decode_ms>0&&!controller_.dirty(),"decode_mode_automatically_reopens_headroom"))return;
            headroom_slides_=true;startSlides();
        } else if(stage_==18) {
            if(!require(operation=="render"&&ok&&controller_.decodeMode()==0&&
                        controller_.frame()->decode_mode==spk::desktop::DecodeMode::compatible16&&
                        controller_.frame()->timings.decode_ms>0&&!controller_.dirty(),"decode_mode_automatically_returns_compatible"))return;
            stage_=19;controller_.resetSettings();
        } else if(stage_==19) {
            // Reset is a new photograph's settings: the table's initial values,
            // but the frame keeps its film edge seeds (its body, advance and
            // number on the roll, Session.seedFilmEdge).
            spk::desktop::RenderSettings initial;
            for(const char* key:{"overscan_camera_seed","overscan_frame_seed","overscan_frame_number","film_edge_seeded"})
                initial.set(key,controller_.frame()->settings.get(key));
            if(!require(operation=="render"&&ok&&controller_.frame()->settings==initial&&exposureIs(0)&&
                        !controller_.frame()->scan_film&&controller_.decodeMode()==0&&!controller_.dirty(),
                        "reset_settings_automatically_updates_preview"))return;
            if(!require(sameRows(original_,original_rows_),"original_frame_immutable_after_all_auto_edits"))return;
            stage_=20;
            later([this]{
                if(!capture("final"))return;
                const QString copy=output_+"/second-frame."+QFileInfo(input_).suffix();
                if(!require(QFile::copy(input_,copy),"isolated_second_photo_fixture"))return;
                controller_.openFiles({QUrl::fromLocalFile(input_),QUrl::fromLocalFile(copy)});
            });
        } else if(stage_==20) {
            if(!require(operation=="open"&&ok&&controller_.libraryItems().size()>=3,
                        "qml_library_contains_two_photos_and_rejected_item"))return;
            stage_=21;later([this]{
                if(!capture("library"))return;
                const auto unchanged=controller_.frame();
                controller_.setCropAspect(1);
                if(!require(controller_.frame()==unchanged&&controller_.previewImage().width()==controller_.previewImage().height(),
                            "crop_changes_display_without_redeveloping"))return;
                later([this]{
                    if(!require(canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"cropped_canvas_matches_output")||!capture("cropped"))return;
                    if(!require(QMetaObject::invokeMethod(&window_,"startCrop"),"crop_editor_opens"))return;
                    later([this]{
                        if(!require(window_.property("cropMode").toBool()&&canvas_->image().cacheKey()==controller_.uncroppedImage().cacheKey(),
                                    "crop_editor_displays_uncropped_source")||!capture("crop-editor"))return;
                        // Deliver real pointer events through the QML overlay,
                        // including its dialog/debounce lock and normalized
                        // source mapping. No native file dialog is automated.
                        const auto bounds=canvas_->imageRect();
                        const auto start=canvas_->mapToScene(bounds.topLeft()+QPointF(bounds.width()*0.2,bounds.height()*0.3));
                        const auto end=canvas_->mapToScene(bounds.topLeft()+QPointF(bounds.width()*0.7,bounds.height()*0.7));
                        auto pointer=[this](QEvent::Type type,QPointF point,Qt::MouseButton button,Qt::MouseButtons buttons,
                                            Qt::KeyboardModifiers modifiers){mouse(type,point,button,buttons,modifiers);};
                        // Alt: the start lies inside the 1:1 crop, where a
                        // plain drag now moves the frame; Alt draws a new
                        // rectangle anywhere (the Mac's Option-drag).
                        pointer(QEvent::MouseButtonPress,start,Qt::LeftButton,Qt::LeftButton,Qt::AltModifier);
                        pointer(QEvent::MouseMove,end,Qt::NoButton,Qt::LeftButton,Qt::AltModifier);
                        pointer(QEvent::MouseButtonRelease,end,Qt::LeftButton,Qt::NoButton,Qt::AltModifier);
                        const auto crop=controller_.cropRect();
                        if(!require(!window_.property("cropMode").toBool()&&std::abs(crop.x()-0.2)<1e-5&&
                                    std::abs(crop.y()-0.3)<1e-5&&std::abs(crop.width()-0.5)<1e-5&&
                                    std::abs(crop.height()-0.4)<1e-5,"qml_crop_pointer_gesture_applies_geometry"))return;
                        if(!require(QMetaObject::invokeMethod(&window_,"openExport"),"export_options_open"))return;
                        later([this]{
                            if(!require(!controller_.settingsEditable(),"export_options_suspend_edits")||!capture("export-options"))return;
                            auto* popup=window_.findChild<QObject*>("exportPopup");
                            if(!require(popup&&QMetaObject::invokeMethod(popup,"close"),"export_options_close"))return;
                            later([this]{
                                if(!require(controller_.settingsEditable(),"export_options_release_edits"))return;
                                const auto frame=controller_.frame();
                                controller_.rotateClockwise();controller_.setFlipHorizontal(true);controller_.setStraightenDegrees(3.5);
                                if(!require(controller_.frame()==frame&&controller_.quarterTurns()==1&&controller_.flipHorizontal()&&
                                            controller_.straightenDegrees()==3.5,"orientation_preserves_engine_frame"))return;
                                controller_.undo();
                                if(!require(controller_.straightenDegrees()==0&&controller_.canRedo(),"geometry_undo"))return;
                                controller_.redo();controller_.flushEdits();
                                if(!require(controller_.straightenDegrees()==3.5&&controller_.persistenceWarning().isEmpty(),"geometry_redo_and_persist"))return;
                                later([this]{
                                    if(!require(canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"transformed_canvas_matches_output")||!capture("geometry"))return;
                                    auto* undoButton=window_.findChild<QObject*>("undoButton");
                                    if(!require(undoButton&&undoButton->property("enabled").toBool()&&QMetaObject::invokeMethod(undoButton,"clicked"),"qml_undo_button"))return;
                                    if(!require(controller_.straightenDegrees()==0,"qml_undo_reaches_geometry"))return;
                                    auto* redoButton=window_.findChild<QObject*>("redoButton");
                                    if(!require(redoButton&&QMetaObject::invokeMethod(redoButton,"clicked")&&controller_.straightenDegrees()==3.5,"qml_redo_button"))return;
                                    later([this]{checkHistogram();});
                                });
                            });
                        });
                    });
                });
            });
        } else if(stage_==30) {
            if(!require(operation=="export"&&!ok&&!QFileInfo::exists(output_+"/working-space.tif")&&
                        controller_.status().contains(QString::fromStdString(original_->encoding.color_space))&&
                        controller_.frame()==original_,"export_refuses_frame_not_encoded_in_srgb"))return;
            // The export page converts instead of refusing: the working-space
            // frame through the engine's transform into sRGB.
            stage_=31;exported_.clear();
            controller_.exportWithRecipe(recipe("PNG 8-bit","kCGColorSpaceSRGB",output_+"/recipe",false));
        } else if(stage_==31) {
            const QString png=output_+"/recipe/input.png";
            QImageReader reader(png);const auto image=reader.read();
            if(!require(operation=="batch-export"&&ok&&QDir::cleanPath(exported_.value(0))==QDir::cleanPath(png)&&!image.isNull()&&
                        image.width()==int(original_->width())&&image.colorSpace().isValid()&&
                        image.colorSpace().primaries()==QColorSpace::Primaries::SRgb,"recipe_export_converts_working_space_to_srgb"))return;
            finish(true,{});
        } else {
            require(false,"unexpected_operation_during_settle");
        }
    }
    // --- the canvas tools (zoom, histogram, Original, before/after, crop) ---
    void mouse(QEvent::Type type,QPointF point,Qt::MouseButton button,Qt::MouseButtons buttons,
               Qt::KeyboardModifiers modifiers=Qt::NoModifier) {
        QMouseEvent event(type,point,point,window_.mapToGlobal(point.toPoint()),button,buttons,modifiers);
        QCoreApplication::sendEvent(&window_,&event);
    }
    void drag(QPointF from,QPointF to,Qt::KeyboardModifiers modifiers=Qt::NoModifier) {
        mouse(QEvent::MouseButtonPress,from,Qt::LeftButton,Qt::LeftButton,modifiers);
        for(int i=1;i<=4;++i)mouse(QEvent::MouseMove,from+(to-from)*(i/4.0),Qt::NoButton,Qt::LeftButton,modifiers);
        mouse(QEvent::MouseButtonRelease,to,Qt::LeftButton,Qt::NoButton,modifiers);
    }
    void key(QEvent::Type type,int code) {
        QKeyEvent event(type,code,Qt::NoModifier,code==Qt::Key_Space?QStringLiteral(" "):QString());
        QCoreApplication::sendEvent(&window_,&event);
    }
    QObject* editor() const {return window_.findChild<QObject*>("editorState");}
    // Polls every 50 ms; `then` once `ready` holds, a failed `name` after the timeout.
    void waitFor(std::function<bool()> ready,std::function<void()> then,const QString& name,int timeoutMs=30000) {
        auto clock=std::make_shared<QElapsedTimer>();clock->start();
        auto poll=std::make_shared<std::function<void()>>();
        *poll=[this,ready,then,name,timeoutMs,clock,poll]{
            if(done_)return;
            if(ready()){then();return;}
            if(clock->elapsed()>timeoutMs){require(false,name);return;}
            QTimer::singleShot(50,this,[poll]{(*poll)();});
        };
        (*poll)();
    }
    // Pearson correlation of two images' luma on a 64 x 64 area-averaged grid.
    static double lumaCorrelation(const QImage& a,const QImage& b) {
        const auto small=[](const QImage& image){
            const auto reduced=display::downscaled(image,{64,64});
            std::vector<double> luma;std::vector<float> row(std::size_t(reduced.width())*4);
            for(int y=0;y<reduced.height();++y) {
                qFloatFromFloat16(row.data(),reinterpret_cast<const qfloat16*>(reduced.constScanLine(y)),qsizetype(row.size()));
                for(int x=0;x<reduced.width();++x)luma.push_back(0.2126*row[x*4]+0.7152*row[x*4+1]+0.0722*row[x*4+2]);
            }
            return luma;
        };
        const auto x=small(a),y=small(b);
        if(x.size()!=y.size()||x.empty())return 0;
        double mx=0,my=0;for(std::size_t i=0;i<x.size();++i){mx+=x[i];my+=y[i];}
        mx/=double(x.size());my/=double(y.size());
        double sxy=0,sxx=0,syy=0;
        for(std::size_t i=0;i<x.size();++i){sxy+=(x[i]-mx)*(y[i]-my);sxx+=(x[i]-mx)*(x[i]-mx);syy+=(y[i]-my)*(y[i]-my);}
        return sxx>0&&syy>0?sxy/std::sqrt(sxx*syy):0;
    }
    // The histogram counts the displayed, cropped frame (not the uncropped
    // print, the Mac's pinned bug) and heads the badge stack.
    void checkHistogram() {
        const auto shown=controller_.histogram(),whole=controller_.uncroppedHistogram();
        QElapsedTimer clock;clock.start();
        const auto expected=display::histogram(controller_.previewImage());
        checks_["histogram_visible_ms"]=double(clock.nsecsElapsed())/1e6;clock.restart();
        const auto full=display::histogram(controller_.uncroppedImage());
        checks_["histogram_full_frame_ms"]=double(clock.nsecsElapsed())/1e6;
        checks_["histogram_publish_ms"]=controller_.metadata().value("histogramMs").toDouble();
        bool same=shown.size()==1024&&whole.size()==1024,differs=false;
        for(int i=0;same&&i<1024;++i)same=std::abs(shown[i]-expected[i])<1e-6&&std::abs(whole[i]-full[i])<1e-6;
        for(int i=0;i<1024&&same;++i)differs=differs||std::abs(shown[i]-whole[i])>1e-3;
        if(!require(same&&differs,"histogram_counts_the_cropped_frame"))return;
        auto* plot=window_.findChild<QQuickItem*>("canvasHistogram");
        if(!require(plot&&plot->isVisible()&&plot->width()==200&&plot->height()==56,"histogram_overlay_shown"))return;
        if(!capture("histogram"))return;
        checkZoom();
    }
    void checkZoom() {
        const double ratio=window_.effectiveDevicePixelRatio();
        auto aligned=[this,ratio]{
            const auto r=canvas_->imageRect();const auto o=canvas_->mapToScene(QPointF());
            const double x=(o.x()+r.x())*ratio,y=(o.y()+r.y())*ratio;
            return std::abs(x-std::round(x))<1e-6&&std::abs(y-std::round(y))<1e-6;
        };
        canvas_->zoomTo(1);
        if(!require(std::abs(canvas_->scalePercent()-100)<1e-9&&aligned()&&
                    std::abs(canvas_->imageRect().width()*ratio-controller_.previewImage().width())<0.01,"zoom_100_physical_and_aligned"))return;
        canvas_->zoomStep(1);const double up1=canvas_->scalePercent();
        canvas_->zoomStep(1);const double up2=canvas_->scalePercent();const bool alignedAt200=aligned();
        if(!require(std::abs(up1-150)<1e-9&&std::abs(up2-200)<1e-9&&alignedAt200,"zoom_steps_follow_mac_ladder"))return;
        canvas_->zoomStep(-1);canvas_->zoomStep(-1);
        if(!require(std::abs(canvas_->scalePercent()-100)<1e-9,"zoom_steps_back_to_100"))return;
        // Ctrl+wheel: a quarter stop per notch, the photo point under the
        // pointer held still.
        const QPointF local(canvas_->width()*0.3,canvas_->height()*0.6);
        const auto scene=canvas_->mapToScene(local);
        const auto before=canvas_->imageRect();
        const QPointF photoBefore((local.x()-before.x())/before.width(),(local.y()-before.y())/before.height());
        QWheelEvent wheel(scene,window_.mapToGlobal(scene),QPoint(),QPoint(0,120),Qt::NoButton,Qt::ControlModifier,Qt::NoScrollPhase,false);
        QCoreApplication::sendEvent(&window_,&wheel);
        const auto after=canvas_->imageRect();
        const QPointF photoAfter((local.x()-after.x())/after.width(),(local.y()-after.y())/after.height());
        checks_["ctrl_wheel_percent"]=canvas_->scalePercent();
        if(!require(std::abs(canvas_->scalePercent()-100*std::exp2(0.25))<1e-6&&
                    std::abs(photoAfter.x()-photoBefore.x())<1e-6&&std::abs(photoAfter.y()-photoBefore.y())<1e-6,
                    "ctrl_wheel_zooms_about_pointer"))return;
        // The navigator frames what the canvas shows.
        canvas_->zoomTo(2);
        later([this]{
            const auto r=canvas_->imageRect();
            const auto fraction=editor()->property("visibleFraction").toRectF();
            const double x0=std::max(0.0,-r.x()/r.width()),x1=std::min(1.0,(canvas_->width()-r.x())/r.width());
            if(!require(fraction.width()<0.999&&std::abs(fraction.x()-x0)<1e-6&&std::abs(fraction.right()-x1)<1e-6,
                        "navigator_frames_zoomed_view")||!capture("zoom-200"))return;
            canvas_->resetView(true);
            later([this]{checkOriginal();});
        });
    }
    // The Original: the decode, in the print's tag and geometry (trap 33's
    // rule for every surface that shows the frame).
    void checkOriginal() {
        auto* state=editor();
        if(!require(state&&!controller_.originalReady(),"original_made_on_demand"))return;
        auto clock=std::make_shared<QElapsedTimer>();clock->start();
        state->setProperty("originalPinned",true);
        if(!require(controller_.originalWanted()&&controller_.originalPending(),"original_requested_when_shown"))return;
        waitFor([this]{return controller_.originalReady()&&!controller_.originalPending();},[this,clock]{
            checks_["original_wait_ms"]=double(clock->elapsed());
            const auto metadata=controller_.metadata();
            checks_["original_decode_ms"]=metadata.value("originalDecodeMs").toDouble();
            checks_["original_geometry_ms"]=metadata.value("originalMs").toDouble();
            const auto original=controller_.originalImage(),print=controller_.previewImage();
            if(!require(original.size()==print.size()&&original.format()==print.format()&&
                        original.colorSpace()==print.colorSpace(),"original_shares_print_size_and_tag"))return;
            // Same geometry: the luma of the Original follows the print's far
            // more closely than either mirror of it does.
            const double same=lumaCorrelation(original,print);
            const double mirrored=std::max(lumaCorrelation(original,print.flipped(Qt::Horizontal)),
                                           lumaCorrelation(original,print.flipped(Qt::Horizontal|Qt::Vertical)));
            checks_["original_print_luma_correlation"]=same;checks_["original_mirrored_luma_correlation"]=mirrored;
            if(!require(same>0.7&&same>mirrored+0.1,"original_agrees_with_print_geometry"))return;
            later([this]{
                const auto shown=controller_.originalImage();
                if(!require(canvas_->image().cacheKey()==shown.cacheKey(),"canvas_shows_original")||!capture("original"))return;
                editor()->setProperty("originalPinned",false);
                later([this]{
                    if(!require(canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"original_released"))return;
                    checkCompare();
                });
            });
        },"original_ready");
    }
    void checkCompare() {
        auto* state=editor();
        if(!require(QMetaObject::invokeMethod(state,"toggleCompare")&&state->property("comparing").toBool(),"compare_toggles"))return;
        later([this,state]{
            auto* before=window_.findChild<FrameCanvas*>("beforeCanvas");
            if(!require(before&&before->isVisible()&&before->imageRect()==canvas_->imageRect()&&
                        before->image().cacheKey()==controller_.originalImage().cacheKey()&&
                        canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"split_original_on_print_rectangle"))return;
            const auto r=canvas_->imageRect();
            drag(canvas_->mapToScene(QPointF(r.x()+r.width()*0.5,r.y()+r.height()*0.5)),
                 canvas_->mapToScene(QPointF(r.x()+r.width()*0.3,r.y()+r.height()*0.5)));
            checks_["compare_position_after_drag"]=state->property("comparePosition").toDouble();
            if(!require(std::abs(state->property("comparePosition").toDouble()-0.3)<0.005,"split_divider_drags"))return;
            later([this,state]{
                if(!capture("compare"))return;
                // Space wins over the split while held, and the split returns.
                window_.contentItem()->forceActiveFocus();
                key(QEvent::KeyPress,Qt::Key_Space);
                later([this,state]{
                    auto* before=window_.findChild<FrameCanvas*>("beforeCanvas");
                    if(!require(state->property("showingOriginal").toBool()&&canvas_->image().cacheKey()==controller_.originalImage().cacheKey()&&
                                !before->isVisible(),"space_holds_original"))return;
                    key(QEvent::KeyRelease,Qt::Key_Space);
                    later([this,state]{
                        auto* before=window_.findChild<FrameCanvas*>("beforeCanvas");
                        if(!require(!state->property("showingOriginal").toBool()&&before->isVisible()&&
                                    canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"space_release_returns_to_split"))return;
                        QMetaObject::invokeMethod(state,"toggleCompare");
                        later([this]{checkCropHandles();});
                    });
                });
            });
        });
    }
    void checkCropHandles() {
        auto* state=editor();
        if(!require(!state->property("comparing").toBool()&&QMetaObject::invokeMethod(&window_,"startCrop"),"crop_editor_reopens"))return;
        later([this,state]{
            if(!require(window_.property("cropMode").toBool()&&canvas_->image().cacheKey()==controller_.uncroppedImage().cacheKey(),
                        "crop_editor_shows_source_again")||!capture("crop-handles"))return;
            const auto crop=controller_.cropRect();const auto r=canvas_->imageRect();
            auto at=[this,r](double nx,double ny){return canvas_->mapToScene(QPointF(r.x()+nx*r.width(),r.y()+ny*r.height()));};
            // The bottom-right grip, inwards: the top-left corner stays.
            drag(at(crop.right(),crop.bottom()),at(crop.right()-0.05,crop.bottom()-0.05));
            const auto resized=state->property("draftCrop").toRectF();
            checks_["crop_lock_ratio"]=state->property("cropLockRatio").toDouble();
            if(!require(window_.property("cropMode").toBool()&&std::abs(resized.x()-crop.x())<1e-9&&std::abs(resized.y()-crop.y())<1e-9&&
                        std::abs(resized.width()-(crop.width()-0.05))<1e-3&&std::abs(resized.height()-(crop.height()-0.05))<1e-3,
                        "crop_grip_resizes_opposite_corner_pinned"))return;
            // The body: moved as a whole.
            const auto c=resized.center();
            drag(at(c.x(),c.y()),at(c.x()+0.04,c.y()-0.03));
            const auto moved=state->property("draftCrop").toRectF();
            if(!require(std::abs(moved.x()-(resized.x()+0.04))<1e-3&&std::abs(moved.y()-(resized.y()-0.03))<1e-3&&
                        std::abs(moved.width()-resized.width())<1e-9&&std::abs(moved.height()-resized.height())<1e-9,"crop_body_moves"))return;
            // Ctrl-drag along a line that should be level.
            const QSizeF source(controller_.frame()->width(),controller_.frame()->height());
            const auto expected=spk::desktop::canvas::straightenFromLine({0.3,0.5},{0.7,0.53},source);
            // Pressed and moved, captured with the line on screen, released.
            mouse(QEvent::MouseButtonPress,at(0.3,0.5),Qt::LeftButton,Qt::LeftButton,Qt::ControlModifier);
            for(int i=1;i<=4;++i)mouse(QEvent::MouseMove,at(0.3+0.1*i,0.5+0.0075*i),Qt::NoButton,Qt::LeftButton,Qt::ControlModifier);
            if(!capture("crop-straighten-line"))return;
            mouse(QEvent::MouseButtonRelease,at(0.7,0.53),Qt::LeftButton,Qt::NoButton,Qt::ControlModifier);
            const double held=state->property("draftStraighten").toDouble();
            checks_["crop_line_straighten"]=held;
            if(!require(expected&&std::abs(held-std::round(*expected*10)/10)<1e-9&&std::abs(held)>1&&
                        window_.property("cropMode").toBool(),"crop_line_sets_straighten"))return;
            QMetaObject::invokeMethod(state,"finishCrop");
            const auto committed=controller_.cropRect();
            if(!require(!window_.property("cropMode").toBool()&&std::abs(committed.x()-moved.x())<1e-9&&
                        std::abs(committed.width()-moved.width())<1e-9&&std::abs(controller_.straightenDegrees()-held)<1e-9,
                        "crop_editor_commits_grips_and_line"))return;
            later([this]{
                if(!require(canvas_->image().cacheKey()==controller_.previewImage().cacheKey(),"cropped_straightened_canvas_matches_output")||
                   !capture("crop-committed"))return;
                finish(true,{});
            });
        });
    }
    void finish(bool success,const QString& error) {
        if(done_)return;done_=true;
        checks_["passed"]=success;checks_["error"]=error;
        checks_["elapsed_ms"]=double(elapsed_.elapsed());checks_["harness_hash_ms"]=harnessHashMs;
        checks_["qt_version"]=QString(qVersion());checks_["platform"]=QGuiApplication::platformName();
        checks_["quick_backend_requested"]=qEnvironmentVariable("QT_QUICK_BACKEND");
        checks_["slide_results"]=slide_results_;
        checks_["frame_publications"]=frame_publications_;checks_["operations_finished"]=operations_finished_;
        checks_["scope"]="QML scene, controller, native Vulkan renderer and file writer; not physical display calibration or native dialog automation";
        QFile report(output_+"/report.json");if(report.open(QIODevice::WriteOnly))report.write(QJsonDocument(checks_).toJson());
        QCoreApplication::exit(success?0:1);
    }
    PreviewController& controller_;QQuickWindow& window_;FrameCanvas* canvas_=nullptr;
    QString input_,reject_,output_,requested_space_;std::vector<std::uint16_t> original_rows_;std::shared_ptr<std::atomic_bool> fail_display_;
    QElapsedTimer elapsed_;
    spk::desktop::FramePtr original_,held_;QJsonObject checks_;int stage_=0;bool done_=false;
    int frame_publications_=0,operations_finished_=0,saved_publications_=0,saved_operations_=0;
    int remembered_paper_=0,negative_film_=0,slide_index_=0;double remembered_ev_=0;
    std::string film_paper_;
    const QStringList slide_ids_{"fujifilm_provia_100f","fujifilm_velvia_100","kodak_ektachrome_100","kodak_kodachrome_64"};
    QJsonArray slide_results_;
    QStringList exported_;
    QElapsedTimer dialog_checks_;
    bool headroom_slides_=false;
    QImage capture_;
};

// Where the per-photo edits go when a run overrides them: the self-test's
// own directory, --edit-store, a snapshot's sibling directory; empty for the
// default (AppLocalDataLocation/Edits). The app preferences follow it
// (AppSettings::resolveFilePath), so a test never touches the user's.
QString editDirectoryFor(const QString& selfTest,const QString& editStore,const QString& snapshot) {
    if(!selfTest.isEmpty())return QDir(selfTest).absoluteFilePath("edits");
    if(!editStore.isEmpty())return QFileInfo(editStore).absoluteFilePath();
    if(!snapshot.isEmpty())return QFileInfo(snapshot).absoluteFilePath()+"-edits";
    return {};
}
// An option's value read from argv before QGuiApplication (and its parser)
// exists: "--name value", "--name=value", or with one dash, as the parser
// accepts them.
QString earlyOption(int argc,char** argv,const char* name) {
    const QString longName=QString::fromLatin1(name);
    for(int i=1;i<argc;++i) {
        QString arg=QString::fromLocal8Bit(argv[i]);
        if(arg.startsWith("--"))arg.remove(0,2);else if(arg.startsWith('-'))arg.remove(0,1);else continue;
        if(arg==longName&&i+1<argc)return QString::fromLocal8Bit(argv[i+1]);
        if(arg.startsWith(longName+'='))return arg.mid(longName.size()+1);
    }
    return {};
}
}

int main(int argc,char** argv) {
    // The Windows offscreen plugin uses a file font database instead of the
    // native DirectWrite one. Reuse installed system fonts for the explicit
    // test platform; no fonts are copied or bundled with the application.
    if(qEnvironmentVariable("QT_QPA_PLATFORM")=="offscreen"&&qEnvironmentVariableIsEmpty("QT_QPA_FONTDIR"))
        qputenv("QT_QPA_FONTDIR",(qEnvironmentVariable("WINDIR")+"/Fonts").toUtf8());
    // Preserve Qt diagnostics when launched by a validation runner with
    // redirected stderr, even though the production executable has no console.
    qInstallMessageHandler([](QtMsgType type,const QMessageLogContext& context,const QString& message){
        ShellCapture::noteMessage(type,context,message);
        const auto bytes=qFormatLogMessage(type,context,message).toUtf8();
        std::fwrite(bytes.data(),1,std::size_t(bytes.size()),stderr);std::fputc('\n',stderr);std::fflush(stderr);
    });
    // Before the application object, so AppLocalDataLocation is known to the
    // early read of the preferences below.
    QCoreApplication::setOrganizationName("SpektraLab");QCoreApplication::setApplicationName("SpektraLab Windows");
    // Settings > General > Scale (the Mac's InterfaceScale, Theme.swift): Qt
    // scales the whole window by QT_SCALE_FACTOR, which must be set before the
    // application exists -- so the choice applies at the next start, and an
    // explicit QT_SCALE_FACTOR in the environment wins.
    const QString earlySettings=AppSettings::resolveFilePath(earlyOption(argc,argv,"settings-file"),
        editDirectoryFor(earlyOption(argc,argv,"self-test"),earlyOption(argc,argv,"edit-store"),earlyOption(argc,argv,"snapshot")));
    AppInfo::Startup startup;
    startup.interfaceScaleFromEnvironment=!qEnvironmentVariableIsEmpty("QT_SCALE_FACTOR");
    startup.activeInterfaceScale=AppSettings::readValue(earlySettings,QStringLiteral("general.interfaceScale")).toString();
    if(!AppInfo::interfaceScales().contains(startup.activeInterfaceScale))startup.activeInterfaceScale=QStringLiteral("115");
    if(!startup.interfaceScaleFromEnvironment&&startup.activeInterfaceScale!=QLatin1String("115"))
        qputenv("QT_SCALE_FACTOR",QByteArray::number(AppInfo::scaleFactor(startup.activeInterfaceScale),'f',4));
    QGuiApplication app(argc,argv);
    QQuickStyle::setStyle("Basic");
    QCommandLineParser parser;parser.setApplicationDescription("SpektraLab Windows Qt Quick preview");parser.addHelpOption();
    parser.addOptions({{"resources","Engine resource directory","directory"},
                       {"open","Open a RAW file","file"},
                       {"snapshot","Save one rendered window capture to a new PNG and exit (requires --open)","file"},
                       {"edit-store","Override the per-photo edit directory (tests use an isolated directory)","directory"},
                       {"set","With --snapshot: set a settings row by wire name once the RAW is open (repeatable; "
                              "true/false, a number or text), and capture after it has developed","key=value"},
                       {"self-test","Run real RAW frontend checks and save a report in a NEW directory","directory"},
                       {"reject","Unsupported RAW for the failed-open check","file"},
                       {"settings-file","Use this app preferences file (default: beside the edit store)","file"}});
    // Testing only: capture the Settings and About windows into a NEW
    // directory and exit (ShellCapture.hpp).
    QCommandLineOption captureShell("capture-shell","Capture the Settings and About windows (testing)","directory");
    captureShell.setFlags(QCommandLineOption::HiddenFromHelp);
    parser.addOption(captureShell);
    // Testing only, so hidden: ask sessions for another output space (e.g.
    // "ProPhoto RGB") to exercise the tagging path before the app switches.
    QCommandLineOption outputSpace("output-color-space","Engine output colour space to request (testing)","name");
    outputSpace.setFlags(QCommandLineOption::HiddenFromHelp);
    parser.addOption(outputSpace);
    // Testing only: with --snapshot of a half-frame pair (--open <pair>.spkpair),
    // pick "first" or "second" before the capture, so the active hole shows.
    QCommandLineOption pairLayer("pair-layer","With --snapshot of a pair: the hole to pick (testing)","side");
    pairLayer.setFlags(QCommandLineOption::HiddenFromHelp);
    parser.addOption(pairLayer);
    parser.process(app);
    const QString requestedSpace=parser.isSet(outputSpace)?parser.value(outputSpace):
        QString::fromLatin1(spk::desktop::kDisplayOutputColorSpace);
    const auto resources=parser.isSet("resources")?parser.value("resources"):QCoreApplication::applicationDirPath()+"/resources";
    const bool testing=parser.isSet("self-test");
    const bool snapshot=parser.isSet("snapshot");
    if(snapshot&&(!parser.isSet("open")||testing||QFileInfo::exists(parser.value("snapshot"))))return 2;
    const auto testOutput=parser.value("self-test");
    if(testing&&(!parser.isSet("open")||!parser.isSet("reject")||QFileInfo::exists(testOutput)||!QDir().mkpath(testOutput)))return 2;
    QString testInput=parser.value("open"),testReject=parser.value("reject");
    if(testing){
        testInput=QDir(testOutput).absoluteFilePath("input."+QFileInfo(testInput).suffix());
        testReject=QDir(testOutput).absoluteFilePath("rejected."+QFileInfo(testReject).suffix());
        if(!QFile::copy(parser.value("open"),testInput)||!QFile::copy(parser.value("reject"),testReject))return 2;
    }
    const bool capturingShell=parser.isSet(captureShell);
    const auto shellOutput=parser.value(captureShell);
    if(capturingShell&&(testing||snapshot||QFileInfo::exists(shellOutput)||!QDir().mkpath(shellOutput)))return 2;
    const QString editDirectory=editDirectoryFor(testing?testOutput:QString(),parser.value("edit-store"),
                                                 snapshot?parser.value("snapshot"):QString());
    // Declared before the QML engine, so it outlives every binding that
    // writes to it; it flushes when destroyed.
    AppSettings appSettings(AppSettings::resolveFilePath(parser.value("settings-file"),editDirectory));
    startup.settingsFile=appSettings.filePath();
    startup.editDirectory=editDirectory.isEmpty()?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+"/Edits":editDirectory;
    AppInfo appInfo(startup);
    DisplaySettings displaySettings(appSettings);
    // Set on the GUI thread, consumed by the factory on the worker.
    auto failDisplay=std::make_shared<std::atomic_bool>(false);
    PreviewController controller(std::filesystem::path(resources.toStdWString()),nullptr,
        [failDisplay](const auto& frame){if(failDisplay->exchange(false))throw std::runtime_error("Injected display publication failure");return PreviewController::imageFromFrame(frame);},
        editDirectory,parser.isSet(outputSpace)?requestedSpace:QString());
    qmlRegisterType<FrameCanvas>("SpektraLab.Native",1,0,"FrameCanvas");
    // The crop grips' arithmetic and the held Space key (CanvasTools.hpp).
    CanvasTools canvasTools;
    qmlRegisterSingletonInstance("SpektraLab.Native",1,0,"CanvasTools",&canvasTools);
    // QML text by key (qml/L10n.qml): compiled-in tables, then <app>/i18n.
    Localizer localizer;localizer.loadStandardLocations();
    // Settings > General > Language, as the user left it (a language whose
    // table is gone falls back to English inside the Localizer).
    if(const auto language=appSettings.value("general.language").toString();!language.isEmpty())localizer.setLanguage(language);
    qmlRegisterSingletonInstance("SpektraLab.Native",1,0,"Localizer",&localizer);
    // The shell's state (AppSettings.hpp, AppShell.hpp): preferences, the
    // display colour management choice, and what the About window reports.
    qmlRegisterSingletonInstance("SpektraLab.Native",1,0,"AppSettings",&appSettings);
    qmlRegisterSingletonInstance("SpektraLab.Native",1,0,"DisplayColour",&displaySettings);
    qmlRegisterSingletonInstance("SpektraLab.Native",1,0,"AppInfo",&appInfo);
    // The controller's status lines (Messages.hpp) come from the same tables.
    // The Localizer is GUI-thread only, so a worker thread's call (the batch
    // summary) falls back to Messages.hpp's English.
    spk::desktop::messages::lookup()=[&localizer](std::string_view key,const QStringList& args)->QString{
        if(QThread::currentThread()!=localizer.thread())return {};
        QVariantList values;for(const auto& arg:args)values.push_back(arg);
        return localizer.translate(QString::fromUtf8(key.data(),qsizetype(key.size())),values);
    };
    // Declared after the Localizer, so destroyed first: the controller outlives
    // both and may still produce a status line while it shuts down.
    struct ClearLookup{~ClearLookup(){spk::desktop::messages::lookup()=nullptr;}} clearLookup;
    // The export page's recipes: export-recipes.json beside app-settings.json
    // (<AppLocalData>, the --edit-store / test directory, or --settings-file's).
    ExportRecipeStore exportRecipes(QFileInfo(appSettings.filePath()).absoluteDir().filePath(QStringLiteral("export-recipes.json")));
    QQmlApplicationEngine engine;engine.rootContext()->setContextProperty("preview",&controller);
    engine.rootContext()->setContextProperty("exportRecipes",&exportRecipes);
    QObject::connect(&engine,&QQmlApplicationEngine::objectCreationFailed,&app,[]{QCoreApplication::exit(2);},Qt::QueuedConnection);
    engine.loadFromModule("SpektraLab","Main");
    if(engine.rootObjects().isEmpty())return 2;
    // The stored display choice on the editor window's pipeline before its
    // first frame (and before the self-test sets its own dither below).
    displaySettings.attach(qobject_cast<QQuickWindow*>(engine.rootObjects().first()));
    QObject::connect(&app,&QCoreApplication::aboutToQuit,&appSettings,[&appSettings]{appSettings.flush();});
    canvasTools.watch(qobject_cast<QQuickWindow*>(engine.rootObjects().first()));
    std::unique_ptr<SelfTest> test;
    std::unique_ptr<ShellCapture> shellCapture;
    if(capturingShell) {
        auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
        shellCapture=std::make_unique<ShellCapture>(*window,QDir(shellOutput).absolutePath());
    } else if(testing) {
        auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
        test=std::make_unique<SelfTest>(controller,*window,testInput,testReject,testOutput,failDisplay,requestedSpace);
    } else if(parser.isSet("open")) {
        if(snapshot) {
            auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
            const auto destination=parser.value("snapshot");
            const auto sets=parser.values("set");
            const auto capture=[window,destination]{
                QTimer::singleShot(250,window,[window,destination]{
                    QFile file(destination);const auto scene=window->grabWindow();
                    const bool saved=!scene.isNull()&&file.open(QIODevice::WriteOnly|QIODevice::NewOnly)&&scene.save(&file,"PNG")&&file.flush();
                    QCoreApplication::exit(saved?0:1);
                });
            };
            const auto layer=parser.value(pairLayer);
            QObject::connect(&controller,&PreviewController::operationFinished,&app,[&controller,sets,capture,layer](const QString& operation,bool ok){
                if(!ok){QCoreApplication::exit(1);return;}
                if(operation=="open"&&!layer.isEmpty())controller.setPairLayer(layer);
                if(operation=="open"&&!sets.isEmpty()) {
                    // --set: each row as the sections would set it; the
                    // capture waits for the frame they develop.
                    for(const auto& entry:sets) {
                        const auto eq=entry.indexOf('=');
                        const auto key=entry.left(eq),text=eq<0?QString():entry.mid(eq+1);
                        bool number=false;const double value=text.toDouble(&number);
                        const QVariant v=text=="true"?QVariant(true):text=="false"?QVariant(false):number?QVariant(value):QVariant(text);
                        if(eq<=0||!controller.setParameter(key,v)){QCoreApplication::exit(1);return;}
                    }
                    controller.apply();
                    return;
                }
                if((operation=="open"&&sets.isEmpty())||(operation=="render"&&!controller.dirty()))capture();
            });
            QTimer::singleShot(60000,&app,[]{QCoreApplication::exit(1);});
        }
        QObject::connect(&controller,&PreviewController::initialized,&app,[&](bool ok){if(ok)controller.openRaw(QUrl::fromLocalFile(parser.value("open")));});
    }
    return app.exec();
}
