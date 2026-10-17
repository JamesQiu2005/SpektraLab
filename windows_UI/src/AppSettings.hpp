#pragma once
// The application's own preferences -- the Settings window's values, the
// display colour management choice, the rail widths and which sections are
// open -- as one JSON object in one file. The macOS app keeps the same things
// in UserDefaults (SettingsWindow.swift's @AppStorage keys, Session.uiKey);
// Windows has no shared defaults domain, so this is a file the app owns.
//
// Where the file is (resolveFilePath):
//   --settings-file <path>       exactly that file;
//   an overridden edit store     <edit store>/app-settings.json -- --edit-store,
//                                the --self-test's and --snapshot's own edit
//                                directories -- so a test or a scripted run
//                                never reads or writes the user's preferences
//                                (the Mac's trap 24: a test must not own the
//                                shared store);
//   otherwise                    <AppLocalDataLocation>/app-settings.json, next
//                                to the Edits folder.
//
// The file is a flat object of dotted keys ("display.mode",
// "layout.leftRailWidth"). A key this build does not know is kept as it was
// read and written back unchanged, so an older build never strips a newer
// one's settings. Writes are atomic (QSaveFile: a temporary file renamed over
// the old one) and coalesced: setValue() schedules a write a moment later,
// flush() writes now, and the destructor flushes. A file that cannot be
// parsed is left in place until the first change, then kept beside the new
// one as <file>.bad rather than silently overwritten.
//
// QML reaches the application's instance as the `AppSettings` singleton.
// Bindings read `revision` (as L10n.qml does with the Localizer's) so a value
// shown in two windows follows a change made in either.
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariant>

class AppSettings final:public QObject {
    Q_OBJECT
    Q_PROPERTY(QString filePath READ filePath CONSTANT)
    Q_PROPERTY(int revision READ revision NOTIFY changed)
    // Empty, or the last read or write failure in English, for the Settings
    // window's Diagnostics page.
    Q_PROPERTY(QString lastError READ lastError NOTIFY errorChanged)
public:
    static inline const QString kFileName=QStringLiteral("app-settings.json");

    explicit AppSettings(const QString& filePath,QObject* parent=nullptr);
    ~AppSettings() override;

    // The rule above. `editStoreDirectory` is the overridden edit directory, or
    // empty when the edits go to their default place.
    static QString resolveFilePath(const QString& settingsFile,const QString& editStoreDirectory);
    static QString defaultFilePath();
    // One value straight from a file, without an instance: main() reads the
    // interface scale before QGuiApplication exists (QT_SCALE_FACTOR must be
    // set first). Null when the file or key is absent or unreadable.
    static QVariant readValue(const QString& filePath,const QString& key);

    QString filePath() const {return path_;}
    int revision() const {return revision_;}
    QString lastError() const {return error_;}
    // The object as it will be written, unknown keys included (tests).
    QJsonObject object() const {return root_;}

    Q_INVOKABLE QVariant value(const QString& key,const QVariant& fallback=QVariant()) const;
    Q_INVOKABLE bool contains(const QString& key) const;
    // A null/undefined value removes the key.
    Q_INVOKABLE void setValue(const QString& key,const QVariant& value);
    Q_INVOKABLE void remove(const QString& key);
    // Every key starting with `prefix` (the Settings window's Reset All Layout
    // clears "layout.").
    Q_INVOKABLE void removePrefix(const QString& prefix);
    // Write now if anything changed; true when the file holds the current
    // values afterwards.
    Q_INVOKABLE bool flush();

    // Where a file dialog of `kind` ("open", "exportFolder", "openWith") was
    // last accepted, as the folder to open the next one in. Empty when there
    // is none or the folder has gone (an unplugged drive): the dialog then
    // opens in its own default. Read when a dialog opens, never in a binding,
    // so an offline network folder cannot stall the window.
    Q_INVOKABLE QUrl dialogFolder(const QString& kind) const;
    // Remembers `chosen` for `kind`: a folder as itself, a file as the
    // folder holding it ("dialog.<kind>.folder").
    Q_INVOKABLE void rememberDialogFolder(const QString& kind,const QUrl& chosen);

    // Delay before a scheduled write; 0 writes on every change (tests).
    void setWriteDelayMs(int ms) {timer_.setInterval(ms);}

signals:
    void changed(const QString& key);
    void errorChanged();

private:
    void load();
    void touch(const QString& key);
    void setError(const QString& error);
    QString path_;
    QJsonObject root_;
    QTimer timer_;
    int revision_=0;
    bool dirty_=false,keepBad_=false;
    QString error_;
};
