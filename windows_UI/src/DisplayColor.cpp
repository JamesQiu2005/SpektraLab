#include "DisplayColor.hpp"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QScreen>
#include <QtEndian>
#include <algorithm>

#ifdef Q_OS_WIN
#include <QtGui/qscreen_platform.h>
#include <windows.h>
#include <icm.h>
#include <string>
#include <vector>
#endif

namespace spk::color {

QString displayModeName(DisplayMode mode) {
    switch (mode) {
    case DisplayMode::Sdr: return QStringLiteral("SDR");
    case DisplayMode::AutoColorManaged: return QStringLiteral("SDR with Auto Color Management");
    case DisplayMode::Hdr: return QStringLiteral("HDR");
    }
    return {};
}

quint64 profileHash(const QByteArray& bytes) {
    const QByteArray digest = QCryptographicHash::hash(bytes, QCryptographicHash::Sha256);
    return qFromBigEndian<quint64>(digest.constData());
}

ProfileFile readProfileFile(const QString& path) {
    // Larger than any display profile; a mistaken pick of a photograph or a
    // video should not be read whole every time the poll looks at it.
    constexpr qint64 kLargestProfile = 64ll << 20;
    ProfileFile file;
    file.path = path;
    if (path.isEmpty()) {
        file.error = QStringLiteral("no file is selected");
        return file;
    }
    const QFileInfo info(path);
    if (!info.isFile()) {
        file.error = QStringLiteral("the file does not exist");
        return file;
    }
    file.size = info.size();
    file.modifiedMs = info.lastModified().toMSecsSinceEpoch();
    if (file.size > kLargestProfile) {
        file.error = QStringLiteral("the file is too large to be an ICC profile");
        return file;
    }
    QFile reader(path);
    if (!reader.open(QIODevice::ReadOnly)) {
        file.error = QStringLiteral("the file cannot be read (%1)").arg(reader.errorString());
        return file;
    }
    file.bytes = reader.readAll();
    return file;
}

ProfileCheck checkDisplayProfile(const QByteArray& icc) {
    ProfileCheck check;
    const auto fail = [&](const QString& problem) {
        check.space = QColorSpace();
        check.problem = problem;
        return check;
    };
    if (icc.isEmpty()) return fail(QStringLiteral("the profile is empty"));
    // The header starts with the profile's own length. Qt reports a cut-off
    // copy only as unreadable; saying "truncated" tells the user what to fix.
    if (icc.size() < 128) return fail(QStringLiteral("the profile is truncated (%1 bytes, shorter than an ICC header)").arg(icc.size()));
    const quint32 declared = qFromBigEndian<quint32>(icc.constData());
    if (declared > quint32(icc.size()))
        return fail(QStringLiteral("the profile is truncated (%1 of %2 bytes)").arg(icc.size()).arg(declared));
    check.space = QColorSpace::fromIccProfile(icc);
    if (!check.space.isValid()) return fail(QStringLiteral("Qt cannot read this ICC profile"));
    switch (check.space.colorModel()) {
    case QColorSpace::ColorModel::Rgb: break;
    case QColorSpace::ColorModel::Cmyk: return fail(QStringLiteral("it is a CMYK profile, not a display profile"));
    case QColorSpace::ColorModel::Gray: return fail(QStringLiteral("it is a greyscale profile"));
    default: return fail(QStringLiteral("it is not an RGB profile"));
    }
    if (!check.space.isValidTarget())
        return fail(QStringLiteral("it has no transform into the display (an A2B-only profile)"));
    return check;
}

DisplayTarget srgbTarget(const QString& displayName, const QString& status) {
    static const QByteArray icc = QColorSpace(QColorSpace::SRgb).iccProfile();
    static const quint64 hash = profileHash(icc);
    DisplayTarget target;
    target.space = QColorSpace(QColorSpace::SRgb);
    target.icc = icc;
    target.hash = hash;
    target.displayName = displayName;
    target.status = status;
    return target;
}

namespace {

// Verbatim from the approved plan; the checkbox name is Windows' own wording.
const char* const kAcmStatus =
    "Windows Auto Color Management is on: the canvas is limited to sRGB; enable "
    "'Use legacy display ICC color management' for full gamut";

QString monitorLabel(const DisplayInfo& display) {
    if (!display.monitorName.isEmpty()) return display.monitorName;
    if (!display.screenId.isEmpty()) return display.screenId;
    return QStringLiteral("Display");
}

DisplayTarget fromProfile(const ProfileCheck& check, const QByteArray& icc, const QString& displayName,
                          const QString& status) {
    DisplayTarget target;
    target.space = check.space;
    target.icc = icc;
    target.hash = profileHash(icc);
    target.displayName = displayName;
    target.status = status;
    return target;
}

} // namespace

DisplayTarget resolveTarget(const QString& mode, const DisplayInfo& display, const ProfileFile& custom) {
    if (mode == QLatin1String("srgb")) return srgbTarget(QStringLiteral("sRGB (assumed)"));
    if (mode == QLatin1String("custom")) {
        const QString fallback = QStringLiteral("sRGB (fallback)");
        if (custom.path.isEmpty())
            return srgbTarget(fallback, QStringLiteral("No custom display profile is selected. Showing sRGB instead."));
        const QString name = QFileInfo(custom.path).fileName();
        const auto unusable = [&](const QString& problem) {
            return srgbTarget(fallback, QStringLiteral("The custom display profile \"%1\" cannot be used: %2. "
                                                       "Showing sRGB instead.").arg(name, problem));
        };
        if (!custom.error.isEmpty()) return unusable(custom.error);
        const ProfileCheck check = checkDisplayProfile(custom.bytes);
        if (!check.problem.isEmpty()) return unusable(check.problem);
        // An explicit choice is honoured, but under ACM or HDR Windows
        // converts the canvas again after it; say so rather than hide it.
        const QString status = display.mode == DisplayMode::Sdr ? QString()
            : QStringLiteral("Windows is colour-managing this display itself (%1); the custom profile is "
                             "applied before that.").arg(displayModeName(display.mode));
        return fromProfile(check, custom.bytes, QStringLiteral("Custom - ") + name, status);
    }
    const QString prefix = mode == QLatin1String("automatic") ? QString()
        : QStringLiteral("Unknown display colour mode \"%1\"; using automatic. ").arg(mode);
    const QString monitor = monitorLabel(display);
    if (display.mode == DisplayMode::Hdr)
        return srgbTarget(monitor + QStringLiteral(" - sRGB (HDR display)"),
                          prefix + QStringLiteral("HDR is on for this display: the canvas is shown as sRGB until HDR "
                                                  "output is supported."));
    if (display.mode == DisplayMode::AutoColorManaged)
        return srgbTarget(monitor + QStringLiteral(" - sRGB (Windows Auto Color Management)"),
                          prefix + QLatin1String(kAcmStatus));
    if (display.profilePath.isEmpty()) {
        // Windows itself treats a display without a profile as sRGB; that
        // is not a warning unless a query failed on the way.
        const QString status = display.error.isEmpty() ? QString()
            : display.error + QStringLiteral(". Showing sRGB instead.");
        return srgbTarget(monitor + QStringLiteral(" - sRGB (no display profile)"), (prefix + status).trimmed());
    }
    const QString name = QFileInfo(display.profilePath).fileName();
    const QString fallback = monitor + QStringLiteral(" - sRGB (fallback)");
    if (!display.error.isEmpty())
        return srgbTarget(fallback, prefix + display.error + QStringLiteral(". Showing sRGB instead."));
    const ProfileCheck check = checkDisplayProfile(display.icc);
    if (!check.problem.isEmpty())
        return srgbTarget(fallback, prefix + QStringLiteral("The display profile \"%1\" cannot be used: %2. "
                                                            "Showing sRGB instead.").arg(name, check.problem));
    return fromProfile(check, display.icc, monitor + QStringLiteral(" - ") + name, prefix.trimmed());
}

#ifdef Q_OS_WIN
namespace {

std::wstring wide(const QString& text) { return text.toStdWString(); }

// mscms.dll, resolved once and kept loaded. The ColorProfile* functions exist
// only from Windows 10 build 20348; importing them would stop the application
// from starting on older Windows, so every entry point is optional.
struct Mscms {
    using DisplayUserScopeFn = HRESULT(WINAPI*)(LUID, UINT32, WCS_PROFILE_MANAGEMENT_SCOPE*);
    using DisplayDefaultFn = HRESULT(WINAPI*)(WCS_PROFILE_MANAGEMENT_SCOPE, LUID, UINT32, COLORPROFILETYPE,
                                              COLORPROFILESUBTYPE, LPWSTR*);
    using UsePerUserProfilesFn = BOOL(WINAPI*)(LPCWSTR, DWORD, PBOOL);
    using DefaultProfileSizeFn = BOOL(WINAPI*)(WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, COLORPROFILETYPE,
                                               COLORPROFILESUBTYPE, DWORD, PDWORD);
    using DefaultProfileFn = BOOL(WINAPI*)(WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, COLORPROFILETYPE,
                                           COLORPROFILESUBTYPE, DWORD, DWORD, LPWSTR);
    using ColorDirectoryFn = BOOL(WINAPI*)(PCWSTR, PWSTR, PDWORD);

