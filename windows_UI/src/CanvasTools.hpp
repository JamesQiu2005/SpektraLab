#pragma once
// The canvas tools' QML face (singleton "CanvasTools" in SpektraLab.Native):
// CanvasMath's crop arithmetic as invokables, and the held Space key that
// shows the Original for as long as it is down (MetalCanvasView.swift keyDown
// / keyUp, key code 49).
//
// Space is read by an event filter on the editor window rather than by a QML
// Shortcut, which fires on the press alone. It is the Original only when the
// focused item is not one that types or presses on Space (a text field, a
// button, a list, a slider): those keep their Windows meaning. The press is
// then consumed; auto-repeat is ignored; losing the window releases it.
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QRectF>
#include <QSizeF>
#include <QVariant>

class QQuickWindow;

class CanvasTools final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool spaceHeld READ spaceHeld NOTIFY spaceHeldChanged)
public:
    explicit CanvasTools(QObject* parent = nullptr);
    void watch(QQuickWindow* window);
    bool spaceHeld() const { return space_held_; }
    // canvas::CropHandle as an int: -1 outside, 0 the body, 1..8 the grips
    // clockwise from top-left.
    Q_INVOKABLE int cropHandleAt(const QRectF& crop, const QPointF& point, const QSizeF& sourcePx, double tolerancePx) const;
    Q_INVOKABLE QRectF resizedCrop(const QRectF& crop, int handle, const QPointF& point, const QSizeF& sourcePx,
                                   double ratio) const;
    Q_INVOKABLE QRectF movedCrop(const QRectF& crop, const QPointF& delta) const;
    Q_INVOKABLE QRectF drawnCrop(const QPointF& from, const QPointF& to, const QSizeF& sourcePx, double ratio) const;
    // Degrees in output::Geometry's convention, or undefined for a click.
    Q_INVOKABLE QVariant straightenFromLine(const QPointF& a, const QPointF& b, const QSizeF& sourcePx) const;
    // Testing: hold or release as the key would.
    Q_INVOKABLE void setSpaceHeldForTesting(bool held) { setSpaceHeld(held); }
signals:
    void spaceHeldChanged();
protected:
    bool eventFilter(QObject* watched, QEvent* event) override;
private:
    void setSpaceHeld(bool held);
    QPointer<QQuickWindow> window_;
    bool space_held_ = false;
};
