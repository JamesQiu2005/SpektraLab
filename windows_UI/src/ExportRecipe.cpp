#include "ExportRecipe.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>
#include <algorithm>
#include <cmath>

namespace spk::desktop::recipes {

QString formatRaw(Format f) {
    switch(f) {
    case Format::jpeg: return QStringLiteral("JPEG");
    case Format::png: return QStringLiteral("PNG 8-bit");
    case Format::tiff: return QStringLiteral("TIFF 16-bit");
    case Format::di: return QStringLiteral("DI package");
    }
    return {};
}
QString formatLabel(Format f) {
    switch(f) {
    case Format::jpeg: return QStringLiteral("JPEG");
    case Format::png: return QStringLiteral("PNG");
    case Format::tiff: return QStringLiteral("TIFF");
    case Format::di: return QStringLiteral("Digital Intermediate");
    }
    return {};
}
QString formatExtension(Format f) {
    switch(f) {
    case Format::jpeg: return QStringLiteral("jpg");
    case Format::png: return QStringLiteral("png");
    case Format::tiff: case Format::di: return QStringLiteral("tif");
    }
    return {};
}
int formatBitDepth(Format f) { return f==Format::jpeg||f==Format::png?8:16; }
std::optional<Format> withDepth(int depth,Format like) {
    if(like==Format::png&&depth==16)return Format::tiff;
    if(like==Format::tiff&&depth==8)return Format::png;
    return std::nullopt;
}
namespace {
std::optional<Format> formatFromRaw(const QString& raw) {
    for(auto f:{Format::jpeg,Format::png,Format::tiff,Format::di})if(formatRaw(f)==raw)return f;
    return std::nullopt;
}
}

const std::vector<ColorSpaceEntry>& colorSpaces() {
    // ColorSpaceCatalog.builtIns (ExportRecipe.swift:156-162), in its order.
    static const std::vector<ColorSpaceEntry> entries{
        {kDisplayP3,QStringLiteral("Display P3"),"Display P3"},
        {kSRGB,QStringLiteral("sRGB"),"sRGB"},
        {QStringLiteral("kCGColorSpaceAdobeRGB1998"),QStringLiteral("Adobe RGB (1998)"),"Adobe RGB (1998)"},
        {QStringLiteral("kCGColorSpaceROMMRGB"),QStringLiteral("ROMM RGB (ProPhoto)"),"ProPhoto RGB"},
        {QStringLiteral("kCGColorSpaceITUR_2020"),QStringLiteral("Rec. 2020"),"ITU-R BT.2020"},
    };
    return entries;
}
const ColorSpaceEntry* colorSpace(const QString& key) {
    for(const auto& e:colorSpaces())if(e.key==key)return &e;
    return nullptr;
}

QString tokenRaw(Token t) {
    switch(t) {
    case Token::originalName: return QStringLiteral("originalName");
    case Token::filmStock: return QStringLiteral("filmStock");
    case Token::printStock: return QStringLiteral("printStock");
    case Token::date: return QStringLiteral("date");
    }
    return {};
}
QString tokenLabel(Token t) {
    switch(t) {
    case Token::originalName: return QStringLiteral("Original Name");
    case Token::filmStock: return QStringLiteral("Film");
    case Token::printStock: return QStringLiteral("Print");
    case Token::date: return QStringLiteral("Date");
    }
    return {};
}
std::optional<Token> tokenFromRaw(const QString& raw) {
    for(auto t:kAllTokens)if(tokenRaw(t)==raw)return t;
    return std::nullopt;
}

QList<Token> Naming::chosen() const {
    QList<Token> out;
    for(auto t:order)if(tokens.contains(t))out.append(t);
    return out;
}
void Naming::toggle(Token t) {
    if(tokens.contains(t)) {
        if(tokens.size()<=1)return;
        tokens.removeAll(t);
    } else {
        QList<Token> next;
        for(auto o:order)if(tokens.contains(o)||o==t)next.append(o);
        tokens=next;
    }
}
void Naming::move(Token t,Token before) {
    const auto from=order.indexOf(t),to=order.indexOf(before);
    if(t==before||from<0||to<0)return;
    order.removeAt(from);
    order.insert(from<to?to-1:to,t);
    tokens=chosen();
}
QString Naming::stem(const NameContext& c) const {
    QStringList parts;
    for(auto t:chosen()) {
        QString s;
        switch(t) {
        case Token::originalName: s=c.originalName; break;
        case Token::filmStock: s=c.filmStock; break;
        case Token::printStock: s=c.printStock; break;
        case Token::date: s=c.date.toString(QStringLiteral("yyyyMMdd")); break;
        }
        if(!s.isEmpty())parts.append(s);
    }
    QString joined=parts.join(separator);
    if(joined.isEmpty())joined=c.originalName;
    // The Mac replaces "/" and ":"; a Windows name cannot hold these either.
    for(QChar bad:{u'/',u':',u'\\',u'*',u'?',u'"',u'<',u'>',u'|'})joined.replace(bad,u'-');
    return joined;
}
QJsonObject Naming::toJson() const {
    QJsonArray o,t;
    for(auto x:order)o.append(tokenRaw(x));
    for(auto x:tokens)t.append(tokenRaw(x));
    return {{"order",o},{"tokens",t},{"separator",separator}};
}
Naming Naming::fromJson(const QJsonObject& j) {
    Naming n;
    n.separator=j.value("separator").isString()?j.value("separator").toString():QStringLiteral("_");
    QList<Token> known;
    for(const auto& v:j.value("order").toArray())if(auto t=tokenFromRaw(v.toString());t&&!known.contains(*t))known.append(*t);
    for(auto t:kAllTokens)if(!known.contains(t))known.append(t);
    n.order=known;
    QList<Token> on;
    for(const auto& v:j.value("tokens").toArray())if(auto t=tokenFromRaw(v.toString()))on.append(*t);
    if(on.isEmpty())on={Token::originalName};
    n.tokens.clear();
    for(auto t:n.order)if(on.contains(t))n.tokens.append(t);
    return n;
}

QString existingRaw(Existing e) {
    switch(e) {
    case Existing::addSuffix: return QStringLiteral("addSuffix");
    case Existing::overwrite: return QStringLiteral("overwrite");
    case Existing::skip: return QStringLiteral("skip");
    }
    return {};
}
QString existingLabel(Existing e) {
    switch(e) {
    case Existing::addSuffix: return QStringLiteral("Add a suffix");
    case Existing::overwrite: return QStringLiteral("Overwrite");
    case Existing::skip: return QStringLiteral("Skip");
    }
    return {};
}

QJsonObject Metadata::toJson() const {
    QJsonArray f;
    if(camera)f.append("camera");
    if(lens)f.append("lens");
    if(exposure)f.append("exposure");
    if(date)f.append("date");
    return {{"exif",exif},{"fields",f}};
}
Metadata Metadata::fromJson(const QJsonObject& j) {
    Metadata m;
    if(j.value("exif").isBool())m.exif=j.value("exif").toBool();
    if(j.value("fields").isArray()) {
        const auto f=j.value("fields").toArray();
        auto has=[&](const char* k){return f.contains(QJsonValue(QLatin1String(k)));};
        m.camera=has("camera");m.lens=has("lens");m.exposure=has("exposure");m.date=has("date");
    }
    return m;
}

Recipe::Recipe():id(QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper()) {}

int Recipe::clampEdge(int edge) { return std::clamp(edge,16,60000); }

QJsonObject Recipe::toJson() const {
    QJsonObject j;
    j["id"]=id;j["name"]=name;j["format"]=formatRaw(format);
    if(colorSpace.startsWith(QLatin1String("installed:")))
        j["colorSpace"]=QJsonObject{{"installed",QJsonObject{{"path",colorSpace.mid(10)}}}};
    else j["colorSpace"]=QJsonObject{{"builtIn",QJsonObject{{"_0",colorSpace}}}};
    j["folder"]=besideOriginal?QJsonObject{{"besideOriginal",QJsonObject{}}}
                              :QJsonObject{{"fixed",QJsonObject{{"path",folder}}}};
    j["subfolder"]=subfolder;
    j["naming"]=naming.toJson();
    j["existing"]=existingRaw(existing);
    j["quality"]=quality;
    j["outputSize"]=longEdge>0?QJsonObject{{"longEdge",longEdge}}:QJsonObject{{"original",true}};
    if(!openWith.isEmpty())j["openWith"]=QJsonObject{{"path",openWith}};
    j["embedsPreview"]=embedsPreview;
    j["metadata"]=metadata.toJson();
    return j;
}

Recipe Recipe::fromJson(const QJsonObject& j) {
    Recipe r;
    if(QUuid(j.value("id").toString()).isNull()==false)r.id=j.value("id").toString().toUpper();
    if(j.value("name").isString())r.name=j.value("name").toString();
    if(auto f=formatFromRaw(j.value("format").toString()))r.format=*f;
    const auto cs=j.value("colorSpace").toObject();
    if(cs.contains("builtIn")) {
        const auto key=cs.value("builtIn").toObject().value("_0").toString();
        if(!key.isEmpty())r.colorSpace=key;
    } else if(cs.contains("installed")) {
        const auto path=cs.value("installed").toObject().value("path").toString();
        if(!path.isEmpty())r.colorSpace=QStringLiteral("installed:")+path;
    }
    const auto folder=j.value("folder").toObject();
    if(folder.contains("fixed")) {
        const auto path=folder.value("fixed").toObject().value("path").toString();
        if(!path.isEmpty()){r.besideOriginal=false;r.folder=path;}
    }
    if(j.value("subfolder").isString())r.subfolder=j.value("subfolder").toString();
    if(j.value("naming").isObject())r.naming=Naming::fromJson(j.value("naming").toObject());
    for(auto e:{Existing::addSuffix,Existing::overwrite,Existing::skip})
        if(existingRaw(e)==j.value("existing").toString())r.existing=e;
    if(j.value("quality").isDouble())r.quality=std::clamp(j.value("quality").toDouble(),0.1,1.0);
    const auto size=j.value("outputSize").toObject();
    if(size.value("longEdge").isDouble()&&size.value("longEdge").toInt()>0)r.longEdge=clampEdge(size.value("longEdge").toInt());
    else if(size.value("custom").isObject()) {   // the Mac's old two-axis form
        const auto c=size.value("custom").toObject();
        const int e=std::max(c.value("width").toInt(),c.value("height").toInt());
        if(e>0)r.longEdge=clampEdge(e);
    }
    r.openWith=j.value("openWith").toObject().value("path").toString();
    r.embedsPreview=j.value("embedsPreview").toBool(false);
    if(j.value("metadata").isObject())r.metadata=Metadata::fromJson(j.value("metadata").toObject());
    return r;
}

QString Recipe::directory(const QString& source) const {
    const QString base=besideOriginal?QFileInfo(source).absolutePath():folder;
    const QString sub=subfolder.trimmed();
    return sub.isEmpty()?QDir::cleanPath(base):QDir::cleanPath(base+u'/'+sub);
}
QString Recipe::destinationPath(const QString& source,const QString& stem) const {
    const QString dir=directory(source);
    if(format==Format::di)return dir+u'/'+stem+QStringLiteral("_DI.")+formatExtension(format);
    return dir+u'/'+stem+u'.'+formatExtension(format);
}
std::string Recipe::engineSpace(bool* fellBack) const {
    if(fellBack)*fellBack=false;
    if(const auto* e=recipes::colorSpace(colorSpace))return e->engine;
    if(fellBack)*fellBack=true;
    return "Display P3";
}
QString Recipe::colorSpaceName() const {
    if(const auto* e=recipes::colorSpace(colorSpace))return e->name;
    if(colorSpace.startsWith(QLatin1String("installed:")))return QFileInfo(colorSpace.mid(10)).completeBaseName();
    return QStringLiteral("Unknown profile");
}

std::optional<QString> resolveDestination(const Recipe& r,const QString& source,const NameContext& c,
                                          const std::function<bool(const QString&)>& exists) {
    const QString stem=r.naming.stem(c);
    const QString first=r.destinationPath(source,stem);
    if(!exists(first))return first;
    switch(r.existing) {
    case Existing::overwrite: return first;
    case Existing::skip: return std::nullopt;
    case Existing::addSuffix:
        for(int n=1;n<=9999;++n) {
            const QString u=r.destinationPath(source,stem+u'-'+QString::number(n));
            if(!exists(u))return u;
        }
        return first;
    }
    return first;
}

QList<Recipe> defaults() {
    // ExportRecipe.defaults (ExportRecipe.swift:696-702).
    QList<Recipe> out;
    Recipe a;a.name=QString::fromUtf8("JPEG — Display P3");a.format=Format::jpeg;a.colorSpace=kDisplayP3;out.append(a);
    Recipe b;b.name=QString::fromUtf8("TIFF 16-bit — ProPhoto");b.format=Format::tiff;b.colorSpace=QStringLiteral("kCGColorSpaceROMMRGB");out.append(b);
    Recipe c;c.name=QString::fromUtf8("PNG 8-bit — sRGB");c.format=Format::png;c.colorSpace=kSRGB;out.append(c);
    Recipe d;d.name=kDigitalIntermediateName;d.format=Format::di;d.colorSpace=kDisplayP3;out.append(d);
    return out;
}

LoadResult load(const QString& path) {
    LoadResult result;
    QFile file(path);
    if(!file.exists()){result.recipes=defaults();return result;}
    result.existed=true;
    const QString name=QFileInfo(path).fileName();
    if(!file.open(QIODevice::ReadOnly)) {
        result.recipes=defaults();
        result.problem=name+QStringLiteral(" could not be read (")+file.errorString()+
            QStringLiteral("). Using the built-in recipes; your file has not been changed.");
        return result;
    }
    QJsonParseError error{};
    const auto doc=QJsonDocument::fromJson(file.readAll(),&error);
    if(error.error!=QJsonParseError::NoError||!doc.isArray()) {
        result.recipes=defaults();
        result.problem=name+QStringLiteral(" could not be read (")+
            (error.error!=QJsonParseError::NoError?error.errorString():QStringLiteral("not a list of recipes"))+
            QStringLiteral("). Using the built-in recipes; your file has not been changed.");
        return result;
    }
    for(const auto& v:doc.array()) {
        if(!v.isObject())continue;
        auto r=Recipe::fromJson(v.toObject());
        // RecipeStore.load: the DI's two retired built-in names.
        if(r.format==Format::di&&(r.name==QLatin1String("DI package")||r.name==QLatin1String("Digital Intermediate Package")))
            r.name=kDigitalIntermediateName;
        // Two recipes with one id would be one row; the later gets a new id.
        if(std::any_of(result.recipes.begin(),result.recipes.end(),[&](const Recipe& o){return o.id==r.id;}))
            r.id=Recipe().id;
        result.recipes.append(r);
    }
    if(result.recipes.isEmpty())result.recipes=defaults();
    return result;
}

QString save(const QString& path,const QList<Recipe>& recipes) {
    if(!QDir().mkpath(QFileInfo(path).absolutePath()))
        return QStringLiteral("Could not save ")+QFileInfo(path).fileName()+QStringLiteral(": cannot create its folder");
    QJsonArray array;
    for(const auto& r:recipes)array.append(r.toJson());
    QSaveFile file(path);
    if(!file.open(QIODevice::WriteOnly)||file.write(QJsonDocument(array).toJson(QJsonDocument::Indented))<0||!file.commit())
        return QStringLiteral("Could not save ")+QFileInfo(path).fileName()+QStringLiteral(": ")+file.errorString();
    return {};
}

QString storePath(const QString& editDirectory) {
    const QString edits=editDirectory.isEmpty()
        ?QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+QStringLiteral("/Edits"):editDirectory;
    return QFileInfo(QDir::cleanPath(edits)).absolutePath()+QStringLiteral("/export-recipes.json");
}

}  // namespace spk::desktop::recipes
