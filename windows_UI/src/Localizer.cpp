#include "Localizer.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QLocale>
#include <QLoggingCategory>
#include <QVariantMap>
#include <algorithm>

Q_LOGGING_CATEGORY(lcL10n,"spektralab.l10n")

namespace {
Localizer* current=nullptr;
const QString systemSetting=QStringLiteral("system");
}

Localizer::Localizer(QObject* parent):QObject(parent) {if(!current)current=this;}
Localizer::~Localizer() {if(current==this)current=nullptr;}
Localizer* Localizer::instance() {return current;}
QString Localizer::text(const QString& key,const QVariantList& args) {
    return current?current->translate(key,args):format(key,args);
}

bool Localizer::loadFile(const QString& path) {
    QFile file(path);
    if(!file.open(QIODevice::ReadOnly)) {qCWarning(lcL10n).noquote()<<"cannot read"<<path;return false;}
    QJsonParseError error;
    const auto document=QJsonDocument::fromJson(file.readAll(),&error);
    const auto root=document.object();
    const auto strings=root.value(QLatin1String("strings"));
    if(error.error!=QJsonParseError::NoError||!document.isObject()||!strings.isObject()) {
        qCWarning(lcL10n).noquote()<<"skipping"<<path<<"-- not a language table:"<<
            (error.error!=QJsonParseError::NoError?error.errorString():QStringLiteral("no \"strings\" object"));
        return false;
    }
    // The header names the language; the file name is only the fallback, so
    // a translator's "zh-Hans.json" and "chinese.json" mean the same thing.
    auto code=root.value(QLatin1String("language")).toString();
    if(code.isEmpty())code=QFileInfo(path).completeBaseName();
    auto& table=tables_[code];
    const auto name=root.value(QLatin1String("name")).toString();
    const auto englishName=root.value(QLatin1String("englishName")).toString();
    if(!name.isEmpty())table.name=name;
    if(!englishName.isEmpty())table.englishName=englishName;
    if(table.name.isEmpty())table.name=code;
    if(table.englishName.isEmpty())table.englishName=table.name;
    const auto object=strings.toObject();
    for(auto it=object.begin();it!=object.end();++it) {
        if(it.value().isString())table.strings.insert(it.key(),it.value().toString());
        else qCWarning(lcL10n).noquote()<<"skipping non-text value for"<<it.key()<<"in"<<path;
    }
    emit languagesChanged();
    refresh(true);
    return true;
}

int Localizer::loadDirectory(const QString& directory) {
    int loaded=0;
    const auto files=QDir(directory).entryInfoList({QStringLiteral("*.json")},QDir::Files|QDir::Readable,QDir::Name);
    for(const auto& file:files)loaded+=loadFile(file.absoluteFilePath())?1:0;
    return loaded;
}

void Localizer::loadStandardLocations() {
    loadDirectory(QStringLiteral(":/i18n"));
    loadDirectory(QCoreApplication::applicationDirPath()+QStringLiteral("/i18n"));
    for(auto it=tables_.cbegin();it!=tables_.cend();++it)
        for(const auto& key:unknownKeys(it.key()))
            qCWarning(lcL10n).noquote()<<it.key()<<"defines"<<key<<"which en.json does not; it is never shown";
}

void Localizer::setLanguage(const QString& code) {
    if(code==language_)return;
    if(code!=systemSetting&&code!=sourceLanguage&&!tables_.contains(code)) {
        qCWarning(lcL10n).noquote()<<"no table for language"<<code<<"-- keeping"<<language_;
        return;
    }
    language_=code;
    emit languageChanged();
    refresh(false);
}