    DisplayUserScopeFn displayUserScope = nullptr;
    DisplayDefaultFn displayDefault = nullptr;
    UsePerUserProfilesFn usePerUserProfiles = nullptr;
    DefaultProfileSizeFn defaultProfileSize = nullptr;
    DefaultProfileFn defaultProfile = nullptr;
    ColorDirectoryFn colorDirectory = nullptr;

    static const Mscms& get() {
        static const Mscms instance;
        return instance;
    }

private:
    template <typename F>
    static F resolve(HMODULE module, const char* name) {
        return reinterpret_cast<F>(reinterpret_cast<void*>(GetProcAddress(module, name)));
    }
    Mscms() {
        const HMODULE module = LoadLibraryExW(L"mscms.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) return;
        displayUserScope = resolve<DisplayUserScopeFn>(module, "ColorProfileGetDisplayUserScope");
        displayDefault = resolve<DisplayDefaultFn>(module, "ColorProfileGetDisplayDefault");
        usePerUserProfiles = resolve<UsePerUserProfilesFn>(module, "WcsGetUsePerUserProfiles");
        defaultProfileSize = resolve<DefaultProfileSizeFn>(module, "WcsGetDefaultColorProfileSize");
        defaultProfile = resolve<DefaultProfileFn>(module, "WcsGetDefaultColorProfile");
        colorDirectory = resolve<ColorDirectoryFn>(module, "GetColorDirectoryW");
    }
};

// DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 as the 10.0.26100 SDK declares it.
// The SDK hides it below NTDDI_WIN11_GA, and Qt's build may target an older
// NTDDI; the call itself simply fails on Windows that predates it.
struct AdvancedColorInfo2 {
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value;
    UINT32 colorEncoding;
    UINT32 bitsPerColorChannel;
    UINT32 activeColorMode; // 0 SDR, 1 WCG (Auto Color Management), 2 HDR
};
static_assert(sizeof(AdvancedColorInfo2) == 36);
constexpr auto kGetAdvancedColorInfo2 = DISPLAYCONFIG_DEVICE_INFO_TYPE(15);

struct DisplayPath {
    bool found = false;
    LUID adapter{};          // the target's adapter: what ColorProfile* and the colour info take
    UINT32 sourceId = 0;
    UINT32 targetId = 0;
    QString monitorName;
};

DisplayPath findPath(const QString& gdiName) {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    LONG status = ERROR_SUCCESS;
    do {
        UINT32 pathCount = 0, modeCount = 0;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount) != ERROR_SUCCESS) return {};
        paths.resize(pathCount);
        modes.resize(modeCount);
        status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount, modes.data(), nullptr);
        paths.resize(pathCount);
    } while (status == ERROR_INSUFFICIENT_BUFFER); // the topology changed between the two calls
    if (status != ERROR_SUCCESS) return {};
    for (const auto& path : paths) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source.header.size = sizeof(source);
        source.header.adapterId = path.sourceInfo.adapterId;
        source.header.id = path.sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) continue;
        if (QString::fromWCharArray(source.viewGdiDeviceName).compare(gdiName, Qt::CaseInsensitive) != 0) continue;
        // In clone mode several targets share a source; the first decides.
        DisplayPath result;
        result.found = true;
        result.adapter = path.targetInfo.adapterId;
        result.sourceId = path.sourceInfo.id;
        result.targetId = path.targetInfo.id;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
        target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        target.header.size = sizeof(target);
        target.header.adapterId = path.targetInfo.adapterId;
        target.header.id = path.targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&target.header) == ERROR_SUCCESS)
            result.monitorName = QString::fromWCharArray(target.monitorFriendlyDeviceName);
        return result;
    }
    return {};
}

