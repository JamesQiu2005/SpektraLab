// The app preferences file (AppSettings.hpp): where it is, a round trip of
// every value type the Settings window stores, coalesced and atomic writes
// (a failed save leaves the previous file byte for byte and no temporary
// behind), keys this build does not know kept as they were, and an unreadable
// file kept as .bad rather than overwritten. Argument: a scratch directory
// inside the build tree; the test never resolves, reads or writes the real
// AppLocalDataLocation file -- it only checks the default path's shape.
#include "AppSettings.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <cstdio>
#include <memory>
#include <stdexcept>

namespace {
int checks=0;
void check(bool value,const char* message) {
    ++checks;
    if(!value)throw std::runtime_error(message);
}
QByteArray readAll(const QString& path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly)?file.readAll():QByteArray();
}
void write(const QString& path,const QByteArray& bytes) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly|QIODevice::Truncate)&&file.write(bytes)==bytes.size(),"cannot write a fixture file");
}
QJsonObject readObject(const QString& path) {return QJsonDocument::fromJson(readAll(path)).object();}
// Everything in the directory but the files the test expects: what a
// non-atomic or interrupted writer would leave behind.
QStringList strays(const QString& directory,const QStringList& expected) {
    QStringList found;
    for(const auto& name:QDir(directory).entryList(QDir::Files|QDir::Hidden|QDir::System))
        if(!expected.contains(name))found.push_back(name);
    return found;
}
} // namespace

