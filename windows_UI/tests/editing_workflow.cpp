// Actual RAW/Vulkan controller integration, with owned fixtures and a private
// edit store. This exercises user-visible edit history and reopened documents.
#include "PreviewController.hpp"
#include "EditStore.hpp"
#include "FrameOutput.hpp"
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
#include <QTransform>
#include <cmath>
#include <cstring>
#include <functional>
#include <iostream>
#include <stdexcept>

namespace {
namespace output=spk::desktop::output;
namespace editing=spk::desktop::editing;
QJsonArray checks,operations;
void check(bool passed,const QString& name) {
    checks.append(QJsonObject{{"name",name},{"passed",passed}});
    if(!passed)throw std::runtime_error(name.toUtf8().toStdString());
}
bool near(double a,double b){return std::abs(a-b)<1e-10;}
std::filesystem::path nativePath(const QString& value){return std::filesystem::path(value.toStdWString());}
void waitFor(const std::function<bool()>& condition,const QString& description) {
    if(condition())return;
    QEventLoop loop;QTimer poll,deadline;
    poll.setInterval(10);deadline.setSingleShot(true);
    QObject::connect(&poll,&QTimer::timeout,&loop,[&]{if(condition())loop.quit();});
    QObject::connect(&deadline,&QTimer::timeout,&loop,&QEventLoop::quit);
    poll.start();deadline.start(180000);loop.exec();
    check(condition(),"Completed: "+description);
}
void ready(PreviewController& c) {
    waitFor([&]{return c.ready()||c.failed();},"engine initialization");
    check(c.ready(),"Engine initializes: "+c.status());
    QObject::connect(&c,&PreviewController::operationFinished,&c,[&c](const QString& name,bool success){
        operations.append(QJsonObject{{"operation",name},{"success",success},{"status",c.status()}});
    });
}
void idle(PreviewController& c,const QString& name,bool allowFailure=false) {
    waitFor([&]{return !c.busy()&&!c.dirty();},name);
    check(allowFailure||!c.failed(),name+": "+c.status());
}
output::Geometry geometry(const PreviewController& c) {
    return {c.cropRect(),c.quarterTurns(),c.flipHorizontal(),c.flipVertical(),c.straightenDegrees()};
}
struct Desired {
    int film=0,paper=0,decode=0;
    double exposure=0;
    QVariantMap adjustments;
    output::Geometry geometry;
};
Desired desired(const PreviewController& c) {
    return {c.filmIndex(),c.paperIndex(),c.decodeMode(),c.exposureEv(),c.adjustments(),geometry(c)};
}
bool matches(const PreviewController& c,const Desired& expected) {
    return c.filmIndex()==expected.film&&c.paperIndex()==expected.paper&&c.decodeMode()==expected.decode&&
        near(c.exposureEv(),expected.exposure)&&c.adjustments()==expected.adjustments&&geometry(c)==expected.geometry;
}
bool samePixels(const QImage& left,const QImage& right) {
    if(left.isNull()||right.isNull()||left.size()!=right.size())return false;
    const auto a=left.convertToFormat(QImage::Format_RGBA8888),b=right.convertToFormat(QImage::Format_RGBA8888);
    for(int y=0;y<a.height();++y)
        if(std::memcmp(a.constScanLine(y),b.constScanLine(y),std::size_t(a.width())*4)!=0)return false;
    return true;
}
QByteArray bytes(const QString& path) {
    QFile file(path);check(file.open(QIODevice::ReadOnly),"Read file: "+QFileInfo(path).fileName());return file.readAll();
}
QImage readImage(const QString& path) {
    QImageReader reader(path);auto image=reader.read();
    check(!image.isNull(),"Read exported image: "+reader.errorString());return image;
}
void writeNew(const QString& path,const QByteArray& data) {
    QFile file(path);
    if(!file.open(QIODevice::WriteOnly|QIODevice::NewOnly)||file.write(data)!=data.size()||!file.flush())
        throw std::runtime_error("Cannot write complete report without replacement");
}
void checkPhoto(const PreviewController& c,int index,const QString& source) {
    check(c.activeIndex()==index&&c.frame()&&
          QFileInfo(QString::fromStdWString(c.frame()->source.wstring())).canonicalFilePath()==QFileInfo(source).canonicalFilePath(),
          "Active index and displayed source agree");
}
}