DisplayMode advancedColorMode(const DisplayPath& path, QString* how) {
    AdvancedColorInfo2 info2{};
    info2.header.type = kGetAdvancedColorInfo2;
    info2.header.size = sizeof(info2);
    info2.header.adapterId = path.adapter;
    info2.header.id = path.targetId;
    if (DisplayConfigGetDeviceInfo(&info2.header) == ERROR_SUCCESS) {
        *how = QStringLiteral("ADVANCED_COLOR_INFO_2: active mode %1, flags 0x%2, %3 bits")
                   .arg(info2.activeColorMode).arg(info2.value, 0, 16).arg(info2.bitsPerColorChannel);
        if (info2.activeColorMode == 2) return DisplayMode::Hdr;
        if (info2.activeColorMode == 1) return DisplayMode::AutoColorManaged;
        return DisplayMode::Sdr;
    }
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info{};
    info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
    info.header.size = sizeof(info);
    info.header.adapterId = path.adapter;
    info.header.id = path.targetId;
    if (DisplayConfigGetDeviceInfo(&info.header) == ERROR_SUCCESS) {
        *how = QStringLiteral("ADVANCED_COLOR_INFO: flags 0x%1, %2 bits").arg(info.value, 0, 16).arg(info.bitsPerColorChannel);
        // Before _INFO_2, Windows 11 reports ACM as advanced colour enabled
        // with wide colour enforced, and HDR as enabled without it.
        const bool enabled = info.value & 0x2u, wideColorEnforced = info.value & 0x4u;
        if (!enabled) return DisplayMode::Sdr;
        return wideColorEnforced ? DisplayMode::AutoColorManaged : DisplayMode::Hdr;
    }
    *how = QStringLiteral("advanced colour state unavailable; assuming SDR");
    return DisplayMode::Sdr;
}

