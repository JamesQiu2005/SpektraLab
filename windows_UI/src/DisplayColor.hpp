#pragma once
#include <QByteArray>
#include <QImage>
#include <QString>
#include <QWindow>

namespace display {
enum class Mode { MonitorProfile, SystemManaged, Unknown };
struct Target { Mode mode=Mode::Unknown; QByteArray profile; QString status; };
Target targetForWindow(QWindow* window);
QImage transformToMonitorProfile(const QImage& image,const QByteArray& profile);
}
