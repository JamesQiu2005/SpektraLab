#include "CanvasTools.hpp"
#include "CanvasMath.hpp"
#include <QKeyEvent>
#include <QQuickItem>
#include <QQuickWindow>

namespace canvas = spk::desktop::canvas;

CanvasTools::CanvasTools(QObject* parent) : QObject(parent) {}

void CanvasTools::watch(QQuickWindow* window) {
    if (window_) window_->removeEventFilter(this);
    window_ = window;
    if (window) window->installEventFilter(this);
}

void CanvasTools::setSpaceHeld(bool held) {
    if (held == space_held_) return;
    space_held_ = held;
    emit spaceHeldChanged();
}

namespace {
// Items for which Space already means something on Windows.
bool usesSpace(const QQuickItem* item) {
    for (; item; item = item->parentItem()) {
        for (const char* type : {"QQuickTextInput", "QQuickTextEdit", "QQuickAbstractButton", "QQuickComboBox",
                                 "QQuickAbstractSlider", "QQuickSlider", "QQuickSpinBox", "QQuickItemView"})
            if (item->inherits(type)) return true;
        // The focused control is what matters, not the window it sits in.
        if (item->inherits("QQuickPopupItem")) return true;
    }
    return false;
}
}  // namespace

bool CanvasTools::eventFilter(QObject* watched, QEvent* event) {
    if (watched == window_) {
        switch (event->type()) {
        case QEvent::KeyPress:
        case QEvent::KeyRelease: {
            auto* key = static_cast<QKeyEvent*>(event);
            if (key->key() != Qt::Key_Space) break;
            const bool press = event->type() == QEvent::KeyPress;
            if (press && !space_held_ && (key->modifiers() != Qt::NoModifier || usesSpace(window_->activeFocusItem())))
                break;
            if (key->isAutoRepeat()) return space_held_;
            if (press || space_held_) {
                setSpaceHeld(press);
                return true;
            }
            break;
        }
        case QEvent::FocusOut:
        case QEvent::WindowDeactivate:
        case QEvent::Hide:
            setSpaceHeld(false);
            break;
        default:
            break;
        }
    }
    return QObject::eventFilter(watched, event);
}

int CanvasTools::cropHandleAt(const QRectF& crop, const QPointF& point, const QSizeF& sourcePx, double tolerancePx) const {
    return int(canvas::cropHandleAt(crop, point, sourcePx, tolerancePx));
}
QRectF CanvasTools::resizedCrop(const QRectF& crop, int handle, const QPointF& point, const QSizeF& sourcePx,
                                double ratio) const {
    if (handle < int(canvas::CropHandle::topLeft) || handle > int(canvas::CropHandle::left)) return crop;
    return canvas::resizedCrop(crop, canvas::CropHandle(handle), point, sourcePx, ratio);
}
QRectF CanvasTools::movedCrop(const QRectF& crop, const QPointF& delta) const { return canvas::movedCrop(crop, delta); }
QRectF CanvasTools::drawnCrop(const QPointF& from, const QPointF& to, const QSizeF& sourcePx, double ratio) const {
    return canvas::drawnCrop(from, to, sourcePx, ratio);
}
QVariant CanvasTools::straightenFromLine(const QPointF& a, const QPointF& b, const QSizeF& sourcePx) const {
    const auto degrees = canvas::straightenFromLine(a, b, sourcePx);
    return degrees ? QVariant(*degrees) : QVariant();
}
