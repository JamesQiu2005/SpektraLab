// Geometry edits at full resolution, timed on the GUI thread. A straighten
// drag and two crop drags (with and without a straighten, which take
// different paths in FrameOutput) are made as a person makes them: one step
// per 16 ms frame. Reported per drag: each setter call's own time, the longest
// the event loop went unserved (a 1 ms heartbeat), and how long after the last
// step the canvas's picture stops changing. Not a CTest: it needs a camera RAW.
//   spk_qt_geometry_bench <resources> <RAW> <new-output-directory>
#include "PreviewController.hpp"
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QTimer>
#include <algorithm>
#include <cstdio>
#include <functional>
#include <stdexcept>
#include <vector>

namespace {
void require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}
void waitFor(const std::function<bool()>& condition,int timeoutMs=180000) {
    if(condition())return;
    QEventLoop loop;QTimer poll,deadline;
    poll.setInterval(5);deadline.setSingleShot(true);
    QObject::connect(&poll,&QTimer::timeout,&loop,[&]{if(condition())loop.quit();});
    QObject::connect(&deadline,&QTimer::timeout,&loop,&QEventLoop::quit);
    poll.start();deadline.start(timeoutMs);loop.exec();
    require(condition(),"timed out");
}
double percentile(std::vector<double> v,double p) {
    if(v.empty())return 0;
    std::sort(v.begin(),v.end());
    return v[std::min(v.size()-1,std::size_t(p*double(v.size()-1)+.5))];
}
void drag(PreviewController& c,const char* name,const char* gesture,int steps,const std::function<void(int)>& step) {
    std::vector<double> calls;
    double maxGap=0;qint64 lastBeat=0;QElapsedTimer clock;
    QTimer heartbeat;heartbeat.setTimerType(Qt::PreciseTimer);heartbeat.setInterval(1);
    QObject::connect(&heartbeat,&QTimer::timeout,[&]{
        const auto now=clock.nsecsElapsed();
        if(lastBeat)maxGap=std::max(maxGap,double(now-lastBeat)/1e6);
        lastBeat=now;
    });
    qint64 picture=c.previewImage().cacheKey(),changedAt=0;int pictures=0;
    auto watch=[&]{const auto key=c.previewImage().cacheKey();if(key!=picture){picture=key;changedAt=clock.nsecsElapsed();++pictures;}};
    const auto watching=QObject::connect(&c,&PreviewController::frameChanged,&c,watch);
    c.beginEditGesture(gesture);
    clock.start();heartbeat.start();
    int done=0;QEventLoop loop;QTimer pace;pace.setTimerType(Qt::PreciseTimer);pace.setInterval(16);
    QObject::connect(&pace,&QTimer::timeout,&loop,[&]{
        QElapsedTimer call;call.start();
        step(done++);
        calls.push_back(double(call.nsecsElapsed())/1e6);
        if(done==steps){pace.stop();loop.quit();}
    });
    pace.start();loop.exec();
    const auto lastStep=clock.nsecsElapsed();
    c.endEditGesture();
    // Settled once the picture has held still for 500 ms.
    waitFor([&]{watch();return clock.nsecsElapsed()-std::max(changedAt,lastStep)>500'000'000;});
    heartbeat.stop();
    QObject::disconnect(watching);
    double total=0;for(double v:calls)total+=v;
    std::printf("%-22s steps %3d  call ms: median %7.1f  p95 %7.1f  max %7.1f  sum %8.1f  | loop max gap %7.1f ms"
                "  | pictures %3d  settled %7.1f ms after the last step\n",
                name,steps,percentile(calls,.5),percentile(calls,.95),percentile(calls,1),total,maxGap,pictures,
                changedAt>lastStep?double(changedAt-lastStep)/1e6:0.0);
    std::fflush(stdout);
}
}

int main(int argc,char** argv) {
    qputenv("QT_QPA_PLATFORM","offscreen");
    QGuiApplication application(argc,argv);
    try {
        const auto args=application.arguments();
        require(args.size()==4,"usage: spk_qt_geometry_bench <resources> <RAW> <new-output-directory>");
        const QFileInfo raw(args[2]);const QString destination=QFileInfo(args[3]).absoluteFilePath();
        require(raw.isFile(),"the RAW exists");
        require(!QFileInfo::exists(destination)&&QDir().mkpath(destination+"/fixtures"),"the output directory is new");
        const QString copy=destination+"/fixtures/bench."+raw.suffix();
        require(QFile::copy(raw.absoluteFilePath(),copy),"copy the RAW");
        // Full resolution throughout: no live tier.
        PreviewController c(std::filesystem::path(args[1].toStdWString()),nullptr,{},destination+"/edits",{},0);
        waitFor([&]{return c.ready()||c.failed();});require(c.ready(),"the engine starts");
        c.openRaw(QUrl::fromLocalFile(copy));
        waitFor([&]{return !c.busy()&&c.hasFrame();});require(!c.failed(),"the RAW opens");
        const auto full=c.uncroppedImage().size();
        std::printf("%s: %d x %d, full tier %d\n",qPrintable(raw.fileName()),full.width(),full.height(),int(c.fullResolution()));
        drag(c,"straighten","straightenDegrees",40,[&](int i){c.setStraightenDegrees(.1*(i+1));});
        drag(c,"crop, straightened","cropRect",40,[&](int i){c.setCropRect(QRectF(.05+.002*i,.06+.002*i,.8,.8));});
        c.setStraightenDegrees(0);waitFor([&]{return !c.busy();});
        drag(c,"crop","cropRect",40,[&](int i){c.setCropRect(QRectF(.05+.002*i,.06+.002*i,.8,.8));});
        drag(c,"quarter turns","quarterTurns",8,[&](int){c.rotateClockwise();});
        return 0;
    } catch(const std::exception& e) {
        std::fprintf(stderr,"geometry bench failed: %s\n",e.what());
        return 1;
    }
}