QVariantList Localizer::availableLanguages() const {
    QVariantList languages;
    auto add=[&](const QString& code,const QString& name,const QString& englishName) {
        languages.append(QVariantMap{{QStringLiteral("code"),code},{QStringLiteral("name"),name},
                                     {QStringLiteral("englishName"),englishName}});
    };
    // English is always available: it is what every lookup falls back to.
    const auto source=tables_.constFind(sourceLanguage);
    if(source==tables_.cend())add(sourceLanguage,QStringLiteral("English"),QStringLiteral("English"));
    else add(sourceLanguage,source->name,source->englishName);
    QStringList others;
    for(auto it=tables_.cbegin();it!=tables_.cend();++it)if(it.key()!=sourceLanguage)others.append(it.key());
    std::sort(others.begin(),others.end(),[this](const QString& a,const QString& b) {
        return tables_[a].englishName.compare(tables_[b].englishName,Qt::CaseInsensitive)<0;
    });
    for(const auto& code:others)add(code,tables_[code].name,tables_[code].englishName);
    return languages;
}

QStringList Localizer::keys(const QString& code) const {
    const auto table=tables_.constFind(code);
    if(table==tables_.cend())return {};
    auto list=table->strings.keys();
    list.sort();
    return list;
}

QStringList Localizer::unknownKeys(const QString& code) const {
    QStringList unknown;
    const auto table=tables_.constFind(code);
    const auto source=tables_.constFind(sourceLanguage);
    if(code==sourceLanguage||table==tables_.cend())return unknown;
    for(auto it=table->strings.cbegin();it!=table->strings.cend();++it)
        if(source==tables_.cend()||!source->strings.contains(it.key()))unknown.append(it.key());
    unknown.sort();
    return unknown;
}

QString Localizer::translate(const QString& key,const QVariantList& args) const {
    for(const auto& code:{active_,sourceLanguage}) {
        const auto table=tables_.constFind(code);
        if(table==tables_.cend())continue;
        const auto text=table->strings.constFind(key);
        if(text!=table->strings.cend()&&!text->isEmpty())return format(*text,args);
    }
    // Showing the key keeps the window usable and makes the gap visible; the
    // warning names it once rather than on every repaint of the label.
    if(!reported_.contains(key)) {
        reported_.insert(key);
        qCWarning(lcL10n).noquote()<<"no English text for key"<<key;
    }
    return format(key,args);
}

QString Localizer::format(const QString& text,const QVariantList& args) {
    QString result;
    result.reserve(text.size());
    for(qsizetype i=0;i<text.size();++i) {
        if(text[i]==QLatin1Char('{')) {
            qsizetype end=i+1;
            while(end<text.size()&&text[end].isDigit())++end;
            if(end>i+1&&end<text.size()&&text[end]==QLatin1Char('}')) {
                bool ok=false;
                const int index=text.mid(i+1,end-i-1).toInt(&ok);
                if(ok&&index<args.size()) {result+=args[index].toString();i=end;continue;}
            }
        }
        result+=text[i];
    }
    return result;
}

QString Localizer::resolve(const QString& setting) const {
    if(setting!=systemSetting)return tables_.contains(setting)?setting:sourceLanguage;
    // The system's UI languages in preference order; the first one there is a
    // table for wins: an exact tag, then a table whose code is a prefix of the
    // tag ("de" for "de-AT"), then one with the same primary language.
    const auto available=[this] {QStringList codes=tables_.keys();if(!codes.contains(sourceLanguage))codes.append(sourceLanguage);return codes;}();
    for(auto tag:QLocale::system().uiLanguages()) {
        tag.replace(QLatin1Char('_'),QLatin1Char('-'));
        const auto primary=tag.section(QLatin1Char('-'),0,0);
        for(const auto& code:available)if(code.compare(tag,Qt::CaseInsensitive)==0)return code;
        for(const auto& code:available)if(tag.startsWith(code+QLatin1Char('-'),Qt::CaseInsensitive))return code;
        for(const auto& code:available)
            if(code.section(QLatin1Char('-'),0,0).compare(primary,Qt::CaseInsensitive)==0)return code;
    }
    return sourceLanguage;
}

void Localizer::refresh(bool textChanged) {
    const auto next=resolve(language_);
    if(next==active_&&!textChanged)return;
    active_=next;
    ++revision_;
    emit revisionChanged();
}
