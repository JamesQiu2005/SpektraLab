#include "AppSettings.hpp"

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QJsonDocument>
#include <QJsonValue>
#include <QSaveFile>
#include <QStandardPaths>

AppSettings::AppSettings(const QString& filePath,QObject* parent)
    :QObject(parent),path_(QFileInfo(filePath).absoluteFilePath()) {
    // A drag on a rail edge sets its width on every pointer move; one write
    // when the drag pauses is enough.
    timer_.setSingleShot(true);
    timer_.setInterval(400);
    connect(&timer_,&QTimer::timeout,this,[this]{flush();});
    load();
}

AppSettings::~AppSettings() {flush();}

QString AppSettings::defaultFilePath() {
    return QDir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)).filePath(kFileName);
}

QString AppSettings::resolveFilePath(const QString& settingsFile,const QString& editStoreDirectory) {
    if(!settingsFile.isEmpty())return QFileInfo(settingsFile).absoluteFilePath();
    if(!editStoreDirectory.isEmpty())return QDir(QFileInfo(editStoreDirectory).absoluteFilePath()).filePath(kFileName);
    return defaultFilePath();
}

QVariant AppSettings::readValue(const QString& filePath,const QString& key) {
    QFile file(filePath);
    if(!file.open(QIODevice::ReadOnly))return {};
    const auto document=QJsonDocument::fromJson(file.readAll());
    if(!document.isObject())return {};
    const auto value=document.object().value(key);
    return value.isUndefined()||value.isNull()?QVariant():value.toVariant();
}

void AppSettings::load() {
    QFile file(path_);
    if(!file.exists())return;   // a first run: every value is its default
    if(!file.open(QIODevice::ReadOnly)) {
        setError(QStringLiteral("Cannot read the settings file %1: %2").arg(QDir::toNativeSeparators(path_),file.errorString()));
        return;
    }
    QJsonParseError parse{};
    const auto document=QJsonDocument::fromJson(file.readAll(),&parse);
    if(parse.error!=QJsonParseError::NoError||!document.isObject()) {
        keepBad_=true;
        setError(QStringLiteral("The settings file %1 could not be read (%2); defaults are in use, and it will be kept as %3 "
                                "when a setting changes.")
                     .arg(QDir::toNativeSeparators(path_),
                          parse.error!=QJsonParseError::NoError?parse.errorString():QStringLiteral("not a JSON object"),
                          QFileInfo(path_).fileName()+QStringLiteral(".bad")));
        return;
    }
    root_=document.object();
}

QVariant AppSettings::value(const QString& key,const QVariant& fallback) const {
    const auto found=root_.constFind(key);
    return found==root_.constEnd()||found->isNull()||found->isUndefined()?fallback:found->toVariant();
}

bool AppSettings::contains(const QString& key) const {return root_.contains(key);}

void AppSettings::setValue(const QString& key,const QVariant& value) {
    // From QML a value may arrive as a QJSValue (an object or array literal).
    const QVariant plain=value.metaType()==QMetaType::fromType<QJSValue>()?value.value<QJSValue>().toVariant():value;
    const auto json=QJsonValue::fromVariant(plain);
    if(json.isNull()||json.isUndefined()) {remove(key);return;}
    if(root_.value(key)==json)return;
    root_.insert(key,json);
    touch(key);
}

void AppSettings::remove(const QString& key) {
    if(!root_.contains(key))return;
    root_.remove(key);
    touch(key);
}

QUrl AppSettings::dialogFolder(const QString& kind) const {
    const QString folder=value(QStringLiteral("dialog.%1.folder").arg(kind)).toString();
    return !folder.isEmpty()&&QFileInfo(folder).isDir()?QUrl::fromLocalFile(folder):QUrl();
}

void AppSettings::rememberDialogFolder(const QString& kind,const QUrl& chosen) {
    const QString path=chosen.toLocalFile();
    if(path.isEmpty())return;
    const QFileInfo info(path);
    setValue(QStringLiteral("dialog.%1.folder").arg(kind),QDir::cleanPath(info.isDir()?info.absoluteFilePath():info.absolutePath()));
}

void AppSettings::removePrefix(const QString& prefix) {
    QStringList gone;
    for(auto it=root_.constBegin();it!=root_.constEnd();++it)if(it.key().startsWith(prefix))gone.push_back(it.key());
    for(const auto& key:gone)remove(key);
}

void AppSettings::touch(const QString& key) {
    dirty_=true;++revision_;
    emit changed(key);
    if(timer_.interval()<=0)flush();
    else timer_.start();
}

bool AppSettings::flush() {
    timer_.stop();
    if(!dirty_)return error_.isEmpty();
    const QFileInfo info(path_);
    if(!QDir().mkpath(info.absolutePath())) {
        setError(QStringLiteral("Cannot create the settings folder %1").arg(QDir::toNativeSeparators(info.absolutePath())));
        return false;
    }
    if(keepBad_) {
        // Keep what could not be parsed rather than destroying it.
        const QString bad=path_+QStringLiteral(".bad");
        QFile::remove(bad);
        QFile::copy(path_,bad);
        keepBad_=false;
    }
    QSaveFile file(path_);
    if(!file.open(QIODevice::WriteOnly)) {
        setError(QStringLiteral("Cannot write the settings file %1: %2").arg(QDir::toNativeSeparators(path_),file.errorString()));
        return false;
    }
    file.write(QJsonDocument(root_).toJson(QJsonDocument::Indented));
    if(!file.commit()) {
        setError(QStringLiteral("Cannot save the settings file %1: %2").arg(QDir::toNativeSeparators(path_),file.errorString()));
        return false;
    }
    dirty_=false;
    setError({});
    return true;
}

void AppSettings::setError(const QString& error) {
    if(error==error_)return;
    error_=error;
    if(!error.isEmpty())qWarning().noquote()<<error;
    emit errorChanged();
}
