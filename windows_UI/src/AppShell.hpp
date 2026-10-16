#pragma once
// The application shell's C++ half: what the Settings and About windows and
// the top bar's colour line read that is not the photograph's.
//
//   DisplaySettings   the display colour management choice (ColorPipeline's
//                     mode, custom profile and dither), persisted in
//                     AppSettings and applied to every attached window's
//                     pipeline at start and on every change; plus the editor
//                     window's pipeline state (displayName, status) for the
//                     Settings page and the top bar. QML: `DisplayColour`.
//   AppInfo           version, build, Qt and graphics identity, the deployed
//                     licence texts, the folders the app writes to, and the
//                     interface scale this run started with. QML: `AppInfo`.
//
// The macOS counterparts: SettingsWindow.swift (the pages), AboutWindow.swift
// (the credits and the licence list read from the bundle, never retyped).
#include <QObject>
#include <QPointer>
#include <QString>
#include <QUrl>
#include <QVariantList>
#include <vector>

class AppSettings;
class ColorPipeline;
class QQuickWindow;

class DisplaySettings final:public QObject {
    Q_OBJECT
    // "automatic", "srgb" or "custom" (ColorPipeline.hpp).
    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY changed)
    Q_PROPERTY(QString customProfilePath READ customProfilePath WRITE setCustomProfilePath NOTIFY changed)
    Q_PROPERTY(bool dither READ dither WRITE setDither NOTIFY changed)
    // The editor window's pipeline: what it manages to, and its warning.
    Q_PROPERTY(QString displayName READ displayName NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    // The colour space the canvas draws to, as Qt describes it.
    Q_PROPERTY(QString targetDescription READ targetDescription NOTIFY changed)
public:
    static inline const QString kModeKey=QStringLiteral("display.mode");
    static inline const QString kProfileKey=QStringLiteral("display.customProfilePath");
    static inline const QString kDitherKey=QStringLiteral("display.dither");

    explicit DisplaySettings(AppSettings& settings,QObject* parent=nullptr);

    // Applies the stored choice to the window's pipeline and keeps it applied.
    // The first window attached is the one whose state is reported. A key
    // never stored leaves the pipeline's own default in place.
    void attach(QQuickWindow* window);

    QString mode() const;
    void setMode(const QString& mode);
    QString customProfilePath() const;
    void setCustomProfilePath(const QString& path);
    bool dither() const;
    void setDither(bool dither);
    QString displayName() const;
    QString status() const;
    QString targetDescription() const;

    // Ask Windows about the monitors again now (every attached window).
    Q_INVOKABLE void reload();

signals:
    void changed();

private:
    ColorPipeline* primary() const;
    void apply(ColorPipeline* pipeline) const;
    void applyAll();
    AppSettings& settings_;
    std::vector<QPointer<QQuickWindow>> windows_;
};

class AppInfo final:public QObject {
    Q_OBJECT
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString engineBuild READ engineBuild CONSTANT)
    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)
    Q_PROPERTY(QString compiler READ compiler CONSTANT)
    Q_PROPERTY(QString sourceUrl READ sourceUrl CONSTANT)
    Q_PROPERTY(QString upstreamUrl READ upstreamUrl CONSTANT)
    Q_PROPERTY(QString licencesDirectory READ licencesDirectory CONSTANT)
    Q_PROPERTY(QString settingsFile READ settingsFile CONSTANT)
    Q_PROPERTY(QString editDirectory READ editDirectory CONSTANT)
    // The interface scale (percent, "100" / "115" / "130") this run started
    // with; a changed setting applies at the next start.
    Q_PROPERTY(QString activeInterfaceScale READ activeInterfaceScale CONSTANT)
    // True when QT_SCALE_FACTOR came from the environment, not from Settings.
    Q_PROPERTY(bool interfaceScaleFromEnvironment READ interfaceScaleFromEnvironment CONSTANT)
public:
    struct Startup {
        QString settingsFile,editDirectory,activeInterfaceScale;
        bool interfaceScaleFromEnvironment=false;
    };
    explicit AppInfo(Startup startup,QObject* parent=nullptr);

    QString version() const;
    QString engineBuild() const;
    QString qtVersion() const;
    QString compiler() const;
    QString sourceUrl() const {return QStringLiteral("https://github.com/JamesQiu2005/SpektraLab");}
    QString upstreamUrl() const {return QStringLiteral("https://github.com/andreavolpato/spektrafilm");}
    QString licencesDirectory() const;
    QString settingsFile() const {return startup_.settingsFile;}
    QString editDirectory() const {return startup_.editDirectory;}
    QString activeInterfaceScale() const {return startup_.activeInterfaceScale;}
    bool interfaceScaleFromEnvironment() const {return startup_.interfaceScaleFromEnvironment;}

    // [{file, title, detail, present, folder}] in a fixed order -- the texts
    // this build is expected to carry first, then anything else found in
    // the folder -- so a missing text is listed as missing, not left out.
    Q_INVOKABLE QVariantList licences() const;
    // The text of one entry of licences(); for a folder (the Qt SBOMs) a
    // listing of what it holds and which licence they record.
    Q_INVOKABLE QString licenceText(const QString& file) const;
    // "Direct3D 11 · <adapter>" for the window's scene graph, or the
    // software renderer.
    Q_INVOKABLE QString graphicsSummary(QQuickWindow* window) const;
    Q_INVOKABLE QString localPath(const QUrl& url) const {return url.toLocalFile();}
    Q_INVOKABLE QString nativePath(const QString& path) const;
    // Open a folder (or a file's folder) in Explorer. Only on a click.
    Q_INVOKABLE bool openFolder(const QString& path) const;

    // The interface scale choices and their QT_SCALE_FACTOR (the Mac's 115 %
    // is the editor's own drawing, so it is factor 1 here).
    static QStringList interfaceScales() {return {QStringLiteral("100"),QStringLiteral("115"),QStringLiteral("130")};}
    static double scaleFactor(const QString& percent);

private:
    Startup startup_;
};
