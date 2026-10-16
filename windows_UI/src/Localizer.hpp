#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantList>

// User-visible text by key, from one JSON table per language (i18n/README.md
// is the format). English is the source: every key exists in en.json, and a
// key another language leaves out shows the English. Tables come from the
// compiled-in resources and then from an `i18n` folder beside the executable,
// which a translator can fill without rebuilding; a later file for the same
// language overrides key by key.
//
// QML reaches this object as the `Localizer` singleton, through L10n.qml,
// whose tr() reads `revision` so that every binding showing a string re-runs
// on a language switch. C++ code uses text() (the same tables). Main thread
// only: the tables are not locked.
class Localizer final:public QObject {
    Q_OBJECT
    // "en" (the default), any loaded language code, or "system", which follows
    // the operating system's UI languages and is never chosen automatically.
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // The language text is actually drawn in: `language` with "system" resolved.
    Q_PROPERTY(QString activeLanguage READ activeLanguage NOTIFY revisionChanged)
    // [{code, name, englishName}], English first. `name` is in its own language.
    Q_PROPERTY(QVariantList availableLanguages READ availableLanguages NOTIFY languagesChanged)
    // Changes whenever any text may have changed (a switch, a table loaded).
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
public:
    static inline const QString sourceLanguage=QStringLiteral("en");

    explicit Localizer(QObject* parent=nullptr);
    ~Localizer() override;

    // Merges one table / every *.json in a directory (by file name). A missing
    // directory loads nothing; a malformed file is skipped with a warning.
    bool loadFile(const QString& path);
    int loadDirectory(const QString& directory);
    // ":/i18n" (compiled in), then <application directory>/i18n.
    void loadStandardLocations();

    QString language() const {return language_;}
    void setLanguage(const QString& code);
    QString activeLanguage() const {return active_;}
    QVariantList availableLanguages() const;
    int revision() const {return revision_;}
    QStringList keys(const QString& code) const;
    // Keys a language defines that English does not: misspelt or stale.
    QStringList unknownKeys(const QString& code) const;

    // Not named tr(): Q_OBJECT already declares a static QObject::tr(const
    // char*), which a C++ call with a string literal would silently pick.
    Q_INVOKABLE QString translate(const QString& key,const QVariantList& args={}) const;
    // {0}, {1}... replaced by args; any other brace text is left as it is.
    static QString format(const QString& text,const QVariantList& args);

    // The application's localizer (the first one constructed), for C++ text.
    static Localizer* instance();
    // translate() on instance(); the key itself when there is none.
    static QString text(const QString& key,const QVariantList& args={});

signals:
    void languageChanged();
    void languagesChanged();
    void revisionChanged();

private:
    struct Table {QString name,englishName;QHash<QString,QString> strings;};
    QString resolve(const QString& setting) const;
    void refresh(bool textChanged);
    QHash<QString,Table> tables_;
    QString language_=sourceLanguage,active_=sourceLanguage;
    int revision_=0;
    // Keys already reported missing from English: one warning per key.
    mutable QSet<QString> reported_;
};