QString colorDirectory() {
    if (const auto query = Mscms::get().colorDirectory) {
        wchar_t buffer[MAX_PATH + 1] = {};
        DWORD bytes = sizeof(buffer) - sizeof(wchar_t);
        if (query(nullptr, buffer, &bytes)) return QDir::fromNativeSeparators(QString::fromWCharArray(buffer));
    }
    return QDir::fromNativeSeparators(qEnvironmentVariable("SystemRoot") + QStringLiteral("/System32/spool/drivers/color"));
}

QString profilePath(const QString& name) {
    if (name.isEmpty() || QDir::isAbsolutePath(name)) return QDir::fromNativeSeparators(name);
    return colorDirectory() + QLatin1Char('/') + name;
}

struct Lookup {
    QString name;  // file name or path, empty when this query has no answer
    QString how;   // which query, and what it said
};

Lookup lookupDisplayDefault(const DisplayPath& path) {
    const auto& mscms = Mscms::get();
    if (!mscms.displayUserScope || !mscms.displayDefault)
        return {{}, QStringLiteral("ColorProfileGetDisplayDefault: not available on this Windows")};
    if (!path.found) return {{}, QStringLiteral("ColorProfileGetDisplayDefault: no active display path for this monitor")};
    WCS_PROFILE_MANAGEMENT_SCOPE scope = WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE;
    HRESULT result = mscms.displayUserScope(path.adapter, path.sourceId, &scope);
    const QString scopeName = FAILED(result) ? QStringLiteral("system scope; user scope query failed")
        : scope == WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER ? QStringLiteral("user scope") : QStringLiteral("system scope");
    if (FAILED(result)) scope = WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE;
    LPWSTR name = nullptr;
    result = mscms.displayDefault(scope, path.adapter, path.sourceId, CPT_ICC, CPST_STANDARD_DISPLAY_COLOR_MODE, &name);
    if (FAILED(result) || !name) {
        if (name) LocalFree(name);
        return {{}, QStringLiteral("ColorProfileGetDisplayDefault (%1): HRESULT 0x%2")
                        .arg(scopeName).arg(quint32(result), 8, 16, QLatin1Char('0'))};
    }
    Lookup lookup{QString::fromWCharArray(name), QStringLiteral("ColorProfileGetDisplayDefault (%1)").arg(scopeName)};
    LocalFree(name);
    return lookup;
}

