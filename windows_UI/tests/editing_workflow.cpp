// Actual RAW/Vulkan controller integration, with owned fixtures and a private
// edit store. This exercises user-visible edit history and reopened documents.
#include "PreviewController.hpp"
#include "EditStore.hpp"
#include "FrameOutput.hpp"
#include <QDir>
#include <QColorSpace>
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
            c.setRating(1,4);c.setColorLabel(1,7);c.selectAllPhotos(false);c.setItemSelected(1,true);
            c.createCollection("Two RAWs");
            check(c.libraryItems().size()==1&&
                  c.libraryItems()[0].toMap()["rating"].toInt()==4&&
                  c.libraryItems()[0].toMap()["colorLabel"].toInt()==7,
                  "Persistent catalog stores rating and color label");
            check(c.collections().size()==1&&c.collections()[0].toMap()["count"].toInt()==1,
                  "Collection is created from the selected photograph");
            c.setCollectionFilter("");check(c.libraryItems().size()==2,"Clearing collection filter restores all catalog entries");
            c.selectAllPhotos(false);c.setItemSelected(0,true);c.setItemSelected(1,true);
            c.createPairFromSelection();idle(c,"Compose two real RAWs into a half-frame pair");
            check(c.activeIndex()==2&&c.frame()&&c.frame()->pair_sources.size()==2,
                  "Half-frame pair opens as its own library item with both sources");
            check(std::abs(double(c.frame()->width())/c.frame()->height()-37.0/24.0)<0.005,
                  "Half-frame pair follows the 37:24 gate geometry");
            check(c.libraryItems()[2].toMap()["isPair"].toBool(),"Filmstrip marks the persistent pair item");
            check(c.saveExportRecipe("Web JPEG",3,88,1920,1,true)&&
                  c.exportRecipes().size()==1&&c.exportRecipe(0)["outputSpace"].toInt()==1,
                  "Named export recipe validates and stores format, size, colour and metadata");
            c.selectImage(0);idle(c,"Return to first source after half-frame pair");
            c.selectAllPhotos(true);

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
                const QString adobePng=destination+"/transformed-adobe.png";
                c.exportImageWithRecipe(QUrl::fromLocalFile(adobePng),2,95,0,2,true);
                idle(c,"Export transformed Adobe RGB PNG16");
                const auto adobeImage=readImage(adobePng);
                check(adobeImage.colorSpace()==QColorSpace(QColorSpace::AdobeRgb)&&
                      !adobeImage.text("Description").isEmpty(),
                      "Actual RAW export embeds Adobe RGB and selected source metadata");
#ifdef _WIN32
                const QString heif=destination+"/transformed.heic";
                c.exportImageWithRecipe(QUrl::fromLocalFile(heif),4,90,0,0,true);
                idle(c,"Export transformed sRGB HEIF");
                check(QFileInfo(heif).size()>16,"Actual RAW HEIF export is missing or empty");
