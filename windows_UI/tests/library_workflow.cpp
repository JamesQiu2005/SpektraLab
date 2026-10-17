// Real controller + RAW + Vulkan integration. No QML clicks are simulated;
// the UI uses these same slots. Unit geometry/writer cases live separately.
#include "PreviewController.hpp"
#include "FrameOutput.hpp"
#include "RecipeExport.hpp"
#include "display_checks.hpp"
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>   // CreateHardLinkW: the large folder's frames
#endif

namespace {
namespace output=spk::desktop::output;
int checks=0;
void check(bool ok,const QString& message) {
    ++checks;
    if(!ok)throw std::runtime_error(message.toUtf8().toStdString());
}
std::filesystem::path nativePath(const QString& value) {
#ifdef _WIN32
    return std::filesystem::path(value.toStdWString());
#else
    return std::filesystem::path(value.toStdString());
#endif
}
QString sourcePath(const PreviewController& controller) {
    return controller.frame()?QString::fromStdWString(controller.frame()->source.wstring()):QString();
}
void waitFor(const std::function<bool()>& condition,const QString& description) {
    if(condition())return;
    QEventLoop loop;
    QTimer poll,deadline;
    poll.setInterval(10);deadline.setSingleShot(true);
    QObject::connect(&poll,&QTimer::timeout,&loop,[&]{if(condition())loop.quit();});
    QObject::connect(&deadline,&QTimer::timeout,&loop,&QEventLoop::quit);
    poll.start();deadline.start(180000);loop.exec();
    check(condition(),"Timed out waiting for "+description);
}
void idle(PreviewController& controller,const QString& description,bool allowFailure=false) {
    waitFor([&]{return !controller.busy()&&!controller.dirty()&&!controller.batchExporting()&&controller.pictureSettled();},description);
    check(allowFailure||!controller.failed(),description+": "+controller.status());
}
// Displayed images are half floats: compared exactly, format and tag included.
using display_checks::sameImage;
output::Geometry geometryOf(const PreviewController& controller) {
    return {controller.cropRect(),controller.quarterTurns(),controller.flipHorizontal(),
            controller.flipVertical(),controller.straightenDegrees()};
}
// An 8-bit file against what was on screen, two ways: exactly the export
// path's quantisation of the engine frame the display came from, and
// consistent with every displayed half float (display_checks.hpp).
struct Shown {
    QImage image;
    spk::desktop::FramePtr frame;
    output::Geometry geometry;
};
Shown shown(const PreviewController& controller) {
    return {controller.previewImage().copy(),controller.frame(),geometryOf(controller)};
}
qint64 ambiguousSamples=0;
// The session renders the ProPhoto working space and the legacy export writes
// sRGB: the file is the shown frame converted once (display_checks::
// expectedFile with the export's conversion), and the displayed half floats
// are that same frame's own codes.
display_checks::ToSrgb toSrgb;
bool fileShows(const QImage& file,const Shown& expected,const display_checks::ExportDisplayAgreement& agreement) {
    if(!display_checks::sameRgb8(file,display_checks::expected8(expected.frame,expected.geometry,toSrgb)))return false;
    const auto result=agreement.compare(display_checks::frame8(expected.frame,expected.geometry),expected.image);
    ambiguousSamples+=result.ambiguous;
    return result.samples==qint64(file.width())*file.height()*3&&result.disagreements==0;
}
QByteArray fileHash(const QString& path) {
    QFile file(path);check(file.open(QIODevice::ReadOnly),"Cannot read "+path);
    QCryptographicHash hash(QCryptographicHash::Sha256);
    check(hash.addData(&file),"Cannot hash "+path);return hash.result().toHex();
}
QImage readImage(const QString& path) {
    QImageReader reader(path);auto image=reader.read();
    check(!image.isNull(),"Cannot decode exported image: "+reader.errorString());
    return image;
}
void checkCurrent(const PreviewController& controller,int index,const QString& expected) {
    check(controller.activeIndex()==index,"Library index disagrees with displayed source");
    check(QFileInfo(sourcePath(controller)).canonicalFilePath()==QFileInfo(expected).canonicalFilePath(),
          "Displayed engine frame came from a different library item");
    const auto items=controller.libraryItems();
    check(index>=0&&index<items.size(),"Active library item is missing");
    check(items[index].toMap().value("active").toBool(),"Library active marker disagrees with controller");
}
}