int main(int argc,char** argv) {
    qputenv("QT_QPA_PLATFORM","offscreen");
    QGuiApplication application(argc,argv);
    QString destination;QElapsedTimer elapsed;elapsed.start();QJsonObject report;
    try {
        const auto args=application.arguments();
        if(args.size()!=5)throw std::runtime_error("usage: spk_editing_workflow_test <resources> <RAW> <rejected-RAW> <new-output-directory>");
        const auto resources=nativePath(args[1]);const QFileInfo original(args[2]),rejected(args[3]);
        destination=QFileInfo(args[4]).absoluteFilePath();
        check(original.isFile()&&rejected.isFile(),"Both input fixtures exist");
        check(!QFileInfo::exists(destination),"Output directory is new");
        check(QDir().mkpath(destination+"/fixtures"),"Create owned fixture directory");
        const QString first=destination+"/fixtures/alpha."+original.suffix();
        const QString second=destination+"/fixtures/beta."+original.suffix();
        const QString unsupported=destination+"/fixtures/rejected."+rejected.suffix();
        check(QFile::copy(original.absoluteFilePath(),first)&&QFile::copy(original.absoluteFilePath(),second)&&
              QFile::copy(rejected.absoluteFilePath(),unsupported),"Copy all fixtures before opening");
        const auto firstUrl=QUrl::fromLocalFile(first),secondUrl=QUrl::fromLocalFile(second);
        const QString editDirectory=destination+"/edits";
        Desired savedFirst;const QRectF secondCrop(.2,.1,.1,.12);
        {
            PreviewController c(resources,nullptr,{},editDirectory);ready(c);
            c.openFiles({firstUrl,secondUrl});idle(c,"Initial multiple RAW import");checkPhoto(c,0,first);
            check(!c.canUndo()&&!c.canRedo(),"Imported photographs begin with empty history");

            c.beginEditGesture("exposureEv");c.setExposureEv(.2);c.setExposureEv(.4);c.setExposureEv(.6);c.endEditGesture();
            check(c.canUndo()&&near(c.exposureEv(),.6),"Grouped slider retains final value");
            c.undo();check(near(c.exposureEv(),0)&&!c.canUndo()&&c.canRedo(),"One undo restores whole slider gesture");
            c.redo();check(near(c.exposureEv(),.6)&&c.canUndo()&&!c.canRedo(),"One redo restores whole slider gesture");
            c.undo();c.setExposureEv(.3);
            check(near(c.exposureEv(),.3)&&!c.canRedo(),"Diverging edit retires redo branch");
            c.undo();check(c.canRedo()&&near(c.exposureEv(),0),"Prepare redo branch for zero-net drag");
            c.beginEditGesture("exposureEv");c.setExposureEv(.2);c.setExposureEv(0);c.endEditGesture();
            check(!c.canUndo()&&c.canRedo(),"Zero-net slider drag preserves prior redo history");
            c.redo();check(near(c.exposureEv(),.3),"Preserved redo still restores its value");

            c.beginEditGesture("exposureEv");c.setExposureEv(.4);c.setAdjustment("grainActive",false);c.endEditGesture();
            c.undo();check(near(c.exposureEv(),.4)&&c.adjustments()["grainActive"].toBool(),"Toggle is a separate undo step from active slider");
            c.undo();check(near(c.exposureEv(),.3),"Slider still has its own undo step after toggle");
            c.redo();c.redo();
            check(near(c.exposureEv(),.4)&&!c.adjustments()["grainActive"].toBool(),"Separate slider and toggle redo in order");
            c.setAdjustment("glareActive",false);
            const auto latest=desired(c);int publications=0;
            auto publicationConnection=QObject::connect(&c,&PreviewController::frameChanged,&c,[&]{++publications;});
            c.setExposureEv(1.1);c.apply();check(c.busy(),"Explicit apply starts an in-flight render");
            c.undo();check(near(c.exposureEv(),.4),"Undo applies while older render is in flight");
            c.redo();check(near(c.exposureEv(),1.1),"Redo applies while older render is in flight");
            c.undo();idle(c,"Newest history state wins in-flight render");
            check(matches(c,latest)&&near(c.frame()->settings.print_exposure,std::exp2(-.4)),"Displayed engine parameters match newest undo state");
            check(publications==1,"Superseded render never publishes a stale frame");
            QObject::disconnect(publicationConnection);

            {
                const auto retained=c.frame();const int operationsBefore=operations.size();
                c.setCropRect(QRectF(.13,.17,.11,.15));c.setFlipHorizontal(true);
                const auto mirrored=c.previewImage().copy();c.rotateClockwise();
                check(samePixels(c.previewImage(),mirrored.transformed(QTransform().rotate(90),Qt::FastTransformation))&&
                      !c.flipHorizontal()&&c.flipVertical(),"Clockwise rotation stays visually clockwise after a mirror");
                c.rotateCounterClockwise();
                check(samePixels(c.previewImage(),mirrored)&&c.flipHorizontal()&&!c.flipVertical()&&c.frame()==retained,
                      "Counterclockwise rotation restores mirrored pixels and final-axis flip flags");
                c.setFlipHorizontal(false);c.rotateClockwise();c.setFlipHorizontal(true);c.setFlipVertical(true);c.setStraightenDegrees(6.5);
                const auto transformed=geometry(c);const auto shown=c.previewImage().copy();
                check(c.frame()==retained&&!c.busy()&&operations.size()==operationsBefore,"Crop rotation flips and straighten do not rerender film");
                check(samePixels(shown,output::displayFrame(retained,transformed)),"Preview uses shared full-precision geometry output");
                c.undo();check(near(c.straightenDegrees(),0)&&c.frame()==retained,"Undo geometry changes no engine frame");
                c.redo();check(geometry(c)==transformed&&samePixels(c.previewImage(),shown),"Redo geometry restores exact displayed pixels");
                const QString png=destination+"/transformed.png";
                c.exportImage(QUrl::fromLocalFile(png),1,95,0);idle(c,"Export transformed PNG8");
                check(samePixels(readImage(png),shown),"Actual PNG8 export matches transformed preview pixel for pixel");
                check(c.frame()==retained,"Geometry export retains the editor frame");

                // A parameter's pending debounce must not begin a render and
                // disable the straighten slider while the pointer is held.
                const int beforeHeldGesture=operations.size();
                c.setExposureEv(.55);c.beginEditGesture("straightenDegrees");
                QEventLoop heldGesture;QTimer::singleShot(300,&heldGesture,&QEventLoop::quit);heldGesture.exec();
                check(!c.busy()&&c.dirty()&&operations.size()==beforeHeldGesture,
                      "Holding straighten pauses a pending parameter render");
                c.setStraightenDegrees(7.5);c.endEditGesture();
                idle(c,"Release straighten resumes pending parameter render");
                check(near(c.straightenDegrees(),7.5)&&near(c.frame()->settings.print_exposure,std::exp2(-.55)),
                      "Released straighten and pending exposure both survive rendering");
                c.setStraightenDegrees(6.5);c.setExposureEv(.4);idle(c,"Restore geometry checkpoint parameters");
            }

            c.selectImage(1);idle(c,"Select untouched second photograph");checkPhoto(c,1,second);
            check(!c.canUndo()&&!c.canRedo()&&near(c.exposureEv(),0)&&c.quarterTurns()==0,
                  "Second photograph has independent empty history and geometry");
            c.setCropRect(secondCrop);c.setExposureEv(-.7);
            c.selectImage(0);idle(c,"Restore first photograph with second edit pending");
            check(near(c.exposureEv(),.4)&&c.quarterTurns()==1&&c.canUndo(),"Photo switch restores first independent state and history");
            c.selectAllPhotos(true);c.syncSelectedSettings(false);
            c.selectImage(1);idle(c,"Open synchronized recipient");
            check(near(c.exposureEv(),.4)&&c.cropRect()==secondCrop&&c.quarterTurns()==0,"Synchronization retains recipient geometry");
            c.undo();check(near(c.exposureEv(),-.7)&&c.adjustments()["grainActive"].toBool()&&c.cropRect()==secondCrop,
                           "Recipient independently undoes synchronized parameters");
            check(c.libraryItems()[1].toMap()["thumbnail"].value<QImage>().isNull(),"Pending history render does not republish old thumbnail");
            c.redo();check(near(c.exposureEv(),.4)&&!c.adjustments()["grainActive"].toBool(),"Recipient can redo synchronized parameters");
            c.undo();c.selectImage(0);idle(c,"Return to first before persistence checkpoint");

            // Leave every supported family changed, but deliberately do not
            // yield to the render/save timers. Destruction must flush wanted
            // edits rather than the older engine frame currently on screen.
            int alternativeFilm=-1;
            for(int i=0;i<c.films().size();++i)if(i!=c.filmIndex()&&!c.films()[i].toMap()["positive"].toBool()){alternativeFilm=i;break;}
            check(alternativeFilm>=0&&c.papers().size()>1,"Catalog provides independent persistence choices");
            c.setFilmIndex(alternativeFilm);c.setPaperIndex((c.paperIndex()+1)%c.papers().size());c.setDecodeMode(1);c.setExposureEv(-.35);
            c.setAdjustment("filmExposureEv",.65);c.setAdjustment("filmFormatMm",56.);
            c.setAdjustment("grainAmount",.45);c.setAdjustment("halationActive",false);c.setAdjustment("halationAmount",1.65);
            c.setAdjustment("glareAmount",.35);c.setAdjustment("yFilterShift",.05);c.setAdjustment("mFilterShift",-.07);
            c.rotateCounterClockwise();savedFirst=desired(c);
            check(c.dirty()&&!c.busy(),"Persistence checkpoint contains pending unrendered edits");
            check(c.persistenceWarning().isEmpty(),"No persistence warnings before destruction");
        }
        editing::Store store(editDirectory);
        check(QFileInfo::exists(store.filePath(firstUrl))&&QFileInfo::exists(store.filePath(secondUrl)),"Destruction saved both photographs in private store");
        check(QDir(destination+"/fixtures").entryList(QDir::Files|QDir::NoDotAndDotDot).size()==3,"No edit sidecars were written beside RAW fixtures");
        {
            PreviewController c(resources,nullptr,{},editDirectory);ready(c);
            c.openFiles({secondUrl,firstUrl});idle(c,"Recreated controller opens saved second photograph");
            checkPhoto(c,0,second);check(near(c.exposureEv(),-.7)&&c.cropRect()==secondCrop,"Second saved photograph restores independently");
            c.selectImage(1);idle(c,"Recreated controller restores first photograph");
            checkPhoto(c,1,first);
            check(matches(c,savedFirst),"All controls and geometry survive controller destruction and reopening");
            check(!c.canUndo()&&!c.canRedo(),"Restart restores edits without inventing undo history");
            check(c.persistenceWarning().isEmpty(),"Restored records have no persistence warnings");
            c.setExposureEv(.8);c.openRaw(secondUrl);idle(c,"Open known photo while another preset is pending");
            checkPhoto(c,0,second);
            check(near(c.exposureEv(),-.7)&&c.cropRect()==secondCrop,"Opening known photo does not inherit other photo preset");
            c.rotateClockwise();check(c.canUndo(),"Batch lock test begins with an actual undo step");
            c.selectAllPhotos(false);c.setItemSelected(0,true);
            const auto locked=desired(c);const auto retained=c.frame();
            const QString batch=destination+"/batch";check(QDir().mkpath(batch),"Create batch destination");
            c.exportBatch(QUrl::fromLocalFile(batch),1,95,96);
            check(c.batchExporting()&&!c.canUndo()&&!c.canRedo(),"Batch disables edit history");
            c.undo();c.redo();c.rotateClockwise();c.setStraightenDegrees(-3);c.resetGeometry();c.setExposureEv(.2);
            check(matches(c,locked)&&c.frame()==retained,"Batch rejects history geometry and parameter changes");
            idle(c,"Single selected batch export");
            check(c.canUndo()&&QFileInfo::exists(batch+"/beta.png"),"Batch releases history and writes selected image");
            const auto beforeRejected=desired(c);
            c.openRaw(QUrl::fromLocalFile(unsupported));idle(c,"Unsupported RAW rejected",true);
            check(c.failed()&&matches(c,beforeRejected)&&c.frame()==retained&&c.canUndo(),"Failed open preserves frame settings geometry and valid history");
        }

        // A newer application's record must not be silently replaced even
        // when this controller can still render and edit the original RAW.
        const QString record=store.filePath(firstUrl);
        auto newer=QJsonDocument::fromJson(bytes(record)).object();newer["version"]=99;
        const auto futureBytes=QJsonDocument(newer).toJson(QJsonDocument::Indented);
        {QFile file(record);check(file.open(QIODevice::WriteOnly|QIODevice::Truncate),"Modify only owned fixture record");
         check(file.write(futureBytes)==futureBytes.size()&&file.flush(),"Write future-version fixture");}
        {
            PreviewController c(resources,nullptr,{},editDirectory);ready(c);c.openRaw(firstUrl);idle(c,"Open RAW with future-version record");
            check(!c.persistenceWarning().isEmpty(),"Controller exposes blocked saved-edit warning");
            c.setExposureEv(.35);c.flushEdits();
            check(bytes(record)==futureBytes,"Explicit flush preserves unsupported future record");
        }
        check(bytes(record)==futureBytes,"Destructor flush also preserves future record");
        report["passed"]=true;
    } catch(const std::exception& error) {
        report["passed"]=false;report["error"]=QString::fromUtf8(error.what());
        std::cerr<<error.what()<<'\n';
    }
    report["checks"]=checks;report["checkCount"]=checks.size();report["operations"]=operations;
    report["elapsedMs"]=elapsed.elapsed();
    if(!destination.isEmpty()&&QFileInfo(destination).isDir()) {
        try {writeNew(destination+"/report.json",QJsonDocument(report).toJson(QJsonDocument::Indented));}
        catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
    }
    std::cout<<"editing workflow "<<(report["passed"].toBool()?"PASS":"FAIL")<<" checks="<<checks.size()<<'\n';
    return report["passed"].toBool()?0:1;
}
