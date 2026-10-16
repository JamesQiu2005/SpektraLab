// The shipped language tables, every key the QML asks for, and the Localizer's
// rules: English fallback, placeholders, one warning per missing key, external
// overrides and the switch signal. Arguments: the source i18n directory, the
// source qml directory and a scratch directory (inside the build tree) for the
// test's own language files. Needs neither a GPU nor a QML engine.
#include "Localizer.hpp"
#include "Messages.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QRegularExpression>
#include <QSet>
#include <QVariantMap>
#include <cstdio>
#include <stdexcept>

namespace {
int checks=0;
void check(bool value,const char* message) {
    ++checks;
    if(!value)throw std::runtime_error(message);
}
void write(const QString& path,const QByteArray& bytes) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly|QIODevice::Truncate),"cannot write test language file");
    check(file.write(bytes)==bytes.size(),"incomplete test write");
}
QStringList l10nWarnings;
void capture(QtMsgType type,const QMessageLogContext& context,const QString& message) {
    if(type==QtWarningMsg&&QByteArray(context.category?context.category:"")=="spektralab.l10n")l10nWarnings.append(message);
}
int warningsAbout(const QString& text) {
    int count=0;
    for(const auto& message:l10nWarnings)count+=message.contains(text)?1:0;
    return count;
}
} // namespace

