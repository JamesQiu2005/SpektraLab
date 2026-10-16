#include "FrameCanvas.hpp"
#include "ColorCanvasNode.hpp"
#include "ColorLut.hpp"
#include "ColorPipeline.hpp"
#include <QMouseEvent>
#include <QNativeGestureEvent>
#include <QQuickWindow>
#include <QWheelEvent>
#include <algorithm>
#include <cmath>

namespace canvas=spk::desktop::canvas;

FrameCanvas::FrameCanvas(QQuickItem* parent):QQuickItem(parent) {
    setFlag(ItemHasContents,true);setClip(true);setAcceptedMouseButtons(Qt::LeftButton);
    // Constructed straight into a window: the base constructor's scene change
    // did not reach itemChange() here.
    if(window())attachPipeline(window());
}
canvas::View FrameCanvas::view() const {
    if(follow_)return follow_->view();
    return view_;
}
// The item's size, scale factor and place in the window, read fresh: an
// ancestor moving (a rail resized) moves the item without telling it.
void FrameCanvas::sync() {
    const QSizeF size(width(),height());
    if(size!=view_.canvas||dpr()!=view_.dpr)view_=canvas::resized(view_,size,dpr());
    view_.image=image_.size();
    view_.sceneOrigin=mapToScene(QPointF());
    view_=canvas::clamped(view_);
}
void FrameCanvas::changeView(const canvas::View& next) {
    view_=next;update();emit viewChanged();
}
void FrameCanvas::setPostDev(const QVariantMap& value) {
    if(value==postDev_)return;
    postDev_=value;
    QString error;
    params_=spk::desktop::postdev::paramsFrom(value,&error);
    if(!error.isEmpty())qWarning("FrameCanvas: Post-Dev grade refused, drawing without it: %s",qUtf8Printable(error));
    refreshGrade();update();emit postDevChanged();
}
void FrameCanvas::setSourceMap(const QVariantList& value) {
    const auto map=spk::desktop::postdev::sourceMapFrom(value);
    if(map==sourceMap_)return;
    sourceMap_=map;update();emit postDevChanged();
}
// The grade depends on the parameters and on the image's encoding (its tone
// pivot), so a new image re-derives it; an unchanged result keeps its
// revision, and with it the curve texture already uploaded.
void FrameCanvas::refreshGrade() {
    const auto space=image_.colorSpace().isValid()?image_.colorSpace():QColorSpace(QColorSpace::SRgb);
    const auto next=spk::desktop::postdev::gradeFor(params_,space);
    if(!next){grade_.reset();return;}
    namespace postdev=spk::desktop::postdev;
    if(grade_&&postdev::std140(*grade_)==postdev::std140(*next)&&grade_->tables()==next->tables())return;
    grade_=std::make_shared<const spk::desktop::postdev::Grade>(*next);++grade_revision_;
}
void FrameCanvas::setImage(const QImage& image) {
    if(image.cacheKey()==image_.cacheKey())return;
    const bool changedSize=image.size()!=image_.size();
    const bool changedSpace=image.colorSpace()!=image_.colorSpace();
    image_=image;++revision_;
    if(changedSpace)refreshGrade();
    sync();
    // A new size is a new frame (or a new crop): keep the zoom, centred.
    if(changedSize&&!view_.fit&&view_.dpr>0) {
        const double z=view_.zoom/view_.dpr;
        view_.offset=QPointF((width()-image_.width()*z)*0.5,(height()-image_.height()*z)*0.5);
        view_=canvas::clamped(view_);
    }
    update();emit imageChanged();emit viewChanged();
}
void FrameCanvas::setFit(bool value) {if(value==view_.fit)return;resetView(value);}
void FrameCanvas::resetView(bool value) {
    sync();
    if(value)changeView(canvas::fitted(view_));
    else if(image_.isNull()) {
        // Before any image: 100 %, centred on whatever arrives.
        view_.fit=false;view_.zoom=1;view_.offset={};changeView(view_);
    } else zoomTo(1);
}
double FrameCanvas::dpr() const {return window()?window()->effectiveDevicePixelRatio():1.0;}
double FrameCanvas::scale() const {
    if(image_.isNull()||width()<=0||height()<=0)return 1;
    return canvas::zoomOf(view());
}
double FrameCanvas::scalePercent() const {return image_.isNull()?0:scale()*100;}
QRectF FrameCanvas::imageRect() const {
    if(image_.isNull())return {};
    auto v=view();
    if(follow_){v.image=image_.size();v.sceneOrigin=mapToScene(QPointF());}
    return canvas::imageRect(v);
}
bool FrameCanvas::canZoomIn() const {return !image_.isNull()&&canvas::zoomOf(view())<canvas::kMaxZoom-1e-9;}
bool FrameCanvas::canZoomOut() const {
    if(image_.isNull())return false;
    const auto v=view();
    return canvas::zoomOf(v)>std::min(canvas::fitZoom(v),canvas::kMinZoom)+1e-9;
}
void FrameCanvas::setInteractive(bool value) {
    if(value==interactive_)return;interactive_=value;dragging_=false;emit interactiveChanged();
}
void FrameCanvas::setFollow(FrameCanvas* other) {
    if(other==follow_||other==this)return;
    QObject::disconnect(followChanged_);
    follow_=other;
    if(other)followChanged_=connect(other,&FrameCanvas::viewChanged,this,[this]{update();emit viewChanged();});
    update();emit followChanged();emit viewChanged();
}
void FrameCanvas::panBy(double x,double y) {
    if(view_.fit||image_.isNull())return;
    sync();changeView(canvas::panned(view_,{x,y}));
}
void FrameCanvas::zoomTo(double fraction) {zoomAbout(fraction,width()*0.5,height()*0.5);}
void FrameCanvas::zoomAbout(double fraction,double x,double y) {
    if(image_.isNull()||!std::isfinite(fraction))return;
    sync();
    if(!QRectF(0,0,width(),height()).contains(QPointF(x,y)))x=width()*0.5,y=height()*0.5;
    changeView(canvas::zoomedAbout(view_,fraction,{x,y}));
}
void FrameCanvas::zoomStep(int direction) {
    if(image_.isNull()||direction==0)return;
    sync();zoomTo(canvas::steppedZoom(canvas::zoomOf(view_),direction));
}
void FrameCanvas::toggleHundred(double x,double y) {
    if(image_.isNull())return;
    sync();
    if(!view_.fit&&std::abs(view_.zoom-1)<1e-9)changeView(canvas::fitted(view_));
    else zoomAbout(1,x,y);
}
// The pipeline is created here, on the GUI thread, so that updatePaintNode
// (render thread, GUI blocked) only reads it. changed() can come from the LUT
// builder's thread; the automatic connection queues it to this item.
void FrameCanvas::attachPipeline(QQuickWindow* window) {
    QObject::disconnect(pipelineChanged_);QObject::disconnect(frameSwapped_);
    pipeline_=ColorPipeline::forWindow(window);
    if(pipeline_)pipelineChanged_=connect(pipeline_,&ColorPipeline::changed,this,&QQuickItem::update);
    // An ancestor that moves takes this item to a new physical position
    // without a geometry change here; at a pixel-aligned zoom the image must
    // then be re-snapped to the window's grid. Checked once per frame.
    if(window)frameSwapped_=connect(window,&QQuickWindow::afterAnimating,this,[this]{
        if(image_.isNull()||!isVisible())return;
        const auto origin=mapToScene(QPointF());
        if(origin!=view_.sceneOrigin){view_.sceneOrigin=origin;
            if(canvas::pixelAligned(canvas::zoomOf(view()))){update();emit viewChanged();}}
    });
    update();
}
QVariant FrameCanvas::proof() const {return QVariant::fromValue(proof_);}
void FrameCanvas::setProof(const QVariant& value) {
    const auto next=value.canConvert<ProofTransformPtr>()?value.value<ProofTransformPtr>():ProofTransformPtr();
    if(next==proof_)return;
    proof_=next;update();emit proofChanged();
}
void FrameCanvas::setGamutWarning(bool value) {
    if(value==gamutWarning_)return;
    gamutWarning_=value;update();emit proofChanged();
}
FrameCanvas::PaintColour FrameCanvas::paintColour() const {
    static const auto identity=std::make_shared<const ColorLut>();
    PaintColour colour;
    // An untagged image is sRGB, as it was when the canvas drew it unmanaged.
    const auto space=image_.colorSpace().isValid()?image_.colorSpace():QColorSpace(QColorSpace::SRgb);
    // The proof: the export's transform per pixel, then the display LUT for
    // the recipe space -- once that LUT is this display's (a recipe space is
    // never shown unconverted). An identity proof is the display LUT alone.
    if(pipeline_&&proof_&&spk::color::sameEncoding(space,proof_->source)) {
        if(auto ready=pipeline_->readyLut(proof_->identity?space:proof_->target)) {
            colour.lut=std::move(ready);colour.proofed=true;
            if(!proof_->identity)colour.proof=proof_;
        }
    }
    if(!colour.proofed&&pipeline_)colour.lut=pipeline_->lut(space);
    if(!colour.lut)colour.lut=identity;
    if(colour.proof&&gamutWarning_)
        colour.warning={kGamutWarningColour[0],kGamutWarningColour[1],kGamutWarningColour[2],1.0f};
    return colour;
}
QSGNode* FrameCanvas::updatePaintNode(QSGNode* old,UpdatePaintNodeData*) {
    auto* node=static_cast<ColorCanvasNode*>(old);
    if(image_.isNull()||!window()){delete node;return nullptr;}
    if(!node)node=new ColorCanvasNode;
    // The display LUT, or the proof's while one is set and built.
    const auto colour=paintColour();
    CanvasPaint paint;
    paint.image=image_;paint.revision=revision_;
    paint.lut=colour.lut;paint.proof=colour.proof;paint.warning=colour.warning;
    paint.dither=pipeline_&&pipeline_->dither();
    paint.rect=imageRect();paint.smooth=scale()<1.0;
    paint.grade=grade_;paint.gradeRevision=grade_revision_;paint.sourceMap=sourceMap_;
    if(!node->update(window(),paint)){delete node;return nullptr;}
    return node;
}
void FrameCanvas::geometryChange(const QRectF& next,const QRectF& previous) {
    QQuickItem::geometryChange(next,previous);sync();update();emit viewChanged();
}
void FrameCanvas::itemChange(ItemChange change,const ItemChangeData& data) {
    QQuickItem::itemChange(change,data);
    if(change==ItemSceneChange)attachPipeline(data.window);
    if(change==ItemDevicePixelRatioHasChanged){sync();update();emit viewChanged();}
}
void FrameCanvas::mousePressEvent(QMouseEvent* e) {
    if(!interactive_||image_.isNull()){e->ignore();return;}
    // Pressed to pan; a double-click still arrives at a fitted canvas.
    dragging_=!view_.fit;last_mouse_=e->position();e->accept();
}
void FrameCanvas::mouseMoveEvent(QMouseEvent* e) {if(dragging_){const auto delta=e->position()-last_mouse_;last_mouse_=e->position();panBy(delta.x(),delta.y());e->accept();}else e->ignore();}
void FrameCanvas::mouseReleaseEvent(QMouseEvent* e) {dragging_=false;e->accept();}
void FrameCanvas::mouseUngrabEvent(){dragging_=false;}
void FrameCanvas::mouseDoubleClickEvent(QMouseEvent* e){
    if(!interactive_||image_.isNull()){e->ignore();return;}
    toggleHundred(e->position().x(),e->position().y());e->accept();
}
void FrameCanvas::wheelEvent(QWheelEvent* e) {
    if(!interactive_||image_.isNull()){e->ignore();return;}
    // Pixel deltas from a precision touchpad pan 1:1; a wheel notch is 60 px.
    QPointF delta=!e->pixelDelta().isNull()?QPointF(e->pixelDelta()):QPointF(e->angleDelta())/2.0;
    const auto modifiers=e->modifiers();
    // Shift pans across, Alt up and down (Qt may hand Alt's turn over as a
    // horizontal one, so either axis serves), and a tilted wheel pans
    // across by itself. Everything else zooms.
    const bool across=modifiers&Qt::ShiftModifier||(delta.y()==0&&delta.x()!=0&&!(modifiers&Qt::AltModifier));
    if(across||modifiers&Qt::AltModifier) {
        if(view_.fit){e->ignore();return;}
        const double amount=delta.y()!=0?delta.y():delta.x();
        if(across)panBy(amount,0);else panBy(0,amount);
        e->accept();return;
    }
    // One notch (120) is a quarter stop of magnification, 2^(1/4); a
    // touchpad's fine deltas zoom smoothly by the same law.
    const double notches=e->angleDelta().y()/120.0;
    if(notches!=0){sync();zoomAbout(canvas::zoomOf(view_)*std::exp2(notches/4),e->position().x(),e->position().y());}
    e->accept();
}
bool FrameCanvas::event(QEvent* e) {
    if(e->type()==QEvent::NativeGesture&&interactive_&&!image_.isNull()) {
        auto* gesture=static_cast<QNativeGestureEvent*>(e);
        if(gesture->gestureType()==Qt::ZoomNativeGesture) {
            const auto p=mapFromScene(gesture->scenePosition());
            sync();zoomAbout(canvas::zoomOf(view_)*(1+gesture->value()),p.x(),p.y());
            return true;
        }
    }
    return QQuickItem::event(e);
}