#endif
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
        {
            PreviewController c(resources,nullptr,{},editDirectory);ready(c);
            check(c.libraryItems().size()==3&&c.collections().size()==1&&
                  c.libraryItems()[1].toMap()["rating"].toInt()==4&&
                  c.libraryItems()[1].toMap()["colorLabel"].toInt()==7&&
                  c.libraryItems()[2].toMap()["isPair"].toBool()&&
                  c.exportRecipes().size()==1,
                  "Catalog, collection, metadata, pair and export recipe survive restart");
            c.openRaw(firstUrl);idle(c,"Open RAW for Digital Intermediate preview and export");
            c.setAdjustment("digital_intermediate",true);idle(c,"Render Cineon Digital Intermediate");
            const auto frame=c.frame();
            check(frame&&frame->digital_intermediate&&QFileInfo(QString::fromStdWString(frame->di_view_table.wstring())).isFile(),
                  "DI frame names its bundled Cineon viewing table");
            const auto displayed=output::workingFrame(frame).convertToFormat(QImage::Format_ARGB32);
            check(!displayed.isNull()&&displayed.size()==QSize(int(frame->width()),int(frame->height())),
                  "DI frame is converted to displayable ProPhoto sRGB output");
            int changed=0;
            for(int y=0;y<displayed.height();y+=97)for(int x=0;x<displayed.width();x+=97) {
                const auto* row=frame->bgra8.data()+std::size_t(y)*frame->width()*4;
                const auto legacy=qRgb(row[std::size_t(x)*4+2],row[std::size_t(x)*4+1],row[std::size_t(x)*4]);
                if(legacy!=displayed.pixel(x,y))++changed;
            }
            check(changed>0,"DI viewing actually changes the SDR pixel path");
            output::ExportOptions options;options.format=output::Format::PNG8;
            const QString diExport=destination+"/dia-frame.png";
            output::exportFrame(frame,nativePath(diExport),QRectF(0,0,1,1),options,resources);
            check(readImage(diExport).size()==displayed.size(),"DI exports a complete PNG");
            c.setAdjustment("digital_intermediate",false);idle(c,"Return from Digital Intermediate");
            check(c.frame()&&!c.frame()->digital_intermediate,"DI can be disabled without reopening the RAW");
            const auto layerBaseline=output::workingFrame(c.frame()).convertToFormat(QImage::Format_ARGB32);
            c.setAdjustment("scene_layer_active",true);c.setAdjustment("scene_layer_exposure_ev",1.5);
            c.setAdjustment("scene_layer_radius_x",0.3);c.setAdjustment("scene_layer_radius_y",0.2);
            idle(c,"Render local scene exposure layer");
            const auto layerFrame=c.frame();
            check(bool(layerFrame),"Local scene mask produces a complete frame");
            const auto layered=output::workingFrame(layerFrame).convertToFormat(QImage::Format_ARGB32);
            int layerChanged=0;
            for(int y=0;y<layered.height();y+=97)for(int x=0;x<layered.width();x+=97)
                if(layered.pixel(x,y)!=layerBaseline.pixel(x,y))++layerChanged;
            check(layerChanged>0,"Local scene mask changes the rendered exposure");
            const QString layerExport=destination+"/scene-layer.png";
            output::exportFrame(layerFrame,nativePath(layerExport),QRectF(0,0,1,1),options,resources);
            check(readImage(layerExport).size()==layered.size(),"Local scene mask exports a complete PNG");
            c.setAdjustment("scene_layer_active",false);idle(c,"Disable local scene mask");
            check(c.frame()&&!c.adjustments()["scene_layer_active"].toBool(),"Local scene mask disables without reopening");
            savedFirst=desired(c);
        }
        editing::Store store(editDirectory);
        check(QFileInfo::exists(store.filePath(firstUrl))&&QFileInfo::exists(store.filePath(secondUrl)),"Destruction saved both photographs in private store");
        check(QDir(destination+"/fixtures").entryList(QDir::Files|QDir::NoDotAndDotDot).size()==3,"No edit sidecars were written beside RAW fixtures");
        {
            const QString variantStore=destination+"/variant-store";
            PreviewController c(resources,nullptr,{},variantStore);ready(c);
            c.openRaw(firstUrl);idle(c,"Open RAW before creating variants");
            c.setExposureEv(.45);idle(c,"Render source variant before cloning");
            c.createVariant(0,true);idle(c,"Clone variant with an independent edit record");
            const auto items=c.libraryItems();
            check(items.size()==2&&c.activeIndex()==1&&
                  items[0].toMap()["variantNumber"].toInt()==1&&
                  items[1].toMap()["variantNumber"].toInt()==2&&
                  items[1].toMap()["variantCount"].toInt()==2,
                  "Clone variant appears beside its source with 1 / 2 and 2 / 2 labels");
            check(near(c.exposureEv(),.45),"Clone starts with the complete current edit");
            c.setExposureEv(-.6);idle(c,"Render independent clone edit");
            c.createVariant(0,false);idle(c,"Create a fresh default variant");
            check(c.libraryItems().size()==3&&c.activeIndex()==1&&near(c.exposureEv(),0),
                  "New variant starts with default settings beside the source");
            c.setExposureEv(.8);c.deleteVariant(1);idle(c,"Delete only the active variant");
            check(c.libraryItems().size()==2&&
                  QFileInfo::exists(QUrl(firstUrl).toLocalFile()),
                  "Deleting a variant preserves the source file and sibling variants");
        }
        {
            PreviewController c(resources,nullptr,{},destination+"/variant-store");ready(c);
            check(c.libraryItems().size()==2&&
                  c.libraryItems()[0].toMap()["variantCount"].toInt()==2&&
                  c.libraryItems()[1].toMap()["variantCount"].toInt()==2,
                  "Variant membership and counters survive controller restart");
            c.selectImage(0);idle(c,"Open persisted source variant");
            check(near(c.exposureEv(),.45),"Source variant retained its copied edit");
            c.selectImage(1);idle(c,"Open persisted cloned variant");
            check(near(c.exposureEv(),-.6),"Clone variant retained its independent edit");
        }
        {
            PreviewController c(resources,nullptr,{},destination+"/filter-store");ready(c);
            c.openFiles({firstUrl,secondUrl});idle(c,"Load two photos for filtering");
            c.setLibrarySearch("beta");idle(c,"Filter catalog by name");
            check(c.libraryItems().size()==1&&c.libraryItems()[0].toMap()["name"].toString()=="beta."+original.suffix(),
                  "Library search filters by filename");
            c.setLibrarySearch(QString());c.setLibrarySort(1);idle(c,"Sort catalog by descending name");
            check(c.libraryItems().size()==2&&c.libraryItems()[0].toMap()["name"].toString()=="beta."+original.suffix(),
                  "Library sort preserves the requested order");
            c.moveToTrash(0);idle(c,"Move a catalog entry to trash");
            check(c.libraryItems().size()==1&&c.trashCount()==1&&QFileInfo(QUrl(firstUrl).toLocalFile()).isFile(),
                  "Trash hides only the catalog entry and preserves the source file");
            c.setCollectionFilter(QStringLiteral("__trash__"));idle(c,"Open catalog trash");
            check(c.libraryItems().size()==1&&c.libraryItems()[0].toMap()["trashed"].toBool(),
                  "Trash view reveals the removed catalog entry");
        }
        {
            PreviewController c(resources,nullptr,{},destination+"/filter-store");ready(c);
            check(c.trashCount()==1,"Trash membership survives controller restart");
            c.setCollectionFilter(QStringLiteral("__trash__"));idle(c,"Open persisted trash");
            c.selectImage(c.libraryItems()[0].toMap()["catalogIndex"].toInt());
            idle(c,"Select trashed photo");
            c.restoreFromTrash(c.activeIndex());idle(c,"Restore photo from trash");
            check(c.trashCount()==0,"Restored photo leaves the trash");
            c.setCollectionFilter(QString());idle(c,"Return to all photos");
            check(c.libraryItems().size()==2,"Restored photo returns to the catalog");
        }
        {
            const QString linkedRoot=destination+"/linked-source";
            check(QDir().mkpath(linkedRoot)&&
                  QFile::copy(QUrl(firstUrl).toLocalFile(),linkedRoot+"/linked-alpha.dng"),
                  "Create linked-folder fixture");
            PreviewController c(resources,nullptr,{},destination+"/linked-store");ready(c);
            check(c.addLinkedFolder(QUrl::fromLocalFile(linkedRoot)),
                  "Register a linked RAW folder");
            idle(c,"Inspect linked RAW folder");
            const auto sources=c.librarySources();
            check(c.libraryItems().size()==1&&sources.back().toMap()["kind"].toString()=="linked"&&
                  QFileInfo(sources.back().toMap()["root"].toString()).canonicalFilePath()==QFileInfo(linkedRoot).canonicalFilePath(),
                  "Linked source records its external folder");
            check(QFileInfo(linkedRoot+"/linked-alpha.dng").isFile(),
                  "Linked source leaves the original file in place");
        }
        {
            PreviewController c(resources,nullptr,{},destination+"/linked-store");ready(c);
            check(c.librarySources().back().toMap()["kind"].toString()=="linked"&&
                  c.libraryItems().size()==1&&c.libraryItems()[0].toMap()["name"].toString()=="linked-alpha.dng",
                  "Linked folder source and its external photo survive restart");
        }
        {
            PreviewController c(resources,nullptr,{},editDirectory);ready(c);
            check(c.libraryItems().size()==3,"Recreated controller restores catalog before manual opens");
            c.openFiles({secondUrl,firstUrl});idle(c,"Recreated controller opens saved second photograph");
            checkPhoto(c,1,second);check(near(c.exposureEv(),-.7)&&c.cropRect()==secondCrop,"Second saved photograph restores independently");
            c.selectImage(0);idle(c,"Recreated controller restores first photograph");
            checkPhoto(c,0,first);
            check(matches(c,savedFirst),"All controls and geometry survive controller destruction and reopening");
            check(!c.canUndo()&&!c.canRedo(),"Restart restores edits without inventing undo history");
            check(c.persistenceWarning().isEmpty(),"Restored records have no persistence warnings");
            c.setExposureEv(.8);c.openRaw(secondUrl);idle(c,"Open known photo while another preset is pending");
            checkPhoto(c,1,second);
            check(near(c.exposureEv(),-.7)&&c.cropRect()==secondCrop,"Opening known photo does not inherit other photo preset");
            c.rotateClockwise();check(c.canUndo(),"Batch lock test begins with an actual undo step");
            c.selectAllPhotos(false);c.setItemSelected(1,true);
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
        {
            const QString sourceStore=destination+"/source-catalog-store";
            const QString catalogA=destination+"/catalogs/Album A";
            const QString catalogB=destination+"/catalogs/Album B";
            PreviewController c(resources,nullptr,{},sourceStore);ready(c);
            check(c.librarySources().size()==1&&c.activeLibrarySource()==0,
                  "Application starts with an explicit persistent library source");
            check(c.createLibraryCatalog(QUrl::fromLocalFile(catalogA)),
                  "Create an empty managed catalog without replacing an existing catalog");
            c.openRaw(firstUrl);idle(c,"Import a real RAW into the new managed catalog");
            c.setRating(0,5);
            check(c.createLibraryCatalog(QUrl::fromLocalFile(catalogB))&&c.libraryItems().isEmpty(),
                  "Switching to a fresh managed catalog clears the active photo set");
            const auto sources=c.librarySources();
            int albumA=-1;
            for(int i=0;i<int(sources.size());++i)
                if(sources[i].toMap()["name"].toString()=="Album A")albumA=i;
            check(albumA>=0&&c.switchLibrarySource(albumA)&&c.libraryItems().size()==1&&
                  c.libraryItems()[0].toMap()["rating"].toInt()==5,
                  "Catalog switching restores persisted photo metadata from the selected source");
        }
        {
            const QString sourceStore=destination+"/source-catalog-store";
            PreviewController c(resources,nullptr,{},sourceStore);ready(c);
            check(c.librarySources().size()==3&&c.libraryItems().size()==1&&
                  c.libraryItems()[0].toMap()["rating"].toInt()==5,
                  "Last selected catalog and its photos survive application restart");
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
