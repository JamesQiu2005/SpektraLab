// PreviewController's Post-Dev (Layer 2): the open photograph's grade, its
// undo steps, its QML API and the surfaces the controller grades itself (the
// histogram and the filmstrip thumbnail). Kept apart from PreviewController.cpp
// so the editor lanes touch different files; the members are declared in the
// header, and PreviewController.cpp calls in at five places: the constructor
// (setupPostDev), an open's acceptance (loadPostDev), undo/redo, Reset and
// the thumbnail. The canvas, navigator and crop editor grade on the GPU from
// the postDev map (FrameCanvas); the exports grade in PostDevSurfaces.hpp.
//
// The model is the Mac's Session.adjustments (Adjustments.swift): every edit
// is a stored, undoable change of the frame's sidecar, Bypass included
// (SpektrafilmApp.swift:171-173); nothing re-renders, because Layer 2 never
// reaches the engine (Renderer.swift's layer2 pass on the engine's texture).
#include "PreviewController.hpp"
#include "FrameImage.hpp"
#include "PostDevSurfaces.hpp"
#include <QJsonObject>
#include <cmath>

namespace {
namespace desktop=spk::desktop;
namespace postdev=desktop::postdev;

std::optional<postdev::CurveChannel> channelOf(const QString& name) {
    if(name==QLatin1String("rgb"))return postdev::CurveChannel::rgb;
    if(name==QLatin1String("luma"))return postdev::CurveChannel::luma;
    if(name==QLatin1String("red"))return postdev::CurveChannel::red;
    if(name==QLatin1String("green"))return postdev::CurveChannel::green;
    if(name==QLatin1String("blue"))return postdev::CurveChannel::blue;
    return std::nullopt;
}
postdev::ColorZone* zoneOf(postdev::Params& p,const QString& name) {
    auto& cb=p.colorBalance;
    if(name==QLatin1String("master"))return &cb.master;
    if(name==QLatin1String("shadows"))return &cb.shadows;
    if(name==QLatin1String("midtones"))return &cb.midtones;
    if(name==QLatin1String("highlights"))return &cb.highlights;
    return nullptr;
}
// The double a scalar path names in `p`, or null.
double* fieldOf(postdev::Params& p,const QString& path) {
    struct Top {const char* path;double postdev::Params::* member;};
    static const Top top[]={{"temperature",&postdev::Params::temperature},{"tint",&postdev::Params::tint},
        {"exposure",&postdev::Params::exposure},{"contrast",&postdev::Params::contrast},
        {"brightness",&postdev::Params::brightness},{"saturation",&postdev::Params::saturation},
        {"highlights",&postdev::Params::highlights},{"shadows",&postdev::Params::shadows},
        {"blackPoint",&postdev::Params::blackPoint},{"whitePoint",&postdev::Params::whitePoint}};
    for(const auto& t:top)if(path==QLatin1String(t.path))return &(p.*t.member);
    if(path==QLatin1String("vignette.amount"))return &p.vignette.amount;
    if(path==QLatin1String("vignette.midpoint"))return &p.vignette.midpoint;
    const auto parts=path.split(u'.');
    if(parts.size()==3&&parts[0]==QLatin1String("colorBalance"))
        if(auto* zone=zoneOf(p,parts[1])) {
            if(parts[2]==QLatin1String("hue"))return &zone->hue;
            if(parts[2]==QLatin1String("saturation"))return &zone->saturation;
            if(parts[2]==QLatin1String("luminance"))return &zone->luminance;
        }
    return nullptr;
}
const postdev::Field* fieldRow(const QString& path) {
    for(const auto& f:postdev::fields())if(path==QLatin1String(f.path))return &f;
    return nullptr;
}
bool isNumber(const QVariant& v) {
    switch(v.typeId()) {
    case QMetaType::Double: case QMetaType::Float: case QMetaType::Int: case QMetaType::UInt:
    case QMetaType::LongLong: case QMetaType::ULongLong: return true;
    default: return false;
    }
}
}

void PreviewController::setupPostDev() {
    // At most one refresh per 100 ms while a slider streams: the timer is
    // started, not restarted, so a long drag still updates the histogram.
    postdev_refresh_.setSingleShot(true);postdev_refresh_.setInterval(100);
    connect(&postdev_refresh_,&QTimer::timeout,this,&PreviewController::refreshPostDevSurfaces);
    auto schedule=[this]{if(!postdev_refresh_.isActive())postdev_refresh_.start();};
    connect(this,&PreviewController::postDevChanged,this,schedule);
    connect(this,&PreviewController::frameChanged,this,schedule);
    // The histogram's notification: every new picture, and a regraded one.
    connect(this,&PreviewController::frameChanged,this,&PreviewController::histogramChanged);
}

