#include "AppShell.hpp"

#include "AppSettings.hpp"
#include "ColorPipeline.hpp"
#include "Localizer.hpp"

#include <spektrafilm/spk_engine.h>

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QQuickWindow>
#include <QSet>
#include <QVariantMap>
#include <rhi/qrhi.h>

#ifndef SPEKTRALAB_VERSION
#define SPEKTRALAB_VERSION "0.0.0"
#endif

// --- DisplaySettings ---

DisplaySettings::DisplaySettings(AppSettings& settings,QObject* parent):QObject(parent),settings_(settings) {
    // A change made in any window (or a second Settings page) reaches every
    // pipeline; keys of other groups are not ours.
    connect(&settings_,&AppSettings::changed,this,[this](const QString& key){
        if(key.startsWith(QStringLiteral("display.")))applyAll();
    });
}

void DisplaySettings::attach(QQuickWindow* window) {
    if(!window)return;
    for(const auto& known:windows_)if(known==window)return;
    windows_.emplace_back(window);
    auto* pipeline=ColorPipeline::forWindow(window);
    apply(pipeline);
    connect(pipeline,&ColorPipeline::changed,this,[this,pipeline]{if(pipeline==primary())emit changed();});
    emit changed();
}

ColorPipeline* DisplaySettings::primary() const {
    for(const auto& window:windows_)if(window)return ColorPipeline::forWindow(window);
    return nullptr;
}

void DisplaySettings::apply(ColorPipeline* pipeline) const {
    if(!pipeline)return;
    // The profile before the mode, so switching to "custom" resolves the
    // chosen file once rather than an empty path first.
    if(settings_.contains(kProfileKey))pipeline->setCustomProfilePath(settings_.value(kProfileKey).toString());
    if(settings_.contains(kModeKey)) {
        const auto mode=settings_.value(kModeKey).toString();
        if(mode==QLatin1String("automatic")||mode==QLatin1String("srgb")||mode==QLatin1String("custom"))pipeline->setMode(mode);
    }
    if(settings_.contains(kDitherKey))pipeline->setDither(settings_.value(kDitherKey).toBool());
}

void DisplaySettings::applyAll() {
    for(const auto& window:windows_)if(window)apply(ColorPipeline::forWindow(window));
    emit changed();
}

QString DisplaySettings::mode() const {
    if(auto* p=primary())return p->mode();
    return settings_.value(kModeKey,QStringLiteral("automatic")).toString();
}
void DisplaySettings::setMode(const QString& mode) {settings_.setValue(kModeKey,mode);}
QString DisplaySettings::customProfilePath() const {
    if(auto* p=primary())return p->customProfilePath();
    return settings_.value(kProfileKey).toString();
}
void DisplaySettings::setCustomProfilePath(const QString& path) {settings_.setValue(kProfileKey,QDir::cleanPath(path));}
bool DisplaySettings::dither() const {
    if(auto* p=primary())return p->dither();
    return settings_.value(kDitherKey,true).toBool();
}
void DisplaySettings::setDither(bool dither) {settings_.setValue(kDitherKey,dither);}
QString DisplaySettings::displayName() const {auto* p=primary();return p?p->displayName():QString();}
QString DisplaySettings::status() const {auto* p=primary();return p?p->status():QString();}
QString DisplaySettings::targetDescription() const {
    auto* p=primary();if(!p)return {};
    const auto space=p->targetColorSpace();
    return space.isValid()&&!space.description().isEmpty()?space.description():QStringLiteral("sRGB");
}
void DisplaySettings::reload() {for(const auto& window:windows_)if(window)ColorPipeline::forWindow(window)->reload();}

// --- AppInfo ---

namespace {
struct KnownLicence {const char* file;bool folder;};
// The texts the build deploys beside the executable (engine/CMakeLists.txt,
// build-msvc.ps1, and the volk copy in windows_UI/CMakeLists.txt), in the
// About window's order: the work itself, its data, then what it links.
constexpr KnownLicence kKnownLicences[]={
    {"LICENSE",false},{"SPEKTRAFILM_LICENSE.txt",false},{"PRODUCT_PROFILES_NOTICE.md",false},
    {"LibRaw-LICENSE.LGPL",false},{"LibRaw-LICENSE.CDDL",false},{"LibRaw-COPYRIGHT",false},
    {"Qt-SBOM",true},{"TeX-Gyre-Heros-GUST-FONT-LICENSE.txt",false},{"stb-LICENSE",false},
    {"volk-LICENSE.md",false},{"THIRD_PARTY.md",false}};
constexpr qint64 kMaxLicenceBytes=2*1024*1024;
}