Lookup lookupWcs(const QString& gdiName) {
    const auto& mscms = Mscms::get();
    if (!mscms.usePerUserProfiles || !mscms.defaultProfileSize || !mscms.defaultProfile)
        return {{}, QStringLiteral("WcsGetDefaultColorProfile: not available")};
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    // Device 0 under an adapter's GDI name is its monitor; WCS keys monitor
    // associations by that monitor's registry key.
    if (!EnumDisplayDevicesW(wide(gdiName).c_str(), 0, &device, 0))
        return {{}, QStringLiteral("WcsGetDefaultColorProfile: no monitor device under %1").arg(gdiName)};
    BOOL perUser = FALSE;
    if (!mscms.usePerUserProfiles(device.DeviceKey, CLASS_MONITOR, &perUser)) perUser = FALSE;
    const auto scope = perUser ? WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER : WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE;
    const QString scopeName = perUser ? QStringLiteral("user scope") : QStringLiteral("system scope");
    DWORD bytes = 0;
    if (!mscms.defaultProfileSize(scope, device.DeviceKey, CPT_ICC, CPST_PERCEPTUAL, 0, &bytes) || bytes == 0)
        return {{}, QStringLiteral("WcsGetDefaultColorProfile (%1): no default profile, error %2").arg(scopeName).arg(GetLastError())};
    std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
    if (!mscms.defaultProfile(scope, device.DeviceKey, CPT_ICC, CPST_PERCEPTUAL, 0, bytes, buffer.data()))
        return {{}, QStringLiteral("WcsGetDefaultColorProfile (%1): error %2").arg(scopeName).arg(GetLastError())};
    return {QString::fromWCharArray(buffer.data()), QStringLiteral("WcsGetDefaultColorProfile (%1)").arg(scopeName)};
}

Lookup lookupIcm(const QString& gdiName) {
    // An information context is enough to ask; it is cheaper than a DC.
    const std::wstring device = wide(gdiName);
    const HDC context = CreateICW(device.c_str(), nullptr, nullptr, nullptr);
    if (!context) return {{}, QStringLiteral("GetICMProfileW: no device context for %1").arg(gdiName)};
    DWORD characters = 0;
    GetICMProfileW(context, &characters, nullptr);
    std::vector<wchar_t> buffer(std::max<DWORD>(characters, MAX_PATH) + 1, L'\0');
    characters = DWORD(buffer.size() - 1);
    const BOOL ok = GetICMProfileW(context, &characters, buffer.data());
    DeleteDC(context);
    if (!ok) return {{}, QStringLiteral("GetICMProfileW: error %1").arg(GetLastError())};
    return {QString::fromWCharArray(buffer.data()), QStringLiteral("GetICMProfileW")};
}

QString adapterMonitorName(const QString& gdiName) {
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    if (!EnumDisplayDevicesW(wide(gdiName).c_str(), 0, &device, 0)) return {};
    return QString::fromWCharArray(device.DeviceString);
}

class WindowsProfileSource final : public ProfileSource {
public:
    DisplayInfo query(const QString& screenId) override {
        DisplayInfo info;
        info.screenId = screenId;
        const DisplayPath path = findPath(screenId);
        info.monitorName = !path.monitorName.isEmpty() ? path.monitorName : adapterMonitorName(screenId);
        QString modeHow = QStringLiteral("no active display path; assuming SDR");
        if (path.found) info.mode = advancedColorMode(path, &modeHow);
        Lookup lookup = lookupDisplayDefault(path);
        if (lookup.name.isEmpty()) lookup = lookupWcs(screenId);
        if (lookup.name.isEmpty()) lookup = lookupIcm(screenId);
        info.lookup = lookup.how + QStringLiteral("; ") + modeHow;
        if (lookup.name.isEmpty()) return info;
        info.profilePath = profilePath(lookup.name);
        const QFileInfo file(info.profilePath);
        if (!file.isFile()) {
            info.error = QStringLiteral("Windows names the display profile \"%1\", but the file does not exist").arg(lookup.name);
            return info;
        }
        info.profileSize = file.size();
        info.profileModifiedMs = file.lastModified().toMSecsSinceEpoch();
        // The poll asks every 3 s; read the bytes only when the file changed.
        if (cached_.path != info.profilePath || cached_.size != info.profileSize ||
            cached_.modifiedMs != info.profileModifiedMs || !cached_.error.isEmpty())
            cached_ = readProfileFile(info.profilePath);
        if (!cached_.error.isEmpty())
            info.error = QStringLiteral("The display profile \"%1\" cannot be read: %2").arg(file.fileName(), cached_.error);
        info.icc = cached_.bytes;
        return info;
    }

private:
    ProfileFile cached_;
};

