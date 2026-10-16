#pragma once
// Which colour space the canvases are managed to: the ICC profile Windows
// associates with the monitor a window is on, how Windows drives that monitor
// (legacy SDR, Auto Color Management, HDR), and what to fall back to.
// ColorPipeline.cpp asks these questions and ColorLut.* turns the answer into
// a LUT.
//
// Windows sends no notification when a display's profile changes, so the
// pipeline asks again after screen changes, display and setting messages,
// application activation and on a 3 s poll. ProfileSource is the seam: the
// real one calls the Windows APIs, the tests substitute simulated monitors.
#include <QAbstractNativeEventFilter>
#include <QByteArray>
#include <QColorSpace>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <memory>

class QScreen;

namespace spk::color {

// How Windows composes the monitor. Under Auto Color Management (and HDR)
// DWM treats an 8-bit swapchain as sRGB and colour-manages it to the display
// itself, so the canvas must target sRGB there, not the display profile.
enum class DisplayMode { Sdr, AutoColorManaged, Hdr };
QString displayModeName(DisplayMode mode);

// One answer about one monitor.
struct DisplayInfo {
    QString screenId;      // GDI device name, e.g. "\\.\DISPLAY1": the key
    QString monitorName;   // e.g. "DELL U2720Q"; may be empty
    QString profilePath;   // the associated ICC file; empty when there is none
    QByteArray icc;        // its bytes; empty when there is none or it is unreadable
    qint64 profileSize = -1;
    qint64 profileModifiedMs = -1;
    DisplayMode mode = DisplayMode::Sdr;
    QString lookup;        // which query answered, for diagnostics
    QString error;         // English; why no profile could be read
};

class ProfileSource {
public:
    virtual ~ProfileSource() = default;
    // Called on the GUI thread, from a 3 s poll among others: keep it cheap.
    virtual DisplayInfo query(const QString& screenId) = 0;
};

// The Windows queries, in fallback order: ColorProfileGetDisplayDefault
// (Windows 10 20348+ and 11, loaded at run time so older Windows still
// starts), WcsGetDefaultColorProfile, GetICMProfileW. Re-reads a profile file
// only when its path, size or modification time changes. Elsewhere it
// reports no profile.
std::shared_ptr<ProfileSource> systemProfileSource();

// The GDI device name of the monitor `screen` is on; QScreen::name() where
// the platform has no Windows screen (offscreen).
QString screenIdOf(const QScreen* screen);
// Every attached monitor's GDI device name, without Qt.
QStringList systemScreenIds();
// One line per query and its answer for `screenId`, every fallback included
// (not just the first that succeeds): what --probe-display prints.
QStringList describeSystemLookups(const QString& screenId);

struct ProfileFile {
    QString path;
    QByteArray bytes;
    qint64 size = -1;
    qint64 modifiedMs = -1;
    QString error;         // English
};
ProfileFile readProfileFile(const QString& path);

// Whether `icc` can be a canvas target: an RGB profile Qt can transform to
// (matrix/TRC, or with a B2A table). `problem` is English, empty when usable.
struct ProfileCheck {
    QColorSpace space;
    QString problem;
};
ProfileCheck checkDisplayProfile(const QByteArray& icc);

quint64 profileHash(const QByteArray& bytes);

// What the pipeline manages to, and how it describes that.
struct DisplayTarget {
    QColorSpace space;     // always valid: sRGB on every fallback
    QByteArray icc;        // what a worker thread parses `space` from
    quint64 hash = 0;      // of `icc`; the LUT cache key's display half
    QString displayName;
    QString status;
    bool operator==(const DisplayTarget& other) const {
        return hash == other.hash && displayName == other.displayName && status == other.status;
    }
    bool operator!=(const DisplayTarget& other) const { return !(*this == other); }
};
DisplayTarget srgbTarget(const QString& displayName, const QString& status = {});

// The pipeline's decision, given its mode ("automatic", "srgb", "custom"),
// the OS's answer about the window's monitor and the custom profile file.
DisplayTarget resolveTarget(const QString& mode, const DisplayInfo& display, const ProfileFile& custom);

// WM_DISPLAYCHANGE, WM_SETTINGCHANGE and WM_DPICHANGED reach every top-level
// window; one filter for the application turns them into a signal, coalesced
// over 250 ms because a settings change arrives as a burst.
class DisplayChangeNotifier final : public QObject, public QAbstractNativeEventFilter {
    Q_OBJECT
public:
    static DisplayChangeNotifier* instance();
    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result) override;
signals:
    void displayChanged();
private:
    explicit DisplayChangeNotifier(QObject* parent);
    QTimer debounce_;
};

} // namespace spk::color