int main(int argc,char** argv) {
    QCoreApplication application(argc,argv);
    application.setOrganizationName("SpektraLab");application.setApplicationName("SpektraLab Windows");
    if(argc!=2){std::fprintf(stderr,"usage: spk_qt_app_settings_test <scratch dir>\n");return 2;}
    const QString scratch=QDir(QString::fromLocal8Bit(argv[1])).absolutePath();
    try {
        QDir(scratch).removeRecursively();
        check(QDir().mkpath(scratch),"cannot create the scratch directory");

        // Where the file is: an explicit file wins, an overridden edit store
        // takes it, and only then the user's AppLocalDataLocation.
        const QString explicitFile=QDir(scratch).filePath("explicit/prefs.json");
        const QString editStore=QDir(scratch).filePath("edits");
        check(AppSettings::resolveFilePath(explicitFile,editStore)==QFileInfo(explicitFile).absoluteFilePath(),"--settings-file is not used");
        check(AppSettings::resolveFilePath({},editStore)==QDir(editStore).filePath(AppSettings::kFileName),
              "an overridden edit store does not hold the preferences");
        const QString userFile=AppSettings::resolveFilePath({},{});
        check(userFile==AppSettings::defaultFilePath()&&QFileInfo(userFile).fileName()==AppSettings::kFileName&&
              QFileInfo(userFile).absolutePath()==QFileInfo(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)).absoluteFilePath(),
              "the default is not beside the Edits folder");
        check(!userFile.startsWith(scratch),"the default path is inside the scratch tree");

        // A round trip of every type a page stores, through a new instance.
        const QString path=QDir(editStore).filePath(AppSettings::kFileName);
        {
            AppSettings settings(path);
            check(settings.object().isEmpty()&&settings.lastError().isEmpty()&&!QFileInfo::exists(path),"a first run is not empty and quiet");
            check(settings.value("general.language","en").toString()=="en","a missing key does not return its fallback");
            QStringList spy;QObject::connect(&settings,&AppSettings::changed,[&spy](const QString& key){spy.push_back(key);});
            const int before=settings.revision();
            settings.setValue("general.language",QStringLiteral("en"));
            settings.setValue("display.dither",false);
            settings.setValue("layout.leftRailWidth",312.5);
            settings.setValue("layout.section.film",true);
            settings.setValue("general.interfaceScale",QStringLiteral("130"));
            check(spy.size()==5&&spy.at(1)=="display.dither"&&settings.revision()==before+5,"changes are not announced by key");
            settings.setValue("display.dither",false);
            check(spy.size()==5,"an unchanged value is announced");
            // Coalesced: nothing is written until the delay or a flush.
            check(!QFileInfo::exists(path),"a change was written immediately");
            check(settings.flush()&&QFileInfo::exists(path),"flush did not write");
        }
        {
            AppSettings settings(path);
            check(settings.value("general.language").toString()=="en"&&settings.value("display.dither",true).toBool()==false&&
                  settings.value("layout.leftRailWidth").toDouble()==312.5&&settings.value("layout.section.film").toBool()&&
                  settings.value("general.interfaceScale").toString()=="130","a value did not survive the round trip");
            check(settings.value("display.dither").metaType()==QMetaType::fromType<bool>(),"a bool came back as another type");
            check(AppSettings::readValue(path,"general.interfaceScale").toString()=="130"&&
                  AppSettings::readValue(path,"absent").isNull()&&AppSettings::readValue(path+".none","general.language").isNull(),
                  "the early read before the application object is wrong");
            // The destructor flushes a pending change.
            settings.setValue("display.mode",QStringLiteral("srgb"));
        }
        check(readObject(path).value("display.mode").toString()=="srgb","the destructor did not flush");
        check(strays(QFileInfo(path).absolutePath(),{AppSettings::kFileName}).isEmpty(),"a write left a temporary file");

        // Removal: a key, a null value, and a prefix (Reset All Layout).
        {
            AppSettings settings(path);settings.setWriteDelayMs(0);
            settings.setValue("display.mode",QVariant());
            check(!settings.contains("display.mode")&&!readObject(path).contains("display.mode"),"a null value did not remove the key");
            settings.removePrefix("layout.");
            const auto object=readObject(path);
            check(!object.contains("layout.leftRailWidth")&&!object.contains("layout.section.film")&&object.contains("general.language"),
                  "removePrefix removed the wrong keys");
            // A JavaScript object from QML arrives as a QJSValue.
            QJSEngine engine;
            settings.setValue("ui.object",QVariant::fromValue(engine.evaluate("({a: 1, b: [true, 'x']})")));
            const auto stored=readObject(path).value("ui.object").toObject();
            check(stored.value("a").toInt()==1&&stored.value("b").toArray().size()==2,"a QML object was not stored as JSON");
        }

        // Keys this build does not know are written back unchanged.
        const QString futurePath=QDir(scratch).filePath("future/app-settings.json");
        check(QDir().mkpath(QFileInfo(futurePath).absolutePath()),"cannot create the future directory");
        write(futurePath,R"({"future.panel":{"tabs":[1,2,3],"name":"x"},"display.mode":"srgb","future.flag":true})");
        {
            AppSettings settings(futurePath);settings.setWriteDelayMs(0);
            check(settings.value("display.mode").toString()=="srgb","a stored value was not read");
            settings.setValue("display.mode",QStringLiteral("custom"));
        }
        {
            const auto object=readObject(futurePath);
            check(object.value("display.mode").toString()=="custom"&&object.value("future.flag").toBool()&&
                  object.value("future.panel").toObject().value("tabs").toArray().size()==3&&
                  object.value("future.panel").toObject().value("name").toString()=="x","an unknown key was not kept");
        }

        // Atomic: a save that cannot replace the file (read-only here) fails,
        // says why, and leaves the previous file and no temporary behind.
        const QByteArray previous=readAll(futurePath);
        const auto permissions=QFile::permissions(futurePath);
        check(QFile::setPermissions(futurePath,QFileDevice::ReadOwner|QFileDevice::ReadUser|QFileDevice::ReadGroup|QFileDevice::ReadOther),
              "cannot make the fixture read-only");
        {
            AppSettings settings(futurePath);
            settings.setValue("display.mode",QStringLiteral("automatic"));
            int errors=0;QObject::connect(&settings,&AppSettings::errorChanged,[&errors]{++errors;});
            const bool saved=settings.flush();
            check(!saved&&!settings.lastError().isEmpty()&&errors==1,"a failed save was not reported");
            check(readAll(futurePath)==previous,"a failed save changed the previous file");
            check(strays(QFileInfo(futurePath).absolutePath(),{"app-settings.json"}).isEmpty(),"a failed save left a temporary file");
            check(QFile::setPermissions(futurePath,permissions|QFileDevice::WriteOwner|QFileDevice::WriteUser),"cannot restore the fixture");
            check(settings.flush()&&settings.lastError().isEmpty()&&readObject(futurePath).value("display.mode").toString()=="automatic",
                  "the save did not succeed once the file was writable");
        }

        // An unreadable file: defaults, a warning, and kept as .bad on the
        // first change instead of being overwritten.
        const QString badPath=QDir(scratch).filePath("bad/app-settings.json");
        check(QDir().mkpath(QFileInfo(badPath).absolutePath()),"cannot create the bad directory");
        write(badPath,"{\"display.mode\": \"srgb\",");
        {
            AppSettings settings(badPath);settings.setWriteDelayMs(0);
            check(!settings.lastError().isEmpty()&&settings.object().isEmpty(),"an unreadable file was not reported");
            check(readAll(badPath)=="{\"display.mode\": \"srgb\",","an unreadable file was touched before a change");
            settings.setValue("display.dither",true);
            check(settings.lastError().isEmpty(),"the save after an unreadable file failed");
        }
        check(readAll(badPath+".bad")=="{\"display.mode\": \"srgb\",","the unreadable file was not kept as .bad");
        check(readObject(badPath).value("display.dither").toBool(),"the new file was not written");

        // Dialog folders: a folder is kept as itself, a file as its folder,
        // and one that has gone opens nowhere in particular.
        {
            const QString dialogs=QDir(scratch).filePath("dialogs");
            const QString photos=QDir(dialogs).filePath("photos"),gone=QDir(dialogs).filePath("gone");
            QDir(dialogs).removeRecursively();
            check(QDir().mkpath(photos)&&QDir().mkpath(gone),"cannot create the dialog folders");
            write(QDir(photos).filePath("a.ARW"),"x");
            AppSettings settings(QDir(dialogs).filePath(AppSettings::kFileName));settings.setWriteDelayMs(0);
            check(settings.dialogFolder("open").isEmpty(),"a dialog never used has a folder");
            settings.rememberDialogFolder("open",QUrl::fromLocalFile(QDir(photos).filePath("a.ARW")));
            check(settings.dialogFolder("open")==QUrl::fromLocalFile(photos),"a chosen file does not remember its folder");
            settings.rememberDialogFolder("exportFolder",QUrl::fromLocalFile(gone));
            check(settings.dialogFolder("exportFolder")==QUrl::fromLocalFile(gone)&&settings.dialogFolder("open")==QUrl::fromLocalFile(photos),
                  "a chosen folder is not remembered as itself, or not per kind");
            check(readObject(settings.filePath()).value("dialog.open.folder").toString()==QDir::cleanPath(photos),"a dialog folder is not persisted");
            check(QDir(gone).removeRecursively()&&settings.dialogFolder("exportFolder").isEmpty(),"a folder that has gone is offered");
            settings.rememberDialogFolder("open",QUrl());
            check(settings.dialogFolder("open")==QUrl::fromLocalFile(photos),"a cancelled choice replaced the folder");
        }

        std::printf("spk_qt_app_settings: %d checks passed\n",checks);
        return 0;
    } catch(const std::exception& error) {
        std::fprintf(stderr,"spk_qt_app_settings: FAILED after %d checks: %s\n",checks,error.what());
        return 1;
    }
}