BOOL CALLBACK collectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (GetMonitorInfoW(monitor, &info)) reinterpret_cast<QStringList*>(data)->append(QString::fromWCharArray(info.szDevice));
    return TRUE;
}

} // namespace

std::shared_ptr<ProfileSource> systemProfileSource() {
    static const auto source = std::make_shared<WindowsProfileSource>();
    return source;
}

QString screenIdOf(const QScreen* screen) {
    if (!screen) return {};
    if (auto* native = const_cast<QScreen*>(screen)->nativeInterface<QNativeInterface::QWindowsScreen>()) {
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        if (GetMonitorInfoW(native->handle(), &info)) return QString::fromWCharArray(info.szDevice);
    }
    return screen->name();
}

QStringList systemScreenIds() {
    QStringList ids;
    EnumDisplayMonitors(nullptr, nullptr, collectMonitor, reinterpret_cast<LPARAM>(&ids));
    return ids;
}

QStringList describeSystemLookups(const QString& screenId) {
    QStringList lines;
    const DisplayPath path = findPath(screenId);
    if (path.found)
        lines << QStringLiteral("display path: adapter %1:%2, source %3, target %4, monitor \"%5\"")
                     .arg(path.adapter.HighPart).arg(path.adapter.LowPart).arg(path.sourceId).arg(path.targetId)
                     .arg(path.monitorName);
    else
        lines << QStringLiteral("display path: none active for %1").arg(screenId);
    QString modeHow = QStringLiteral("no active display path");
    if (path.found) {
        const DisplayMode mode = advancedColorMode(path, &modeHow);
        modeHow = displayModeName(mode) + QStringLiteral(" (") + modeHow + QStringLiteral(")");
    }
    lines << QStringLiteral("advanced colour: ") + modeHow;
    for (const Lookup& lookup : {lookupDisplayDefault(path), lookupWcs(screenId), lookupIcm(screenId)})
        lines << lookup.how + QStringLiteral(": ") +
                     (lookup.name.isEmpty() ? QStringLiteral("(no answer)") : profilePath(lookup.name));
    return lines;
}

#else

namespace {
class NoProfileSource final : public ProfileSource {
public:
    DisplayInfo query(const QString& screenId) override {
        DisplayInfo info;
        info.screenId = screenId;
        info.lookup = QStringLiteral("display profiles are only queried on Windows");
        return info;
    }
};
} // namespace

std::shared_ptr<ProfileSource> systemProfileSource() {
    static const auto source = std::make_shared<NoProfileSource>();
    return source;
}
QString screenIdOf(const QScreen* screen) { return screen ? screen->name() : QString(); }
QStringList systemScreenIds() { return {}; }
QStringList describeSystemLookups(const QString&) { return {QStringLiteral("display profiles are only queried on Windows")}; }

#endif

DisplayChangeNotifier* DisplayChangeNotifier::instance() {
    static QPointer<DisplayChangeNotifier> notifier;
    if (!notifier && QCoreApplication::instance()) {
        notifier = new DisplayChangeNotifier(QCoreApplication::instance());
        QCoreApplication::instance()->installNativeEventFilter(notifier);
    }
    return notifier;
}

DisplayChangeNotifier::DisplayChangeNotifier(QObject* parent) : QObject(parent) {
    debounce_.setSingleShot(true);
    debounce_.setInterval(250);
    connect(&debounce_, &QTimer::timeout, this, &DisplayChangeNotifier::displayChanged);
}

bool DisplayChangeNotifier::nativeEventFilter(const QByteArray& eventType, void* message, qintptr*) {
#ifdef Q_OS_WIN
    if (eventType == "windows_generic_MSG") {
        const UINT id = static_cast<const MSG*>(message)->message;
        if (id == WM_DISPLAYCHANGE || id == WM_SETTINGCHANGE || id == WM_DPICHANGED) debounce_.start();
    }
#else
    Q_UNUSED(eventType);
    Q_UNUSED(message);
#endif
    return false;
}

} // namespace spk::color
