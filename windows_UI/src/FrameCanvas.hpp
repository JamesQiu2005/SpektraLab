#pragma once
#include <QImage>
#include <QQuickItem>
#include <QMetaObject>

class FrameCanvas : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(bool fit READ fit WRITE setFit NOTIFY viewChanged)
    Q_PROPERTY(double scalePercent READ scalePercent NOTIFY viewChanged)
    Q_PROPERTY(QRectF imageRect READ imageRect NOTIFY viewChanged)
    Q_PROPERTY(QString displayColorStatus READ displayColorStatus NOTIFY displayColorChanged)
public:
    explicit FrameCanvas(QQuickItem* parent=nullptr);
    QImage image() const { return image_; }
    void setImage(const QImage& image);
    bool fit() const { return fit_; }
    void setFit(bool fit);
    double scalePercent() const;
    QRectF imageRect() const;
    QString displayColorStatus() const { return display_color_status_; }
    Q_INVOKABLE void resetView(bool fit=true);
    Q_INVOKABLE void panBy(double x,double y);
signals:
    void imageChanged();
    void viewChanged();
    void displayColorChanged();
protected:
    QSGNode* updatePaintNode(QSGNode* old,UpdatePaintNodeData*) override;
    void geometryChange(const QRectF& next,const QRectF& previous) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void mouseUngrabEvent() override;
    void mouseDoubleClickEvent(QMouseEvent*) override;
    void itemChange(ItemChange,const ItemChangeData&) override;
private:
    double dpr() const;
    double scale() const;
    void clampPan();
    void refreshDisplayColor();
    QImage image_;
    QImage display_image_;
    quint64 texture_revision_=0;
    QString display_color_status_=QStringLiteral("显示器色彩状态未知（预览保持 sRGB）");
    QMetaObject::Connection screen_connection_;
    bool fit_=true,dragging_=false;
    QPointF pan_,last_mouse_;
};