void PreviewController::loadPostDev() {
    const auto next=active_index_>=0&&active_index_<int(library_.size())?library_[active_index_].postdev:postdev::Params{};
    if(next==postdev_)return;
    postdev_=next;emit postDevChanged();
}

bool PreviewController::editPostDev(const postdev::Params& next,const QString& editKey) {
    if(!settingsEditable()||!frame_||active_index_<0||active_index_>=int(library_.size()))return false;
    if(next==postdev_)return true;
    if(gesture_index_>=0&&gesture_key_!=editKey)endEditGesture();
    auto& item=library_[active_index_];
    // Before the change, so undo returns to it; one step per gesture.
    recordEdit(item,itemState(item));
    postdev_=next;item.postdev=next;item.pending_save=true;
    failed_=false;
    scheduleSave();emit postDevChanged();emit historyChanged();
    return true;
}

void PreviewController::refreshPostDevSurfaces() {
    const auto grade=frame_&&!navigator_.isNull()?postdev::gradeFor(postdev_,navigator_.colorSpace()):std::nullopt;
    const bool had=!graded_histogram_.empty();
    if(grade) {
        try {
            QImage graded=navigator_;
            postdev::gradeImage(graded,*grade,
                                postdev::shownSourceMap(frame_,geometry_));
            graded_histogram_=desktop::display::histogram(graded);
        } catch(const std::exception&) {graded_histogram_.clear();}
    } else graded_histogram_.clear();
    if(grade||had)emit histogramChanged();
    // The filmstrip shows the open photograph as the canvas does.
    if(active_index_>=0&&active_index_<int(library_.size())&&!library_[active_index_].thumbnail.isNull())updateThumbnail();
}

QImage PreviewController::gradedThumbnail(QImage thumbnail) const {
    if(thumbnail.isNull()||!frame_)return thumbnail;
    const auto grade=postdev::gradeFor(postdev_,thumbnail.colorSpace());
    if(!grade)return thumbnail;
    try {
        // A thumbnail of the cropped frame: each pixel at its source position.
        postdev::gradeImage(thumbnail,*grade,postdev::shownSourceMap(frame_,geometry_));
    } catch(const std::exception&) {}
    return thumbnail;
}

QVariantMap PreviewController::postDev() const {return postdev::toJson(postdev_).toVariantMap();}

QVariantList PreviewController::postDevSourceMap() const {
    if(!frame_)return {};
    return postdev::toVariant(postdev::shownSourceMap(frame_,geometry_));
}

QVariantList PreviewController::postDevFields() const {
    QVariantList result;
    for(const auto& f:postdev::fields())
        result.push_back(QVariantMap{{"path",QLatin1String(f.path)},{"from",f.low},{"to",f.high},
                                     {"initial",f.initial},{"snap",f.snap}});
    return result;
}

bool PreviewController::setPostDev(const QString& path,const QVariant& value) {
    auto next=postdev_;
    if(path==QLatin1String("enabled")) {
        if(value.typeId()!=QMetaType::Bool)return false;
        next.enabled=value.toBool();
    } else {
        double* field=fieldOf(next,path);
        const auto* row=fieldRow(path);
        if(!field||!row||!isNumber(value))return false;
        const double v=value.toDouble();
        if(!std::isfinite(v)||v<row->low||v>row->high)return false;
        *field=v;
    }
    return editPostDev(next,QStringLiteral("postDev.")+path);
}

bool PreviewController::setColorZone(const QString& zone,double hue,double saturation) {
    auto next=postdev_;
    auto* z=zoneOf(next,zone);
    if(!z||!std::isfinite(hue)||!std::isfinite(saturation)||hue<0||hue>360||saturation<0||saturation>1)return false;
    z->hue=hue;z->saturation=saturation;
    return editPostDev(next,QStringLiteral("postDev.colorBalance.")+zone);
}

bool PreviewController::resetColorZone(const QString& zone) {
    auto next=postdev_;
    auto* z=zoneOf(next,zone);
    if(!z)return false;
    *z=postdev::ColorZone{};
    return editPostDev(next,QStringLiteral("postDev.colorBalance.")+zone+QStringLiteral(".reset"));
}

