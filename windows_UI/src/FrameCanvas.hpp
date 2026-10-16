#pragma once
#include "CanvasMath.hpp"
#include "PostDevView.hpp"
#include <QImage>
#include <QPointer>
#include <QQuickItem>
#include <memory>

class ColorPipeline;

// The picture of the main canvas, the navigator and the filmstrip thumbnails.
// The image is drawn through its window's display LUT (ColorPipeline.hpp,
// ColorCanvasNode.hpp); everything around the image rectangle is left to the
// items behind it.
//
// The view is CanvasMath's: fitted, or a zoom from 5 % to 800 % with the
// macOS steps (ViewportState.swift), panned under the one clamp. A wheel turn
// with Ctrl held, a touchpad pinch (which Windows delivers as Ctrl+wheel) or
// a native zoom gesture zooms about the pointer; a plain wheel pans
// vertically and Shift+wheel horizontally, as a Windows document view does
// (the Mac pans on a plain scroll and zooms with Cmd or Option). A
// double-click toggles fit and 100 % about the pointer (the Mac's Z).
//
// `follow` makes this canvas draw its image in another canvas's rectangle --
// the before/after split's left half, which must sit pixel for pixel on the
// print it is compared with.
//
// `postDev` grades the picture with Post-Dev (Layer 2) between the sample
// and the display LUT (ColorCanvasNode.hpp): the controller's postDev map
// (PostDev.hpp's `state.postDev` shape; empty: no grade), at the tone pivot
// of the image's own encoding (postdev::midGreyFor). `sourceMap` places the
// image on the uncropped source for the vignette (PostDevView.hpp, six
// numbers; empty: the image is the whole source) -- the controller's
// postDevSourceMap for its cropped previewImage and navigatorImage.
class FrameCanvas : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(QVariantMap postDev READ postDev WRITE setPostDev NOTIFY postDevChanged)
    Q_PROPERTY(QVariantList sourceMap READ sourceMap WRITE setSourceMap NOTIFY postDevChanged)
    Q_PROPERTY(bool fit READ fit WRITE setFit NOTIFY viewChanged)
    Q_PROPERTY(double scalePercent READ scalePercent NOTIFY viewChanged)
    Q_PROPERTY(QRectF imageRect READ imageRect NOTIFY viewChanged)
    Q_PROPERTY(bool canZoomIn READ canZoomIn NOTIFY viewChanged)
    Q_PROPERTY(bool canZoomOut READ canZoomOut NOTIFY viewChanged)
    // Off: the canvas takes no wheel or drag (the crop editor's lock).
    Q_PROPERTY(bool interactive READ interactive WRITE setInteractive NOTIFY interactiveChanged)
    Q_PROPERTY(FrameCanvas* follow READ follow WRITE setFollow NOTIFY followChanged)
public:
    explicit FrameCanvas(QQuickItem* parent=nullptr);
    QImage image() const { return image_; }
    void setImage(const QImage& image);
    bool fit() const { return view_.fit; }
    void setFit(bool fit);
    double scalePercent() const;
    QRectF imageRect() const;
    bool canZoomIn() const;
    bool canZoomOut() const;
    bool interactive() const { return interactive_; }
    void setInteractive(bool value);
    FrameCanvas* follow() const { return follow_; }
    void setFollow(FrameCanvas* canvas);
    QVariantMap postDev() const { return postDev_; }
    void setPostDev(const QVariantMap& value);
    QVariantList sourceMap() const { return spk::desktop::postdev::toVariant(sourceMap_); }
    void setSourceMap(const QVariantList& value);
    // The grade the next paint applies (null: none), for tests.
    std::shared_ptr<const spk::desktop::postdev::Grade> grade() const { return grade_; }
    // Fitted, or 100 % about the canvas's centre (Ctrl+0 / Ctrl+1).
    Q_INVOKABLE void resetView(bool fit=true);
    Q_INVOKABLE void panBy(double x,double y);
    // A fraction of 100 % about a point in the item (the centre when the
    // point is outside it), as the zoom menu and the wheel ask.
    Q_INVOKABLE void zoomTo(double fraction);
    Q_INVOKABLE void zoomAbout(double fraction,double x,double y);
    // The next macOS step in or out, about the centre (Ctrl+= / Ctrl+-).
    Q_INVOKABLE void zoomStep(int direction);
    // Fit <-> 100 % about a point (double-click, Z).
    Q_INVOKABLE void toggleHundred(double x,double y);
    // The view, for tests and the harness.
    spk::desktop::canvas::View view() const;
signals:
    void imageChanged();
    void viewChanged();
    void interactiveChanged();
    void followChanged();
    void postDevChanged();
protected:
    QSGNode* updatePaintNode(QSGNode* old,UpdatePaintNodeData*) override;
    void geometryChange(const QRectF& next,const QRectF& previous) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void mouseUngrabEvent() override;
    void mouseDoubleClickEvent(QMouseEvent*) override;
    void wheelEvent(QWheelEvent*) override;
    bool event(QEvent*) override;
    void itemChange(ItemChange,const ItemChangeData&) override;
private:
    double dpr() const;
    double scale() const;
    void sync();
    void changeView(const spk::desktop::canvas::View& next);
    void attachPipeline(QQuickWindow* window);
    void refreshGrade();
    QVariantMap postDev_;
    spk::desktop::postdev::Params params_;
    spk::desktop::postdev::SourceMap sourceMap_;
    std::shared_ptr<const spk::desktop::postdev::Grade> grade_;
    quint64 grade_revision_=0;
    QPointer<ColorPipeline> pipeline_;
    QMetaObject::Connection pipelineChanged_, frameSwapped_;
    QPointer<FrameCanvas> follow_;
    QMetaObject::Connection followChanged_;
    QImage image_;
    quint64 revision_=0;
    spk::desktop::canvas::View view_;
    bool interactive_=true,dragging_=false;
    QPointF last_mouse_;
};