int main(int argc,char** argv) {
    qputenv("QT_QPA_PLATFORM",QByteArray("offscreen"));
    QGuiApplication application(argc,argv);
    QJsonObject report;
    QString destination;
    QElapsedTimer duration;duration.start();
    try {
        const auto args=application.arguments();
        if(args.size()!=5)throw std::runtime_error("usage: spk_library_workflow_test <resources> <RAW> <rejected-RAW> <new-output-directory>");
        const auto resources=nativePath(args[1]);
        const QFileInfo original(args[2]),rejected(args[3]);
        destination=QFileInfo(args[4]).absoluteFilePath();
        check(original.isFile()&&rejected.isFile(),"Both RAW fixture paths must exist");
        check(!QFileInfo::exists(destination),"Output directory must be new");
        check(QDir().mkpath(destination+"/fixtures"),"Cannot create fixture directory");
        const QString first=destination+"/fixtures/alpha."+original.suffix();
        const QString second=destination+"/fixtures/beta."+original.suffix();
        check(QFile::copy(original.absoluteFilePath(),first)&&QFile::copy(original.absoluteFilePath(),second),
              "Cannot make independent fixture copies");
        QJsonArray operations;
        const display_checks::ExportDisplayAgreement agreement;
        // The export's own conversion, on an engine of the test's: what the
        // legacy export does to a ProPhoto frame before the sRGB writers.
        struct Engine{spk_engine* e;~Engine(){if(e)spk_engine_destroy(e);}} engine{spk_engine_create(args[1].toUtf8().constData(),nullptr)};
        check(engine.e!=nullptr,"test engine");
        toSrgb=[e=engine.e](const QImage& rgba64,const spk::desktop::OutputEncoding& from){
            return spk::desktop::exporting::convert(rgba64,from,"sRGB",e).rgba64;
        };
        {
            PreviewController controller(resources,nullptr,{},destination+"/edits");
            QObject::connect(&controller,&PreviewController::operationFinished,&controller,
                             [&](const QString& operation,bool success){
                operations.append(QJsonObject{{"operation",operation},{"success",success},{"status",controller.status()}});
            });
            waitFor([&]{return controller.ready()||controller.failed();},"engine initialization");
            check(controller.ready(),"Engine initialization: "+controller.status());
            controller.openFiles({QUrl::fromLocalFile(first),QUrl::fromLocalFile(second)});
            idle(controller,"multiple-file import");
            check(controller.libraryItems().size()==2&&controller.selectedCount()==2,
                  "Multiple-file import did not create two selected items");
            checkCurrent(controller,0,first);
            // The working space: every 8-bit file below is a conversion.
            check(controller.frame()->encoding.color_space=="ProPhoto RGB"&&controller.frame()->encoding.cctf_encoding,
                  "The session does not render encoded ProPhoto RGB");
            check(!controller.previewImage().isNull(),"Imported frame has no preview");

            // Leave settings in the 180 ms debounce window, then switch. The
            // first item must retain wanted edits, not its older shown frame.
            controller.setAdjustment("grainActive",false);
            controller.setAdjustment("glareActive",false);
            controller.setAdjustment("filmExposureEv",0.5);
            check(controller.dirty(),"Pending adjustment did not mark the photograph dirty");
            controller.selectImage(1);idle(controller,"select second while first edits are pending");
            checkCurrent(controller,1,second);
            check(controller.adjustments().value("grainActive").toBool()&&
                  controller.adjustments().value("glareActive").toBool()&&
                  controller.adjustments().value("filmExposureEv").toDouble()==0,
                  "A new photograph inherited another photograph's pending settings");
            const QRectF cropB(0.3,0.2,0.5,0.5);
            controller.setCropRect(cropB);
            check(controller.cropRect()==cropB,"Second photograph did not accept its crop");
            controller.selectImage(0);idle(controller,"restore first pending adjustments");
            checkCurrent(controller,0,first);
            check(!controller.adjustments().value("grainActive").toBool()&&
                  !controller.adjustments().value("glareActive").toBool()&&
                  controller.adjustments().value("filmExposureEv").toDouble()==0.5,
                  "Switching photographs discarded pending adjustments");
            const QRectF cropA(0.1,0.1,0.8,0.8);
            const auto uncropped=controller.uncroppedImage();
            const auto fullFrame=controller.frame();
            controller.setCropRect(cropA);
            check(controller.frame()==fullFrame&&!controller.busy(),"Crop unnecessarily re-rendered the film");
            // The cropped picture is made off the GUI thread and lands later.
            waitFor([&]{return controller.pictureSettled();},"the cropped picture");
            check(sameImage(controller.previewImage(),uncropped.copy(output::cropPixels(uncropped.size(),cropA))),
                  "Crop preview disagrees with the original frame's pixel rectangle");
            check(controller.previewImage().format()==QImage::Format_RGBX16FPx4&&
                  controller.previewImage().colorSpace()==spk::desktop::display::colorSpace(fullFrame->encoding),
                  "Crop preview is not the frame's half floats in its own colour space");
            const auto cropped=controller.previewImage();
            for(const auto invalid : {QRectF(0,0,0,1),QRectF(-0.1,0,1,1),QRectF(0.8,0,0.5,1),
                                      QRectF(0,0,std::numeric_limits<double>::quiet_NaN(),1)}) {
                controller.setCropRect(invalid);
                check(controller.cropRect()==cropA&&sameImage(controller.previewImage(),cropped),
                      "Invalid crop changed the visible photograph");
            }
            controller.setExposureEv(0.75);
            controller.selectImage(1);idle(controller,"save pending first-photo print exposure");
            check(controller.exposureEv()==0&&controller.cropRect()==cropB,
                  "Switching leaked print exposure or lost independent crop");
            controller.selectImage(0);idle(controller,"restore first-photo print exposure");
            check(controller.exposureEv()==0.75&&controller.cropRect()==cropA,
                  "First photograph lost desired print exposure or crop");

            controller.selectAllPhotos(true);
            controller.syncSelectedSettings(); // defaults to excluding crop
            controller.selectImage(1);idle(controller,"synchronize selected settings");
            check(controller.exposureEv()==0.75&&
                  controller.adjustments().value("filmExposureEv").toDouble()==0.5&&
                  !controller.adjustments().value("grainActive").toBool()&&
                  !controller.adjustments().value("glareActive").toBool(),
                  "Synchronizing did not copy the source photograph's adjustments");
            check(controller.cropRect()==cropB,"Default synchronization copied crop geometry");
            controller.setExposureEv(-0.5);idle(controller,"independent second-photo brightness");
            const auto expectedB=shown(controller);
            controller.selectImage(0);idle(controller,"return to first photograph before export");
            check(controller.exposureEv()==0.75&&controller.cropRect()==cropA,
                  "Editing the second photograph mutated the first photograph");
            const auto expectedA=shown(controller);

            const QString single=destination+"/displayed.png";
            controller.exportImage(QUrl::fromLocalFile(single),1,95,0);
            idle(controller,"single cropped PNG export");
            check(fileShows(readImage(single),expectedA,agreement),"PNG8 pixels differ from the cropped displayed photograph");
            const auto originalHash=fileHash(single);
            const int beforeRefusal=operations.size();
            controller.exportImage(QUrl::fromLocalFile(single),1,95,0);
            idle(controller,"single-file overwrite refusal",true);
            check(operations.size()>beforeRefusal&&!operations.last().toObject().value("success").toBool(),
                  "An existing single export was not refused");
            check(fileHash(single)==originalHash,"Single export changed an existing file");
            check(sameImage(controller.previewImage(),expectedA.image),"Failed export changed the displayed frame");

            const QString png16=destination+"/small-16bit.png",jpeg=destination+"/small.jpg";
            controller.exportImage(QUrl::fromLocalFile(png16),2,95,128);
            idle(controller,"PNG16 export through controller");
            QFile pngFile(png16);check(pngFile.open(QIODevice::ReadOnly),"PNG16 export is missing");
            const auto header=pngFile.read(29);pngFile.close();
            check(header.size()==29&&header.left(8)==QByteArray::fromHex("89504e470d0a1a0a")&&
                  static_cast<unsigned char>(header[24])==16,"PNG16 controller option did not produce 16-bit PNG");
            const auto small16=readImage(png16);
            check(std::max(small16.width(),small16.height())==128,"PNG16 long-edge option was not applied");
            controller.exportImage(QUrl::fromLocalFile(jpeg),3,91,127);
            idle(controller,"JPEG export through controller");
            const auto smallJpeg=readImage(jpeg);
            check(std::max(smallJpeg.width(),smallJpeg.height())==127,"JPEG format/long-edge option was not applied");

            const QString batch=destination+"/batch";
            check(QDir().mkpath(batch),"Cannot create batch directory");
            controller.selectAllPhotos(true);
            controller.exportBatch(QUrl::fromLocalFile(batch),1,95,0);
            check(controller.batchExporting()&&controller.batchTotal()==2,"Batch did not hold both selected photographs");
            const int lockedIndex=controller.activeIndex(),lockedSelected=controller.selectedCount();
            const auto lockedCrop=controller.cropRect();
            const auto lockedAdjustments=controller.adjustments();
            const double lockedExposure=controller.exposureEv();
            controller.setExposureEv(-1.5);controller.setAdjustment("filmExposureEv",-2);
            controller.setCropRect(QRectF(0,0,0.5,0.5));controller.selectImage(1-lockedIndex);
            controller.setItemSelected(0,false);controller.selectAllPhotos(false);
            controller.openRaw(QUrl::fromLocalFile(rejected.absoluteFilePath()));
            controller.openFiles({QUrl::fromLocalFile(rejected.absoluteFilePath())});
            controller.syncSelectedSettings(true);
            check(controller.activeIndex()==lockedIndex&&controller.selectedCount()==lockedSelected&&
                  controller.cropRect()==lockedCrop&&controller.adjustments()==lockedAdjustments&&
                  controller.exposureEv()==lockedExposure&&controller.libraryItems().size()==2,
                  "A user edit/source/selection change escaped the batch lock");
            idle(controller,"batch of two independent photographs");
            check(controller.batchProgress()==2,"Batch did not report both completed photographs");
            const QString firstExport=batch+"/alpha.png",secondExport=batch+"/beta.png";
            check(fileShows(readImage(firstExport),expectedA,agreement),"Batch alpha filename contains the wrong photograph/settings/crop");
            check(fileShows(readImage(secondExport),expectedB,agreement),"Batch beta filename contains the wrong photograph/settings/crop");
            const auto firstHash=fileHash(firstExport),secondHash=fileHash(secondExport);

            // Batch's final development left beta in the worker, while the
            // editor still shows alpha. The next edit must reconcile that
            // source before rendering; otherwise beta acquires alpha's UI.
            checkCurrent(controller,0,first);
            const auto beforeBatchEdit=controller.frame();
            controller.setExposureEv(1.0);idle(controller,"edit displayed alpha after worker exported beta");
            checkCurrent(controller,0,first);
            check(controller.frame()!=beforeBatchEdit&&controller.exposureEv()==1.0&&
                  controller.frame()->settings.print_exposure==0.5&&controller.cropRect()==cropA,
                  "Post-batch edit did not publish alpha with its requested settings");
            check(!sameImage(controller.previewImage(),expectedA.image),"Post-batch brightness edit did not change alpha");
            controller.setExposureEv(0.75);idle(controller,"restore deterministic alpha after batch");
            checkCurrent(controller,0,first);
            check(sameImage(controller.previewImage(),expectedA.image),
                  "Restoring alpha after batch did not recover its deterministic pixels");

            controller.exportBatch(QUrl::fromLocalFile(batch),1,95,0);
            idle(controller,"skip existing batch destinations");
            check(fileHash(firstExport)==firstHash&&fileHash(secondExport)==secondHash,
                  "Repeat batch overwrote an existing destination");
            check(QDir(batch).entryList(QDir::Files|QDir::NoDotAndDotDot).size()==2,
                  "Repeat batch renamed existing files instead of skipping them");

            const QString cancelled=destination+"/cancelled";
            check(QDir().mkpath(cancelled),"Cannot create cancellation directory");
            controller.exportBatch(QUrl::fromLocalFile(cancelled),1,95,64);
            check(controller.batchExporting(),"Cancellation test did not start a batch");
            controller.cancelExport();
            idle(controller,"cancel batch between photographs",true);
            const auto cancelledFiles=QDir(cancelled).entryList(QDir::Files|QDir::NoDotAndDotDot);
            check(cancelledFiles.size()<=1,"Immediate cancellation continued to another photograph");
            for(const auto& file:cancelledFiles)check(!readImage(cancelled+"/"+file).isNull(),"Cancellation left an incomplete file");
            check(controller.settingsEditable(),"Cancellation did not release the editor");

            const auto lastFrame=controller.frame();
            const auto lastPreview=controller.previewImage();
            const int lastIndex=controller.activeIndex();
            const auto lastSource=sourcePath(controller);
            controller.openRaw(QUrl::fromLocalFile(rejected.absoluteFilePath()));
            idle(controller,"unsupported RAW preserves current photograph",true);
            check(controller.failed()&&controller.frame()==lastFrame&&sameImage(controller.previewImage(),lastPreview),
                  "Failed RAW import replaced the visible photograph");
            checkCurrent(controller,lastIndex,lastSource);

            // Failed imports remain explicit library items. A mixed batch
            // may write its supported files, but must report the bad item
            // and retain the editor's original immutable frame and index.
            check(controller.libraryItems().size()==3,"Rejected RAW was not retained as a diagnosable library item");
            controller.selectAllPhotos(true);
            check(controller.selectedCount()==3,"Mixed batch did not select all three library items");
            const QString mixed=destination+"/mixed-failure";
            check(QDir().mkpath(mixed),"Cannot create mixed batch directory");
            controller.exportBatch(QUrl::fromLocalFile(mixed),1,95,64);
            idle(controller,"batch containing supported and unsupported RAW files",true);
            check(controller.failed()&&controller.status().contains(QStringLiteral("1 failed"))&&
                  controller.status().contains(rejected.completeBaseName()),
                  "Mixed batch concealed the unsupported RAW failure");
            check(controller.batchProgress()==3,"Mixed batch did not account for every selected file");
            check(controller.frame()==lastFrame&&sameImage(controller.previewImage(),lastPreview),
                  "Mixed batch failure replaced the editor's displayed photograph");
            checkCurrent(controller,lastIndex,lastSource);
            for(const auto& name : {QStringLiteral("alpha.png"),QStringLiteral("beta.png")}) {
                const auto written=readImage(mixed+"/"+name);
                check(std::max(written.width(),written.height())==64,
                      "Mixed batch did not finish a supported photo at the requested size");
            }
            check(!QFileInfo::exists(mixed+"/"+rejected.completeBaseName()+".png")&&
                  QDir(mixed).entryList(QDir::Files|QDir::NoDotAndDotDot).size()==2,
                  "Mixed batch published an output or partial file for rejected RAW");
            report.insert("mixed_failure_status",controller.status());
            report.insert("alpha_png_sha256",QString::fromLatin1(firstHash));
            report.insert("beta_png_sha256",QString::fromLatin1(secondHash));
            report.insert("cancelled_files",cancelledFiles.size());
            report.insert("export_display_ambiguous_samples",double(ambiguousSamples));
        }
        // ---- A large folder: 300 photographs (hard links to one fixture, so
        // no disk is spent). The import call returns quickly, the GUI thread
        // is never held long while every file's own preview arrives, and the
        // first photograph opens ----
        {
            const QString big=destination+"/big";
            check(QDir().mkpath(big),"Cannot create the large folder");
            constexpr int count=300;
            for(int i=0;i<count;++i) {
                const QString link=QStringLiteral("%1/frame_%2.%3").arg(big).arg(i,3,10,QChar('0')).arg(original.suffix());
                const auto target=QDir::toNativeSeparators(first).toStdWString(),name=QDir::toNativeSeparators(link).toStdWString();
                check(CreateHardLinkW(name.c_str(),target.c_str(),nullptr)!=0,"Cannot hard-link a large-folder frame");
            }
            PreviewController controller(resources,nullptr,{},destination+"/big-edits");
            waitFor([&]{return controller.ready()||controller.failed();},"engine initialization for the large folder");
            // The longest the event loop goes without running, from a 5 ms
            // timer's late arrivals.
            qint64 worstGap=0;QElapsedTimer tick;QTimer probe;probe.setInterval(5);
            QObject::connect(&probe,&QTimer::timeout,[&]{worstGap=std::max(worstGap,tick.restart());});
            QElapsedTimer clock;clock.start();
            controller.openFiles({QUrl::fromLocalFile(big)});
            const double importMs=double(clock.elapsed());
            check(controller.libraryCount()==count,"The large folder lists every photograph");
            tick.start();probe.start();
            waitFor([&]{return controller.previewsPending()==0&&!controller.busy();},"every preview of the large folder");
            probe.stop();
            const double allMs=double(clock.elapsed());
            int previews=0;
            for(int i=0;i<count;++i)previews+=!controller.libraryItem(i).value("strip").value<QImage>().isNull();
            std::cout<<"large folder: "<<count<<" photographs listed in "<<importMs<<" ms, every preview in "<<allMs
                     <<" ms, longest GUI stall meanwhile "<<worstGap<<" ms\n";
            report.insert("large_folder_import_ms",importMs);
            report.insert("large_folder_previews_ms",allMs);
            report.insert("large_folder_worst_stall_ms",double(worstGap));
            check(previews==count,"Every photograph of the large folder has its own preview");
            check(controller.frame()&&controller.activeIndex()==0,"The large folder's first photograph opens");
            check(importMs<1500,"The large folder is listed without holding the GUI thread");
            check(worstGap<400,"The GUI thread is never held long while the large folder's previews arrive");
        }
        report.insert("operations",operations);
        report.insert("status","passed");
        report.insert("checks",checks);
        report.insert("elapsed_ms",double(duration.elapsed()));
        report.insert("limits","Controller/RAW/Vulkan integration in offscreen Qt; not a native dialog or visible-window interaction test.");
        QFile reportFile(destination+"/library-workflow.json");
        check(reportFile.open(QIODevice::WriteOnly|QIODevice::NewOnly),"Cannot create workflow report");
        const auto bytes=QJsonDocument(report).toJson(QJsonDocument::Indented);
        check(reportFile.write(bytes)==bytes.size()&&reportFile.flush(),"Cannot finish workflow report");
        std::cout<<"Library workflow: "<<checks<<" checks passed\n";
        return 0;
    } catch(const std::exception& error) {
        report.insert("status","failed");report.insert("checks",checks);report.insert("error",QString::fromUtf8(error.what()));
        if(!destination.isEmpty()) {
            QFile file(destination+"/failure.json");
            if(file.open(QIODevice::WriteOnly|QIODevice::NewOnly))file.write(QJsonDocument(report).toJson());
        }
        std::cerr<<error.what()<<'\n';return 1;
    }
}
