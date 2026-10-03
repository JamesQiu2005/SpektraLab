#include "PreviewController.hpp"
#include "FrameCanvas.hpp"
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
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
            [this](const QString& operation,bool ok){step(operation,ok);});
        QTimer::singleShot(180000,this,[this]{if(!done_)finish(false,"timeout");});
    }
private:
    bool require(bool value,const QString& name) {
        checks_[name]=value;if(!value){finish(false,name+": "+controller_.status());return false;}return true;
    }
    void later(std::function<void()> action){QTimer::singleShot(180,this,[this,action=std::move(action)]{if(!done_)action();});}
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
            stage_=2;controller_.setExposureEv(0.5);controller_.apply();
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
            stage_=7;controller_.setFilmIndex((controller_.filmIndex()+1)%controller_.films().size());controller_.apply();
        } else if(stage_==7) {
            if(!require(operation=="render"&&ok&&!controller_.frame()->reprint()&&
                        controller_.frame()->settings.film_stock!=held_->settings.film_stock,"film_change_renders_selected_stock"))return;
            stage_=8;controller_.setPaperIndex((controller_.paperIndex()+1)%controller_.papers().size());controller_.apply();
        } else if(stage_==8) {
            if(!require(operation=="render"&&ok&&controller_.frame()->reprint()&&
                        controller_.frame()->settings.print_stock!=held_->settings.print_stock,"paper_change_reprints_selected_stock"))return;
            later([this]{if(capture("final"))finish(true,{});});
        }
    }
    void finish(bool success,const QString& error) {
        if(done_)return;done_=true;
        checks_["passed"]=success;checks_["error"]=error;
        checks_["qt_version"]=QString(qVersion());checks_["platform"]=QGuiApplication::platformName();
        checks_["quick_backend_requested"]=qEnvironmentVariable("QT_QUICK_BACKEND");
        checks_["scope"]="QML scene, controller, native Vulkan renderer and file writer; not physical display calibration or native dialog automation";
        QFile report(output_+"/report.json");if(report.open(QIODevice::WriteOnly))report.write(QJsonDocument(checks_).toJson());
        QCoreApplication::exit(success?0:1);
    }
    PreviewController& controller_;QQuickWindow& window_;FrameCanvas* canvas_=nullptr;
    QString input_,reject_,output_,original_hash_;std::shared_ptr<bool> fail_display_;
    spk::desktop::FramePtr original_,held_;QJsonObject checks_;int stage_=0;bool done_=false;
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
                       {"self-test","Run real RAW frontend checks and save a report in a NEW directory","directory"},
                       {"reject","Unsupported RAW for the failed-open check","file"}});
    parser.process(app);
    const auto resources=parser.isSet("resources")?parser.value("resources"):QCoreApplication::applicationDirPath()+"/resources";
    const bool testing=parser.isSet("self-test");
    const auto testOutput=parser.value("self-test");
    if(testing&&(!parser.isSet("open")||!parser.isSet("reject")||QFileInfo::exists(testOutput)||!QDir().mkpath(testOutput)))return 2;
    auto failDisplay=std::make_shared<bool>(false);
    PreviewController controller(std::filesystem::path(resources.toStdWString()),nullptr,
        [failDisplay](const auto& frame){if(*failDisplay){*failDisplay=false;throw std::runtime_error("Injected display publication failure");}return PreviewController::imageFromFrame(frame);});
    qmlRegisterType<FrameCanvas>("SpektraLab.Native",1,0,"FrameCanvas");
    QQmlApplicationEngine engine;engine.rootContext()->setContextProperty("preview",&controller);
    QObject::connect(&engine,&QQmlApplicationEngine::objectCreationFailed,&app,[]{QCoreApplication::exit(2);},Qt::QueuedConnection);
    engine.loadFromModule("SpektraLab","Main");
    if(engine.rootObjects().isEmpty())return 2;
    std::unique_ptr<SelfTest> test;
    if(testing) {
        auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first());if(!window)return 2;
        test=std::make_unique<SelfTest>(controller,*window,parser.value("open"),parser.value("reject"),testOutput,failDisplay);
    } else if(parser.isSet("open")) {
        QObject::connect(&controller,&PreviewController::initialized,&app,[&](bool ok){if(ok)controller.openRaw(QUrl::fromLocalFile(parser.value("open")));});
    }
    return app.exec();
}