int main(int argc,char** argv) {
    QCoreApplication application(argc,argv);
    if(argc!=4){std::fprintf(stderr,"usage: spk_qt_localizer_test <i18n dir> <qml dir> <scratch dir>\n");return 2;}
    const QString i18n=QString::fromLocal8Bit(argv[1]),qml=QString::fromLocal8Bit(argv[2]),scratch=QString::fromLocal8Bit(argv[3]);
    qInstallMessageHandler(capture);
    try {
        // The shipped tables: English loads, is the default, and is complete.
        Localizer localizer;
        check(Localizer::instance()==&localizer,"first localizer is the C++ accessor's");
        check(localizer.loadDirectory(i18n)>=1,"no language table in the i18n directory");
        check(localizer.language()=="en"&&localizer.activeLanguage()=="en","English is not the default");
        const auto english=localizer.keys("en");
        check(english.size()>50,"en.json is missing or nearly empty");
        for(const auto& key:english)check(!localizer.translate(key).isEmpty(),"an English text is empty");
        for(const auto& language:localizer.availableLanguages())
            check(localizer.unknownKeys(language.toMap().value("code").toString()).isEmpty(),"a shipped table has keys en.json lacks");

        // Every key the QML asks for exists in English, and no CJK text is
        // left in QML: the copy lives in the tables.
        const QRegularExpression call(QStringLiteral("L10n\\.tr\\(\\s*\"([^\"]+)\""));
        const QRegularExpression cjk(QStringLiteral("[\\x{3000}-\\x{303F}\\x{4E00}-\\x{9FFF}\\x{FF00}-\\x{FFEF}]"));
        QSet<QString> used;
        for(QDirIterator files(qml,{QStringLiteral("*.qml")},QDir::Files,QDirIterator::Subdirectories);files.hasNext();) {
            QFile file(files.next());
            check(file.open(QIODevice::ReadOnly),"cannot read a QML file");
            const auto source=QString::fromUtf8(file.readAll());
            check(!cjk.match(source).hasMatch(),"CJK text in a QML file");
            // Comment lines may show the call with a made-up key.
            for(const auto& line:source.split(QLatin1Char('\n'))) {
                if(line.trimmed().startsWith(QLatin1String("//")))continue;
                for(auto it=call.globalMatch(line);it.hasNext();) {
                    const auto key=it.next().captured(1);
                    used.insert(key);
                    if(!english.contains(key))std::fprintf(stderr,"QML key not in en.json: %s (%s)\n",qPrintable(key),qPrintable(files.fileName()));
                    check(english.contains(key),"QML asks for a key en.json does not define");
                }
            }
        }
        check(used.size()>50,"QML calls L10n.tr() for almost nothing");

        // The controller's status lines (Messages.hpp) are looked up in the
        // same tables; its English fallback must say exactly what en.json says,
        // or a build without the Localizer would read differently.
        for(const auto& message:spk::desktop::messages::kMessages) {
            const auto key=QString::fromUtf8(message.key);
            if(!english.contains(key)||localizer.translate(key)!=QString::fromUtf8(message.english))
                std::fprintf(stderr,"Messages.hpp and en.json disagree: %s\n",message.key);
            check(english.contains(key),"a Messages.hpp key is not in en.json");
            check(localizer.translate(key)==QString::fromUtf8(message.english),"Messages.hpp's English differs from en.json");
        }

        // Placeholders: {N} by position, repeated or reordered; anything else
        // in braces is text.
        check(Localizer::format("{0} and {1}, {0} again; {2} {x} {} {1",{QStringLiteral("a"),7})=="a and 7, a again; {2} {x} {} {1",
              "placeholder substitution");
        check(localizer.translate("strip.count",{3,1})=="3 photos · 1 selected","English placeholders");

        // A key English lacks shows itself, and is reported once, not on every lookup.
        l10nWarnings.clear();
        check(localizer.translate("no.such.key")=="no.such.key"&&localizer.translate("no.such.key")=="no.such.key",
              "a missing key does not show itself");
        check(warningsAbout("no.such.key")==1,"a missing key is not reported exactly once");
        check(Localizer::text("film.title")==localizer.translate("film.title"),"C++ accessor disagrees with translate()");

        // A test-only language from a folder: listed, selectable, falls back to
        // English per key, reorders placeholders, and switching signals.
        QDir().mkpath(scratch+"/extra");QDir().mkpath(scratch+"/override");
        write(scratch+"/extra/test.json",QStringLiteral(
            "{\"language\": \"xx-Test\", \"name\": \"Testish\", \"englishName\": \"Test language\", \"strings\": {"
            "\"film.title\": \"Filmish\", \"strip.count\": \"{1} of {0}\", \"print.title\": \"\", \"no.such.english\": \"stray\"}}").toUtf8());
        write(scratch+"/extra/broken.json",QByteArrayLiteral("{\"language\": \"yy\", \"strings\": [1, 2"));
        l10nWarnings.clear();
        check(localizer.loadDirectory(scratch+"/extra")==1,"test language not loaded, or a broken file accepted");
        check(warningsAbout("broken.json")==1,"a malformed table is not reported");
        const auto languages=localizer.availableLanguages();
        auto field=[&](int index,const char* name) {return languages[index].toMap().value(QLatin1String(name)).toString();};
        check(languages.size()==2&&field(0,"code")=="en"&&field(1,"code")=="xx-Test"&&
              field(1,"name")=="Testish"&&field(1,"englishName")=="Test language","available languages");
        check(localizer.unknownKeys("xx-Test")==QStringList{"no.such.english"},"a stray key is not found");
        int languageSignals=0,revisionSignals=0;
        QObject::connect(&localizer,&Localizer::languageChanged,[&]{++languageSignals;});
        QObject::connect(&localizer,&Localizer::revisionChanged,[&]{++revisionSignals;});
        const int revision=localizer.revision();
        localizer.setLanguage("xx-Test");
        check(languageSignals==1&&revisionSignals==1&&localizer.revision()!=revision&&localizer.activeLanguage()=="xx-Test",
              "switching does not signal");
        check(localizer.translate("film.title")=="Filmish","the selected language is not used");
        check(localizer.translate("strip.count",{3,1})=="1 of 3","placeholders are not reordered");
        check(localizer.translate("print.title")=="Print"&&localizer.translate("crop.title")=="Crop",
              "an empty or missing translation does not fall back to English");
        localizer.setLanguage("xx-Test");
        check(languageSignals==1&&revisionSignals==1,"setting the same language signals");
        l10nWarnings.clear();
        localizer.setLanguage("zz-Unknown");
        check(languageSignals==1&&localizer.language()=="xx-Test"&&warningsAbout("zz-Unknown")==1,
              "an unknown language is accepted");
        localizer.setLanguage("en");
        check(languageSignals==2&&revisionSignals==2&&localizer.translate("film.title")=="Film","switching back");
        // "system" is allowed, never automatic, and resolves to a table we have.
        localizer.setLanguage("system");
        check(localizer.language()=="system"&&(localizer.activeLanguage()=="en"||localizer.activeLanguage()=="xx-Test"),
              "system resolves to a loaded language");
        localizer.setLanguage("en");

        // An external table for an existing language overrides key by key.
        write(scratch+"/override/en.json",QStringLiteral(
            "{\"language\": \"en\", \"strings\": {\"film.title\": \"Film (override)\"}}").toUtf8());
        const int beforeOverride=localizer.revision();
        check(localizer.loadDirectory(scratch+"/override")==1,"override not loaded");
        check(localizer.revision()!=beforeOverride,"loading a table does not refresh bindings");
        check(localizer.translate("film.title")=="Film (override)","external override not applied");
        check(localizer.translate("crop.title")=="Crop"&&localizer.keys("en").size()==english.size(),
              "an override replaced the whole table instead of merging");
        check(localizer.availableLanguages()[0].toMap().value(QStringLiteral("name")).toString()=="English",
              "an override without a name renamed the language");
    } catch(const std::exception& error) {
        std::fprintf(stderr,"FAIL after %d checks: %s\n",checks,error.what());
        return 1;
    }
    std::printf("localizer: %d checks passed\n",checks);
    return 0;
}