AppInfo::AppInfo(Startup startup,QObject* parent):QObject(parent),startup_(std::move(startup)) {}

QString AppInfo::version() const {return QStringLiteral(SPEKTRALAB_VERSION);}
QString AppInfo::engineBuild() const {return QString::fromUtf8(spk_build_info());}
QString AppInfo::qtVersion() const {return QString::fromLatin1(qVersion());}
QString AppInfo::compiler() const {
#if defined(_MSC_FULL_VER)
    return QStringLiteral("MSVC %1.%2.%3").arg(_MSC_VER/100).arg(_MSC_VER%100,2,10,QLatin1Char('0')).arg(_MSC_FULL_VER%100000);
#elif defined(__clang__)
    return QStringLiteral("Clang %1.%2").arg(__clang_major__).arg(__clang_minor__);
#elif defined(__GNUC__)
    return QStringLiteral("GCC %1.%2").arg(__GNUC__).arg(__GNUC_MINOR__);
#else
    return QStringLiteral("unknown compiler");
#endif
}
QString AppInfo::licencesDirectory() const {return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("licenses"));}

QVariantList AppInfo::licences() const {
    const QDir dir(licencesDirectory());
    QVariantList result;QSet<QString> listed;
    auto add=[&](const QString& file,bool folder){
        const QFileInfo info(dir.filePath(file));
        const bool present=folder?info.isDir():info.isFile();
        result.push_back(QVariantMap{{"file",file},{"folder",folder},{"present",present},
                                     {"size",present&&!folder?info.size():qint64(0)}});
        listed.insert(file);
    };
    for(const auto& known:kKnownLicences)add(QString::fromLatin1(known.file),known.folder);
    // Anything else a later build deploys still appears, by its file name.
    for(const auto& info:dir.entryInfoList(QDir::Files|QDir::Dirs|QDir::NoDotAndDotDot,QDir::Name|QDir::IgnoreCase))
        if(!listed.contains(info.fileName()))add(info.fileName(),info.isDir());
    return result;
}

QString AppInfo::licenceText(const QString& file) const {
    // Only names directly inside the folder: the viewer never reads elsewhere.
    if(file.isEmpty()||file.contains(QLatin1Char('/'))||file.contains(QLatin1Char('\\'))||file.startsWith(QLatin1Char('.')))return {};
    const QDir dir(licencesDirectory());
    const QFileInfo info(dir.filePath(file));
    if(info.isDir()) {
        QStringList lines;
        for(const auto& entry:QDir(info.absoluteFilePath()).entryInfoList(QDir::Files,QDir::Name))
            lines.push_back(QStringLiteral("  %1  (%2)").arg(entry.fileName(),QLocale::c().formattedDataSize(entry.size())));
        return Localizer::text(QStringLiteral("about.folderListing"),
                               {QDir::toNativeSeparators(info.absoluteFilePath()),lines.join(QLatin1Char('\n'))});
    }
    QFile text(info.absoluteFilePath());
    if(!text.open(QIODevice::ReadOnly))return {};
    const auto bytes=text.read(kMaxLicenceBytes);
    auto result=QString::fromUtf8(bytes);
    if(text.size()>kMaxLicenceBytes)result+=QStringLiteral("\n\n[...]");
    return result;
}

QString AppInfo::graphicsSummary(QQuickWindow* window) const {
    if(!window)return {};
    if(auto* rhi=window->rhi()) {
        const auto driver=rhi->driverInfo();
        const QString backend=QString::fromLatin1(rhi->backendName());
        return driver.deviceName.isEmpty()?backend:backend+QStringLiteral(" · ")+QString::fromUtf8(driver.deviceName);
    }
    // QT_QUICK_BACKEND=software (the self-test's and smoke test's backend)
    // is reported by the window's renderer, not by the static default.
    auto* renderer=window->rendererInterface();
    return renderer&&renderer->graphicsApi()==QSGRendererInterface::Software?Localizer::text(QStringLiteral("about.softwareRenderer"))
                                                                            :QString();
}

QString AppInfo::nativePath(const QString& path) const {return QDir::toNativeSeparators(path);}

bool AppInfo::openFolder(const QString& path) const {
    if(path.isEmpty())return false;
    const QFileInfo info(path);
    const QString folder=info.isDir()?info.absoluteFilePath():info.absolutePath();
    if(!QFileInfo(folder).isDir())return false;
    return QDesktopServices::openUrl(QUrl::fromLocalFile(folder));
}

double AppInfo::scaleFactor(const QString& percent) {
    bool ok=false;const int value=percent.toInt(&ok);
    return ok&&value>0?value/115.0:1.0;
}
