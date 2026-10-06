#include "PreviewController.hpp"
#include "FrameCanvas.hpp"
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QMouseEvent>
#include <QStringList>
#include <QTimer>
#include <cmath>
#include <cstdio>
#include <memory>

namespace {
QString fingerprint(const spk::desktop::FramePtr& frame) {
    if(!frame)return {};
    return QString::fromLatin1(QCryptographicHash::hash(
        QByteArrayView(reinterpret_cast<const char*>(frame->bgra8.data()),qsizetype(frame->bgra8.size())),
        QCryptographicHash::Sha256).toHex());
}

// This is an actual QML/controller/engine test with saved window captures. It
// deliberately makes no claim about physical monitor colour management or
// native file-dialog interaction; those need a separate interactive gate.
class SelfTest final:public QObject {
public:
    SelfTest(PreviewController& controller,QQuickWindow& window,QString input,QString reject,
             QString output,std::shared_ptr<bool> failDisplay)
        :controller_(controller),window_(window),input_(std::move(input)),reject_(std::move(reject)),
         output_(std::move(output)),fail_display_(std::move(failDisplay)) {
        canvas_=window_.findChild<FrameCanvas*>("frameCanvas");
        QObject::connect(&controller_,&PreviewController::initialized,this,[this](bool ok){
            if(!require(ok,"engine_init"))return;
            if(!require(canvas_!=nullptr,"canvas_found"))return;
            controller_.openRaw(QUrl::fromLocalFile(input_));
        });
        QObject::connect(&controller_,&PreviewController::operationFinished,this,
            [this](const QString& operation,bool ok){++operations_finished_;step(operation,ok);});
        QObject::connect(&controller_,&PreviewController::frameChanged,this,[this]{++frame_publications_;});
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
    void step(const QString& operation,bool ok) {
        if(done_)return;
        if(stage_==0) {
            if(!require(operation=="open"&&ok&&controller_.hasFrame(),"open_raw"))return;
            original_=controller_.frame();original_hash_=fingerprint(original_);
            checks_["width"]=int(original_->width());checks_["height"]=int(original_->height());
            checks_["film_count"]=controller_.films().size();checks_["paper_count"]=controller_.papers().size();
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
                    // this frame at one physical pixel per source pixel.
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
            stage_=2;controller_.setExposureEv(0.5);
            controller_.setDialogOpen(true);
            later([this]{
                if(!require(!controller_.busy()&&!controller_.settingsEditable()&&controller_.dirty()&&
                            controller_.frame()==original_,"file_dialog_suspends_pending_preview"))return;
                controller_.setExposureEv(1);
                if(!require(controller_.exposureEv()==0.5,"file_dialog_holds_selected_settings"))return;
                controller_.setDialogOpen(false);
            },400);
            QTimer::singleShot(5000,this,[this]{if(!done_&&stage_==2)finish(false,"automatic brightness preview did not run");});
        } else if(stage_==2) {
            if(!require(operation=="render"&&ok&&controller_.frame()!=original_&&controller_.frame()->reprint(),"brightness_reprint"))return;
            if(!require(fingerprint(original_)==original_hash_,"old_frame_immutable"))return;
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
            if(!require(fingerprint(original_)==original_hash_,"held_frame_still_immutable"))return;
            const int negative=filmIndex("kodak_ektar_100");
            if(!require(negative>=0,"negative_test_stock_in_catalog"))return;
            stage_=7;controller_.setFilmIndex(negative);
        } else if(stage_==7) {
            if(!require(operation=="render"&&ok&&!controller_.frame()->reprint()&&
                        controller_.frame()->settings.film_stock!=held_->settings.film_stock,"film_change_renders_selected_stock"))return;
            stage_=8;controller_.setPaperIndex((controller_.paperIndex()+1)%controller_.papers().size());
        } else if(stage_==8) {
            if(!require(operation=="render"&&ok&&controller_.frame()->reprint()&&
                        controller_.frame()->settings.print_stock!=held_->settings.print_stock,"paper_change_reprints_selected_stock"))return;
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
                    {"display_sha256",fingerprint(controller_.frame())},{"render_ms",controller_.frame()->timings.render_ms},
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
            if(!require(operation=="render"&&ok&&controller_.frame()->settings.film_stock=="kodak_portra_400"&&
                        controller_.frame()->settings.print_stock=="kodak_portra_endura"&&exposureIs(0)&&
                        !controller_.frame()->scan_film&&controller_.decodeMode()==0&&!controller_.dirty(),
                        "reset_settings_automatically_updates_preview"))return;
            if(!require(fingerprint(original_)==original_hash_,"original_frame_immutable_after_all_auto_edits"))return;
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
                        auto pointer=[this](QEvent::Type type,QPointF point,Qt::MouseButton button,Qt::MouseButtons buttons){
                            QMouseEvent event(type,point,point,window_.mapToGlobal(point.toPoint()),button,buttons,Qt::NoModifier);
                            QCoreApplication::sendEvent(&window_,&event);
                        };
                        pointer(QEvent::MouseButtonPress,start,Qt::LeftButton,Qt::LeftButton);
                        pointer(QEvent::MouseMove,end,Qt::NoButton,Qt::LeftButton);
                        pointer(QEvent::MouseButtonRelease,end,Qt::LeftButton,Qt::NoButton);
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
                                    finish(true,{});
                                });
                            });
                        });
                    });
                });
            });
        } else {
            require(false,"unexpected_operation_during_settle");
        }
    }
    void finish(bool success,const QString& error) {
        if(done_)return;done_=true;
        checks_["passed"]=success;checks_["error"]=error;
        checks_["qt_version"]=QString(qVersion());checks_["platform"]=QGuiApplication::platformName();
        checks_["quick_backend_requested"]=qEnvironmentVariable("QT_QUICK_BACKEND");
        checks_["slide_results"]=slide_results_;
        checks_["frame_publications"]=frame_publications_;checks_["operations_finished"]=operations_finished_;
        checks_["scope"]="QML scene, controller, native Vulkan renderer and file writer; not physical display calibration or native dialog automation";
        QFile report(output_+"/report.json");if(report.open(QIODevice::WriteOnly))report.write(QJsonDocument(checks_).toJson());
        QCoreApplication::exit(success?0:1);
    }
    PreviewController& controller_;QQuickWindow& window_;FrameCanvas* canvas_=nullptr;
    QString input_,reject_,output_,original_hash_;std::shared_ptr<bool> fail_display_;
    spk::desktop::FramePtr original_,held_;QJsonObject checks_;int stage_=0;bool done_=false;
    int frame_publications_=0,operations_finished_=0,saved_publications_=0,saved_operations_=0;
    int remembered_paper_=0,negative_film_=0,slide_index_=0;double remembered_ev_=0;
    const QStringList slide_ids_{"fujifilm_provia_100f","fujifilm_velvia_100","kodak_ektachrome_100","kodak_kodachrome_64"};
    QJsonArray slide_results_;
    bool headroom_slides_=false;
    QImage capture_;
};
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
        const auto bytes=qFormatLogMessage(type,context,message).toUtf8();
        std::fwrite(bytes.data(),1,std::size_t(bytes.size()),stderr);std::fputc('\n',stderr);std::fflush(stderr);
    });
    QGuiApplication app(argc,argv);
    app.setOrganizationName("SpektraLab");app.setApplicationName("SpektraLab Windows");
    QQuickStyle::setStyle("Basic");
    QCommandLineParser parser;parser.setApplicationDescription("SpektraLab Windows Qt Quick preview");parser.addHelpOption();
    parser.addOptions({{"resources","Engine resource directory","directory"},
                       {"open","Open a RAW file","file"},
                       {"snapshot","Save one rendered window capture to a new PNG and exit (requires --open)","file"},
                       {"edit-store","Override the per-photo edit directory (tests use an isolated directory)","directory"},
                       {"self-test","Run real RAW frontend checks and save a report in a NEW directory","directory"},
                       {"reject","Unsupported RAW for the failed-open check","file"}});
    parser.process(app);
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
    const QString editDirectory=testing?QDir(testOutput).absoluteFilePath("edits"):
        parser.isSet("edit-store")?QFileInfo(parser.value("edit-store")).absoluteFilePath():
        snapshot?QFileInfo(parser.value("snapshot")).absoluteFilePath()+"-edits":QString{};
    auto failDisplay=std::make_shared<bool>(false);
    PreviewController controller(std::filesystem::path(resources.toStdWString()),nullptr,
        [failDisplay](const auto& frame){if(*failDisplay){*failDisplay=false;throw std::runtime_error("Injected display publication failure");}return PreviewController::imageFromFrame(frame);},editDirectory);
    qmlRegisterType<FrameCanvas>("SpektraLab.Native",1,0,"FrameCanvas");
    QQmlApplicationEngine engine;engine.rootContext()->setContextProperty("preview",&controller);
    QObject::connect(&engine,&QQmlApplicationEngine::objectCreationFailed,&app,[]{QCoreApplication::exit(2);},Qt::QueuedConnection);
    engine.loadFromModule("SpektraLab","Main");
    if(engine.rootObjects().isEmpty())return 2;
    std::unique_ptr<SelfTest> test;
    if(testing) {
        auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
        test=std::make_unique<SelfTest>(controller,*window,testInput,testReject,testOutput,failDisplay);
    } else if(parser.isSet("open")) {
        if(snapshot) {
            auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
            const auto destination=parser.value("snapshot");
            QObject::connect(&controller,&PreviewController::operationFinished,&app,[window,destination](const QString& operation,bool ok){
                if(operation!="open")return;
                if(!ok){QCoreApplication::exit(1);return;}
                QTimer::singleShot(250,window,[window,destination]{
                    QFile file(destination);const auto scene=window->grabWindow();
                    const bool saved=!scene.isNull()&&file.open(QIODevice::WriteOnly|QIODevice::NewOnly)&&scene.save(&file,"PNG")&&file.flush();
                    QCoreApplication::exit(saved?0:1);
                });
            });
            QTimer::singleShot(60000,&app,[]{QCoreApplication::exit(1);});
        }
        QObject::connect(&controller,&PreviewController::initialized,&app,[&](bool ok){if(ok)controller.openRaw(QUrl::fromLocalFile(parser.value("open")));});
    }
    return app.exec();
}
