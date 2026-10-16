// Actual RAW/Vulkan controller integration, with owned fixtures and a private
// edit store. This exercises user-visible edit history and reopened documents.
#include "PreviewController.hpp"
#include "EditStore.hpp"
#include "FrameOutput.hpp"
#include "display_checks.hpp"
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
#include <algorithm>
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
// Displayed images are half floats: compared exactly, format and tag included.
using display_checks::sameImage;
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
                check(sameImage(c.previewImage(),mirrored.transformed(QTransform().rotate(90),Qt::FastTransformation))&&
                      !c.flipHorizontal()&&c.flipVertical(),"Clockwise rotation stays visually clockwise after a mirror");
                c.rotateCounterClockwise();
                check(sameImage(c.previewImage(),mirrored)&&c.flipHorizontal()&&!c.flipVertical()&&c.frame()==retained,
                      "Counterclockwise rotation restores mirrored pixels and final-axis flip flags");
                c.setFlipHorizontal(false);c.rotateClockwise();c.setFlipHorizontal(true);c.setFlipVertical(true);c.setStraightenDegrees(6.5);
                const auto transformed=geometry(c);const auto shown=c.previewImage().copy();
                check(c.frame()==retained&&!c.busy()&&operations.size()==operationsBefore,"Crop rotation flips and straighten do not rerender film");
                check(sameImage(shown,output::displayFrame(retained,transformed)),"Preview uses shared full-precision geometry output");
                c.undo();check(near(c.straightenDegrees(),0)&&c.frame()==retained,"Undo geometry changes no engine frame");
                c.redo();check(geometry(c)==transformed&&sameImage(c.previewImage(),shown),"Redo geometry restores exact displayed pixels");
                const QString png=destination+"/transformed.png";
                c.exportImage(QUrl::fromLocalFile(png),1,95,0);idle(c,"Export transformed PNG8");
                // The file is exactly the export path's quantisation of the
                // engine frame the preview was made from, and every sample is
                // one the displayed half float's 16-bit source could give.
                const auto exported=readImage(png);
                check(display_checks::sameRgb8(exported,display_checks::expected8(retained,transformed)),
                      "Actual PNG8 export is the transformed engine frame pixel for pixel");
                const display_checks::ExportDisplayAgreement agreement;
                const auto agreed=agreement.compare(exported,shown);
                report["export_display_ambiguous_samples"]=double(agreed.ambiguous);
                check(agreed.samples==qint64(exported.width())*exported.height()*3&&agreed.disagreements==0,
                      "Actual PNG8 export matches transformed preview pixel for pixel");
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

            {
                // A film that moves the paper is one undo step (macOS
                // Session.selectFilmStock pushes one), and black and white
                // prints on its silver paper as a neutral picture.
                const auto film=c.parameter("film_stock"),paper=c.parameter("print_stock");
                check(c.selectFilm("kodak_tri_x_400")&&c.parameter("print_stock")=="ilford_multigrade_iv_rc"&&
                      c.filmIsMonochrome(),"A black-and-white film takes the silver paper");
                idle(c,"Render Tri-X 400 on Multigrade IV RC");
                check(c.frame()->settings.film_stock=="kodak_tri_x_400"&&
                      c.frame()->settings.print_stock=="ilford_multigrade_iv_rc","Black-and-white frame published");
                // The displayed picture is sRGB half floats, read here at 8
                // bits; a silver print has no colour in it beyond rounding
                // (glare and grain are on here).
                const auto shown=c.previewImage().convertToFormat(QImage::Format_RGB32);
                int spread=0;double mean=0;
                for(int y=0;y<shown.height();++y)for(int x=0;x<shown.width();++x) {
                    const QRgb p=shown.pixel(x,y);
                    spread=std::max({spread,std::abs(qRed(p)-qGreen(p)),std::abs(qBlue(p)-qGreen(p))});
                    mean+=qGreen(p);
                }
                mean/=double(shown.width())*shown.height()*255.0;
                std::cout<<"black and white on the RAW: largest channel spread "<<spread<<"/255, mean "<<mean<<'\n';
                check(spread<=2&&mean>0.05&&mean<0.95,"A black-and-white print of the RAW is a neutral picture");
                c.undo();
                check(c.parameter("film_stock")==film&&c.parameter("print_stock")==paper&&!c.filmIsMonochrome(),
                      "One undo restores both the film and the paper it moved");
                c.redo();
                check(c.parameter("film_stock")=="kodak_tri_x_400"&&c.parameter("print_stock")=="ilford_multigrade_iv_rc",
                      "One redo restores both again");
                c.undo();idle(c,"Undo back to the colour pair");
                check(c.frame()->settings.film_stock==film.toString().toStdString()&&
                      c.frame()->settings.print_stock==paper.toString().toStdString(),"Colour pair renders again after undo");
            }

            {
                // Film Edge on the RAW (FilmEdgeSection.swift, Session+FilmEdge
                // .swift): the crop goes into the 135 gate, the engine is handed
                // the picture cut by it, and the frame is the film around it --
                // the canvas spk_overscan_geometry reports, with the gate where
                // it says. The export writes the strip; the film edge off gives
                // the crop back; one undo step each.
                const auto before=geometry(c);const auto plainFrame=c.frame();
                check(c.setFilmEdgeActive(true),"Switch the film edge on");
                const auto held=geometry(c);
                const QSizeF source(plainFrame->decode_width,plainFrame->decode_height);
                const double ratio=held.crop.width()*source.width()/(held.crop.height()*source.height());
                check(std::abs(ratio-1.5)<0.02*1.5&&held.quarterTurns==before.quarterTurns&&
                      held.straightenDegrees==before.straightenDegrees,"The crop is held at the 135 gate's shape");
                idle(c,"Develop the frame on the film");
                const auto strip=c.frame();
                check(strip->cut&&strip->geometry.x==held.crop.x()&&std::abs(strip->geometry.w-held.crop.width())<1e-12,
                      "The engine was handed the picture cut by the held crop");
                const QJsonObject layout=QJsonDocument::fromJson(QByteArray::fromStdString(strip->overscan_geometry)).object();
                check(layout["valid"].toBool()&&layout["canvas_w"].toInt()==int(strip->width())&&
                      layout["canvas_h"].toInt()==int(strip->height()),"The frame is the canvas spk_overscan_geometry reports");
                check(strip->width()>strip->picture_width&&strip->height()>strip->picture_height,
                      "The film is larger than the picture");
                // The gate's quad, in canvas pixels, is the picture's size.
                const auto quad=layout["gates"].toArray().first().toArray();
                double x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;
                for(int i=0;i<4;++i){
                    const double x=quad[2*i].toDouble()*strip->width(),y=quad[2*i+1].toDouble()*strip->height();
                    x0=std::min(x0,x);x1=std::max(x1,x);y0=std::min(y0,y);y1=std::max(y1,y);
                }
                std::cout<<"film edge on the RAW: picture "<<strip->picture_width<<" x "<<strip->picture_height
                         <<" in a film of "<<strip->width()<<" x "<<strip->height()<<", gate "<<(x1-x0)<<" x "<<(y1-y0)
                         <<" at "<<x0<<", "<<y0<<'\n';
                check(std::abs((x1-x0)-strip->picture_width)<0.03*strip->picture_width&&
                      std::abs((y1-y0)-strip->picture_height)<0.03*strip->picture_height&&x0>0&&y0>0&&
                      x1<strip->width()&&y1<strip->height(),"The gate holds the picture inside the film");
                check(c.previewImage().size()==QSize(int(strip->width()),int(strip->height()))&&
                      c.frameIsCut()&&!c.uncroppedImage().isNull()&&c.uncroppedImage().size()!=c.previewImage().size(),
                      "The canvas shows the strip whole; the crop editor frames over the whole decode");
                const auto edge=c.filmEdge();
                check(edge["filmMeasured"].toBool()&&edge["filmWidth"].toInt()==int(strip->width())&&
                      edge["pictureWidth"].toInt()==int(strip->picture_width),"The section's size caption is measured");
                const QString png=destination+"/film-edge.png";
                c.exportImage(QUrl::fromLocalFile(png),1,95,0);idle(c,"Export the strip");
                check(display_checks::sameRgb8(readImage(png),display_checks::expected8(c.frame(),output::Geometry{})),
                      "The export writes the whole strip, with no geometry over it");
                // A new framing re-develops; the crop stays the gate's shape.
                auto moved=held;moved.crop.translate(-held.crop.x()*0.5,0);
                c.setCropRect(moved.crop);
                check(c.dirty()&&std::abs(c.cropRect().x()-moved.crop.x())<1e-12,"A new framing is a new negative");
                idle(c,"Develop the new framing");
                check(c.frame()!=strip&&c.frame()->cut&&std::abs(c.frame()->geometry.x-moved.crop.x())<1e-12,
                      "The new framing reached the engine");
                // The date back prints in the frame, on the film.
                check(c.setDateBackActive(true)&&c.dateBack()["effective"].toBool(),"Switch the date back on");
                idle(c,"Develop the date");
                check(c.frame()->cut&&c.frame()->width()==strip->width(),"The date prints on the same film");
                c.undo();check(!c.parameter("date_imprint_active").toBool(),"One undo takes the date off");
                c.undo();check(geometry(c)==held,"One undo restores the framing");
                check(c.setFilmEdgeActive(false)&&geometry(c)==before,"The film edge off gives the crop back");
                idle(c,"Develop without the film edge");
                check(!c.frame()->cut&&c.frame()->width()==plainFrame->width(),"The frame is the photograph again");
                c.undo();check(c.parameter("overscan_active").toBool()&&geometry(c)==held,"Undo puts the crop back in the gate");
                c.redo();check(!c.parameter("overscan_active").toBool()&&geometry(c)==before,"Redo gives it back again");
                idle(c,"Settle without the film edge");
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
            {
                // The rendered first photograph's strip thumbnail: the same
                // half floats and tag as its canvas, reduced to the strip box.
                const auto thumbnail=c.libraryItems()[0].toMap()["thumbnail"].value<QImage>();
                check(thumbnail.format()==QImage::Format_RGBX16FPx4&&
                      thumbnail.colorSpace()==spk::desktop::display::colorSpace(c.frame()->encoding)&&
                      thumbnail.width()<=180&&thumbnail.height()<=120&&(thumbnail.width()==180||thumbnail.height()==120),
                      "Rendered thumbnail keeps 16-bit-class half floats in the frame's colour space");
            }
            c.redo();check(near(c.exposureEv(),.4)&&!c.adjustments()["grainActive"].toBool(),"Recipient can redo synchronized parameters");
            c.undo();c.selectImage(0);idle(c,"Return to first before persistence checkpoint");

            // Leave every supported family changed, but deliberately do not
            // yield to the render/save timers. Destruction must flush wanted
            // edits rather than the older engine frame currently on screen.
            int alternativeFilm=-1;
            for(int i=0;i<c.films().size();++i)
                if(i!=c.filmIndex()&&!c.films()[i].toMap()["positive"].toBool()&&!c.films()[i].toMap()["monochrome"].toBool()){alternativeFilm=i;break;}
            check(alternativeFilm>=0&&c.papers().size()>1,"Catalog provides independent persistence choices");
            c.setFilmIndex(alternativeFilm);
            // The film took its own paper; then another one it can print on.
            int alternativePaper=c.paperIndex();
            do alternativePaper=(alternativePaper+1)%c.papers().size();
            while(c.papers()[alternativePaper].toMap()["monochrome"].toBool());
            c.setPaperIndex(alternativePaper);
            check(c.paperIndex()==alternativePaper,"A second colour paper is chosen for persistence");
            c.setDecodeMode(1);c.setExposureEv(-.35);
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

        // The Pre-Dev rail on the RAW (PreviewControllerPredev.cpp), in a
        // controller, fixtures and edit store of its own.
        check(QDir().mkpath(destination+"/predev"),"Create the Pre-Dev fixture directory");
        const QString gamma=destination+"/predev/gamma."+original.suffix(),delta=destination+"/predev/delta."+original.suffix();
        check(QFile::copy(original.absoluteFilePath(),gamma)&&QFile::copy(original.absoluteFilePath(),delta),"Copy the Pre-Dev fixtures");
        {
            PreviewController c(resources,nullptr,{},destination+"/predev-edits");ready(c);
            c.openFiles({QUrl::fromLocalFile(gamma),QUrl::fromLocalFile(delta)});idle(c,"Open the Pre-Dev fixtures");
            const auto measured=[&](const QString& name){
                const auto shown=c.frame();
                waitFor([&]{return c.frame()!=shown||(c.latitude().value("available").toBool()&&c.metering().value("available").toBool());},name);
            };
            // The meter and the latitude of the frame on screen, measured on
            // the worker after the develop.
            measured("Latitude and meter of the developed frame");
            const auto latitude=c.latitude();const auto meter=c.metering();
            std::cout<<"latitude on the RAW: "<<latitude["summary"].toString().replace(QChar(0x00A0),' ').toStdString()
                     <<"; below "<<latitude["below"].toDouble()<<" within "<<latitude["within"].toDouble()<<" above "
                     <<latitude["above"].toDouble()<<"; "<<meter["label"].toString().toStdString()<<"; spk_scene_latitude "
                     <<latitude["analysisMs"].toDouble()<<" ms, spk_solve "<<meter["solveMs"].toDouble()<<" ms on a "
                     <<c.frame()->width()<<"x"<<c.frame()->height()<<" frame\n";
            check(std::abs(latitude["below"].toDouble()+latitude["within"].toDouble()+latitude["above"].toDouble()-1)<1e-6&&
                  latitude["heldStops"].toDouble()>2&&latitude["fractions"].toList().size()==128,"The latitude readout of the RAW");

            // White balance: As Shot is the camera's; a temperature re-decodes
            // and develops a new negative; a print edit after it does not.
            const auto wb=c.whiteBalance();
            check(wb["mode"]=="as_shot"&&wb["asShotKnown"].toBool()&&wb["temperatureAsShot"].toBool()&&wb["tintAsShot"].toBool()&&
                  wb["temperature"]==wb["asShotTemperature"],"As Shot reads the camera's white balance");
            const auto shotMultipliers=c.frame()->metadata.post_scale_pre_mul;
            check(c.setTemperature(3200),"Temperature 3200 K accepted");idle(c,"Re-decode at 3200 K");
            check(!c.frame()->reprint()&&!c.frame()->negative_was_cached()&&c.frame()->timings.decode_ms>0&&
                  c.frame()->metadata.post_scale_pre_mul!=shotMultipliers&&!c.whiteBalance()["temperatureAsShot"].toBool()&&
                  c.whiteBalance()["tintAsShot"].toBool(),"A white balance re-decodes the RAW; the tint stays the camera's");
            std::cout<<"white balance on the RAW: as shot "<<wb["asShotTemperature"].toDouble()<<" K / "<<wb["asShotTint"].toDouble()
                     <<"; 3200 K re-decode "<<c.frame()->timings.decode_ms<<" ms, render "<<c.frame()->timings.render_ms<<" ms\n";
            c.setExposureEv(c.exposureEv()+.1);idle(c,"A print edit after the white balance");
            check(c.frame()->reprint()&&c.frame()->negative_was_cached()&&c.frame()->timings.decode_ms==0,
                  "A print edit after a white balance reprints the cached negative without decoding");
            // A print edit re-probes the medium (its key holds the enlarger)
            // and keeps the scene: the analysis's cost after a reprint.
            {
                const auto printed=c.frame();
                waitFor([&]{return c.frame()!=printed||c.latitude().value("current").toBool();},"Latitude after a print edit");
                std::cout<<"latitude after a reprint: spk_scene_latitude "<<c.latitude()["analysisMs"].toDouble()<<" ms\n";
            }
            c.undo();c.undo();idle(c,"Undo back to As Shot");
            check(c.whiteBalance()["mode"]=="as_shot"&&c.frame()->metadata.post_scale_pre_mul==shotMultipliers,
                  "Undo restores As Shot and the camera's multipliers");

            // The neutral picker, at the middle of the shown picture.
            bool pickDone=false,pickOk=false;QString pickMessage;
            auto pickConnection=QObject::connect(&c,&PreviewController::neutralPicked,&c,[&](bool ok,const QString& m){pickDone=true;pickOk=ok;pickMessage=m;});
            check(c.pickNeutral(.5,.5),"The neutral picker starts");
            waitFor([&]{return pickDone;},"The neutral pick");idle(c,"Re-decode at the picked white balance");
            QObject::disconnect(pickConnection);
            if(pickOk) {
                check(c.whiteBalance()["mode"]=="custom"&&std::get<std::string>(c.frame()->settings.get("white_balance"))=="custom"&&
                      c.frame()->timings.decode_ms>0,"A pick is Custom, re-decoded");
                std::cout<<"neutral pick on the RAW: "<<c.whiteBalance()["temperature"].toDouble()<<" K / "<<c.whiteBalance()["tint"].toDouble()<<"\n";
                c.undo();idle(c,"Undo the pick");
            } else {
                std::cout<<"neutral pick on the RAW refused: "<<pickMessage.toStdString()<<"\n";
                check(!pickMessage.isEmpty()&&c.whiteBalance()["mode"]=="as_shot","A refused pick says why and changes nothing");
            }

            // Process: the shifts are offsets from the solved pack, so they go
            // back to 0 in one undo step; the pack is reported.
            check(c.setParameter("y_filter_shift",.3)&&c.setParameter("m_filter_shift",-.2),"Shifts before Process");
            idle(c,"Render the shifts");
            bool processDone=false,processOk=false;
            auto processConnection=QObject::connect(&c,&PreviewController::processed,&c,[&](bool ok,const QString&){processDone=true;processOk=ok;});
            check(c.process(),"Process starts");waitFor([&]{return processDone;},"Process");idle(c,"Reprint after Process");
            QObject::disconnect(processConnection);
            check(processOk&&c.parameter("y_filter_shift").toDouble()==0&&c.parameter("m_filter_shift").toDouble()==0,
                  "Process zeroes the shifts");
            check(c.frame()->reprint()&&c.frame()->settings.y_filter_shift==0,"Process's reprint shows the solved pack");
            const auto pack=c.metering()["filters"].toMap();
            check(pack.contains("c")&&pack.contains("m")&&pack.contains("y"),"Process reports the pack");
            std::cout<<"Process on the RAW: pack C "<<pack["c"].toDouble()<<" M "<<pack["m"].toDouble()<<" Y "<<pack["y"].toDouble()<<"\n";
            c.undo();
            check(near(c.parameter("y_filter_shift").toDouble(),.3)&&near(c.parameter("m_filter_shift").toDouble(),-.2),
                  "One undo restores both shifts");
            idle(c,"Undo Process");

            // Scene Placement: a highlight step through the Fit, committed and
            // re-developed; synced, the other photograph fits its own.
            measured("Latitude after Process");
            const auto placement=c.scenePlacement();
            check(placement["enabled"].toBool(),"Scene Placement is enabled on a measured frame");
            const auto window=placement["highlightWindow"].toMap();
            if(window["hasSpan"].toBool()) {
                const double step=std::min(window["from"].toDouble()+.25,window["to"].toDouble());
                const double aboveBefore=c.latitude()["above"].toDouble();
                check(c.placeScene(step,0,"highlight")&&c.scenePlacement()["active"].toBool()&&
                      near(c.scenePlacement()["highlight"].toDouble(),step),"A highlight step is committed");
                check(c.latitude()["above"].toDouble()<=aboveBefore,"The graph follows the committed curve at once");
                idle(c,"Re-develop with the placement");
                check(!c.frame()->negative_was_cached()&&std::get<bool>(c.frame()->settings.get("scene_latitude_active")),
                      "A placement re-develops");
                const auto knee=c.parameter("scene_latitude_highlight_knee").toDouble();
                std::cout<<"placement on the RAW: highlight "<<step<<" stops (window "<<window["from"].toDouble()<<" .. "
                         <<window["to"].toDouble()<<"), knee "<<knee<<", above "<<aboveBefore<<" -> "<<c.latitude()["above"].toDouble()<<"\n";
                c.selectAllPhotos(false);c.setItemSelected(1,true);c.syncSelectedSettings(false);
                c.selectImage(1);idle(c,"Open the synced photograph");
                waitFor([&]{return c.activeIndex()==1&&c.parameter("scene_latitude_needs_fit")==false&&!c.dirty()&&!c.busy();},
                        "The synced placement is fitted on its own frame");
                std::cout<<"synced placement: active "<<std::get<bool>(c.frame()->settings.get("scene_latitude_active"))
                         <<", pull-back "<<c.parameter("scene_latitude_highlight_pull_back").toDouble()
                         <<", knee "<<c.parameter("scene_latitude_highlight_knee").toDouble()<<" (source knee "<<knee<<")\n";
                check(std::get<bool>(c.frame()->settings.get("scene_latitude_active"))&&
                      near(c.parameter("scene_latitude_highlight_pull_back").toDouble(),step)&&
                      std::abs(c.parameter("scene_latitude_highlight_knee").toDouble()-knee)<1e-9,
                      "A synced placement carries its pull-back and is fitted on its own frame (the same file: the same knee)");
                c.undo();idle(c,"Undo the sync");
                check(!c.scenePlacement()["active"].toBool(),"The recipient undoes the synced placement");
                c.selectImage(0);idle(c,"Back to the placed photograph");
                c.undo();idle(c,"Undo the placement");
                check(!c.scenePlacement()["active"].toBool()&&!std::get<bool>(c.frame()->settings.get("scene_latitude_active")),
                      "Undo turns the placement off");
            } else {
                std::cout<<"placement on the RAW: no highlight window: "<<placement["highlightMessage"].toString().toStdString()<<"\n";
                check(!placement["highlightMessage"].toString().isEmpty(),"A side with no window says why");
            }
        }
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