void PreviewController::resetPostDev(const QString& group) {
    auto next=postdev_;
    const postdev::Params zero;
    // RightSections.swift's section menus, and CameraSection's vignette.
    if(group==QLatin1String("whiteBalance")){next.temperature=0;next.tint=0;}
    else if(group==QLatin1String("exposure")) {
        next.exposure=next.contrast=next.brightness=next.saturation=0;
        next.highlights=next.shadows=next.blackPoint=next.whitePoint=0;
    }
    else if(group==QLatin1String("curves"))next.curves=zero.curves;
    else if(group==QLatin1String("colorBalance"))next.colorBalance=zero.colorBalance;
    else if(group==QLatin1String("vignette"))next.vignette=zero.vignette;
    else if(group.isEmpty()){next=zero;next.enabled=postdev_.enabled;}
    else return;
    editPostDev(next,QStringLiteral("postDev.reset.")+group);
}

void PreviewController::togglePostDevBypass() {
    auto next=postdev_;next.enabled=!next.enabled;
    editPostDev(next,QStringLiteral("postDev.enabled"));
}

QVariantList PreviewController::curveSamples(const QString& channel,int count) const {
    const auto ch=channelOf(channel);
    QVariantList result;
    if(!ch||count<2||count>4096)return result;
    const auto& curve=postdev_.curves[*ch];
    for(int i=0;i<count;++i)result.push_back(curve.evaluate(double(i)/(count-1)));
    return result;
}
double PreviewController::curveValue(const QString& channel,double x) const {
    const auto ch=channelOf(channel);
    return ch&&std::isfinite(x)?postdev_.curves[*ch].evaluate(x):0.0;
}
int PreviewController::curvePointNear(const QString& channel,double x,double y,double width,double height) const {
    const auto ch=channelOf(channel);
    if(!ch)return -1;
    const auto i=postdev_.curves[*ch].indexNear({x,y},postdev::Curve::hitTolerance(width,height));
    return i?*i:-1;
}
bool PreviewController::curvePointDeletable(const QString& channel,int index) const {
    const auto ch=channelOf(channel);
    return ch&&postdev_.curves[*ch].isDeletable(index);
}
int PreviewController::insertCurvePoint(const QString& channel,double x,double y) {
    const auto ch=channelOf(channel);
    if(!ch||!std::isfinite(x)||!std::isfinite(y))return -1;
    auto next=postdev_;
    const int index=next.curves[*ch].insert({x,y});
    if(index<0)return -1;
    return editPostDev(next,QStringLiteral("postDev.curves.")+channel)?index:-1;
}
bool PreviewController::moveCurvePoint(const QString& channel,int index,double x,double y) {
    const auto ch=channelOf(channel);
    if(!ch||!std::isfinite(x)||!std::isfinite(y)||index<0||index>=int(postdev_.curves[*ch].points.size()))return false;
    auto next=postdev_;
    next.curves[*ch].move(index,{x,y});
    return editPostDev(next,QStringLiteral("postDev.curves.")+channel);
}
bool PreviewController::removeCurvePoint(const QString& channel,int index) {
    const auto ch=channelOf(channel);
    if(!ch||!postdev_.curves[*ch].isDeletable(index))return false;
    auto next=postdev_;
    next.curves[*ch].remove(index);
    return editPostDev(next,QStringLiteral("postDev.curves.")+channel);
}
bool PreviewController::resetCurve(const QString& channel) {
    const auto ch=channelOf(channel);
    if(!ch)return false;
    auto next=postdev_;
    next.curves[*ch]=postdev::Curve{};
    return editPostDev(next,QStringLiteral("postDev.curves.")+channel);
}

QVariantMap PreviewController::wheelZoneAt(double x,double y,double diameter) const {
    const auto zone=postdev::wheel::zoneAt(x,y,diameter);
    return {{"hue",zone.hue},{"saturation",zone.saturation}};
}
QPointF PreviewController::wheelPoint(double hue,double saturation,double diameter) const {
    const auto [x,y]=postdev::wheel::pointOf({hue,saturation,0},diameter);
    return {x,y};
}
double PreviewController::arcTheta(double fraction,bool left) const {
    return postdev::wheel::arcTheta(fraction,left?postdev::wheel::Side::left:postdev::wheel::Side::right);
}
double PreviewController::arcValue(double x,double y,double centreX,double centreY,bool left,double low,double high) const {
    return postdev::wheel::arcValue(postdev::wheel::arcAngle(x,y,centreX,centreY),
                                    left?postdev::wheel::Side::left:postdev::wheel::Side::right,low,high);
}
double PreviewController::arcFraction(double value,double low,double high) const {
    return postdev::wheel::arcFraction(value,low,high);
}
