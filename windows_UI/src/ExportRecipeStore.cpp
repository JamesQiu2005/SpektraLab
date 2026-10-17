#include "ExportRecipeStore.hpp"
#include <QClipboard>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QSet>
#include <functional>

namespace recipes = spk::desktop::recipes;

ExportRecipeStore::ExportRecipeStore(QString path,QObject* parent):QObject(parent),path_(std::move(path)) {
    auto loaded=recipes::load(path_);
    recipes_=std::move(loaded.recipes);problem_=loaded.problem;
    // Seeded on first run, so the file exists from the first launch rather
    // than after the first edit (ExportRecipeStore.init).
    if(problem_.isEmpty()&&!loaded.existed)persist();
}

QVariantList ExportRecipeStore::recipes() const {
    QVariantList out;
    for(const auto& r:recipes_)out.append(QVariantMap{{"id",r.id},{"name",r.name}});
    return out;
}

QStringList ExportRecipeStore::formatLabels() const {
    QStringList out;
    for(auto f:{recipes::Format::jpeg,recipes::Format::png,recipes::Format::tiff,recipes::Format::di})out.append(recipes::formatLabel(f));
    return out;
}
QStringList ExportRecipeStore::colorSpaceNames() const {
    QStringList out;for(const auto& e:recipes::colorSpaces())out.append(e.name);return out;
}
QStringList ExportRecipeStore::existingLabels() const {
    QStringList out;
    for(auto e:{recipes::Existing::addSuffix,recipes::Existing::overwrite,recipes::Existing::skip})out.append(recipes::existingLabel(e));
    return out;
}

QVariantMap ExportRecipeStore::selected() const {
    const auto& r=current();
    int space=-1;
    for(int i=0;i<int(recipes::colorSpaces().size());++i)if(recipes::colorSpaces()[i].key==r.colorSpace)space=i;
    QVariantList chips;
    for(auto t:r.naming.order)chips.append(QVariantMap{{"token",recipes::tokenRaw(t)},{"label",recipes::tokenLabel(t)},{"on",r.naming.isOn(t)}});
    QString openLabel=QStringLiteral("None");
    if(r.openWith==QLatin1String("default"))openLabel=QStringLiteral("Default App");
    else if(r.openWith==QLatin1String("explorer"))openLabel=QStringLiteral("File Explorer");
    else if(!r.openWith.isEmpty())openLabel=QFileInfo(r.openWith).completeBaseName();
    return {
        {"id",r.id},{"name",r.name},
        {"format",int(r.format)},{"formatLabel",recipes::formatLabel(r.format)},
        {"bitDepth",recipes::formatBitDepth(r.format)},
        {"depthChoosable",r.format==recipes::Format::png||r.format==recipes::Format::tiff},
        {"takesColorSpace",recipes::takesColorSpace(r.format)},{"takesQuality",recipes::takesQuality(r.format)},
        {"carriesPreviewPage",recipes::carriesPreviewPage(r.format)},{"isDI",r.format==recipes::Format::di},
        {"extension",recipes::formatExtension(r.format)},
        {"colorSpaceIndex",space},{"colorSpaceName",r.colorSpaceName()},{"colorSpaceKey",r.colorSpace},
        {"besideOriginal",r.besideOriginal},{"folder",QDir::toNativeSeparators(r.folder)},
        {"folderLabel",r.besideOriginal?QStringLiteral("Beside the original"):QFileInfo(r.folder).fileName()},
        {"subfolder",r.subfolder},{"chips",chips},{"tokenCount",int(r.naming.tokens.size())},
        {"existing",int(r.existing)},{"existingLabel",recipes::existingLabel(r.existing)},
        {"quality",r.quality},{"longEdge",r.longEdge},
        {"openWith",r.openWith},{"openWithLabel",openLabel},
        {"embedsPreview",r.embedsPreview},
        {"exif",r.metadata.exif},{"exifCamera",r.metadata.camera},{"exifLens",r.metadata.lens},
        {"exifExposure",r.metadata.exposure},{"exifDate",r.metadata.date},
    };
}
QVariantMap ExportRecipeStore::selectedJson() const { return current().toJson().toVariantMap(); }

void ExportRecipeStore::persist() {
    problem_=recipes::save(path_,recipes_);
}
void ExportRecipeStore::edit(const std::function<void(recipes::Recipe&)>& change) {
    auto next=recipes_[selected_];
    change(next);
    if(next==recipes_[selected_])return;
    recipes_[selected_]=std::move(next);
    persist();emit changed();
}

void ExportRecipeStore::select(int index) {
    if(index<0||index>=recipes_.size()||index==selected_)return;
    selected_=index;emit changed();
}
void ExportRecipeStore::add() {
    recipes::Recipe r;recipes_.append(r);selected_=int(recipes_.size())-1;persist();emit changed();
}
void ExportRecipeStore::duplicate() {
    auto copy=current();copy.id=recipes::Recipe().id;copy.name+=QStringLiteral(" copy");
    recipes_.append(copy);selected_=int(recipes_.size())-1;persist();emit changed();
}
void ExportRecipeStore::remove() {
    // Removing the last recipe would leave the page nothing to show.
    if(recipes_.size()<2)return;
    recipes_.removeAt(selected_);selected_=0;persist();emit changed();
}
void ExportRecipeStore::rename(const QString& name) {
    const auto trimmed=name.trimmed();
    if(trimmed.isEmpty())return;
    edit([&](auto& r){r.name=trimmed;});
}
void ExportRecipeStore::setFormat(int index) {
    if(index<0||index>3)return;
    edit([&](auto& r){r.format=recipes::Format(index);});
}
void ExportRecipeStore::setDepth(int bits) {
    if(auto f=recipes::withDepth(bits,current().format))edit([&](auto& r){r.format=*f;});
}
void ExportRecipeStore::setColorSpace(int index) {
    if(index<0||index>=int(recipes::colorSpaces().size()))return;
    edit([&](auto& r){r.colorSpace=recipes::colorSpaces()[std::size_t(index)].key;});
}
void ExportRecipeStore::setBesideOriginal() { edit([](auto& r){r.besideOriginal=true;}); }
void ExportRecipeStore::setFolder(const QUrl& folder) {
    const auto path=folder.toLocalFile();
    if(path.isEmpty())return;
    edit([&](auto& r){r.besideOriginal=false;r.folder=QDir::cleanPath(path);});
}
void ExportRecipeStore::setSubfolder(const QString& s) { edit([&](auto& r){r.subfolder=s;}); }
void ExportRecipeStore::toggleToken(const QString& token) {
    if(auto t=recipes::tokenFromRaw(token))edit([&](auto& r){r.naming.toggle(*t);});
}
void ExportRecipeStore::moveToken(const QString& token,const QString& before) {
    const auto t=recipes::tokenFromRaw(token),b=recipes::tokenFromRaw(before);
    if(t&&b)edit([&](auto& r){r.naming.move(*t,*b);});
}
void ExportRecipeStore::originalNameOnly() {
    edit([](auto& r){r.naming.tokens={recipes::Token::originalName};});
}
void ExportRecipeStore::selectAllTokens() { edit([](auto& r){r.naming.tokens=r.naming.order;}); }
void ExportRecipeStore::resetTokenOrder() {
    edit([](auto& r){r.naming.resetOrder();r.naming.tokens=r.naming.chosen();});
}
void ExportRecipeStore::setExisting(int index) {
    if(index<0||index>2)return;
    edit([&](auto& r){r.existing=recipes::Existing(index);});
}
void ExportRecipeStore::setQuality(double q) {
    if(!(q>=0.1&&q<=1.0))return;
    edit([&](auto& r){r.quality=q;});
}
void ExportRecipeStore::setLongEdge(int edge) {
    edit([&](auto& r){r.longEdge=edge<=0?0:recipes::Recipe::clampEdge(edge);});
}
void ExportRecipeStore::setOpenWith(const QString& v) { edit([&](auto& r){r.openWith=v;}); }
void ExportRecipeStore::setOpenWithApplication(const QUrl& exe) {
    const auto path=exe.toLocalFile();
    if(!path.isEmpty())setOpenWith(QDir::toNativeSeparators(path));
}
void ExportRecipeStore::setEmbedsPreview(bool on) { edit([&](auto& r){r.embedsPreview=on;}); }
void ExportRecipeStore::setMetadata(const QString& field,bool on) {
    edit([&](auto& r){
        if(field==QLatin1String("exif"))r.metadata.exif=on;
        else if(field==QLatin1String("camera"))r.metadata.camera=on;
        else if(field==QLatin1String("lens"))r.metadata.lens=on;
        else if(field==QLatin1String("exposure"))r.metadata.exposure=on;
        else if(field==QLatin1String("date"))r.metadata.date=on;
    });
}

QString ExportRecipeStore::sampleName(const QUrl& url,const QString& film,const QString& paper) const {
    const auto& r=current();
    const QString source=url.toLocalFile();
    recipes::NameContext c;
    // NamingRule.sampleContext when nothing is open.
    c.originalName=source.isEmpty()?QStringLiteral("_DSC4037"):QFileInfo(source).completeBaseName();
    c.filmStock=source.isEmpty()&&film.isEmpty()?QStringLiteral("portra400"):film;
    c.printStock=source.isEmpty()&&paper.isEmpty()?QStringLiteral("endura"):paper;
    const auto stem=r.naming.stem(c);
    return r.format==recipes::Format::di?stem+QStringLiteral("_DI.tif"):stem+u'.'+recipes::formatExtension(r.format);
}

QUrl ExportRecipeStore::folderUrl() const {
    const auto& r=current();
    return !r.besideOriginal&&!r.folder.isEmpty()&&QFileInfo(r.folder).isDir()?QUrl::fromLocalFile(r.folder):QUrl();
}
QStringList ExportRecipeStore::destinationFolders(const QVariantList& sources) const {
    QStringList out;QSet<QString> seen;
    for(const auto& v:sources) {
        const QString s=v.toUrl().toLocalFile();
        if(s.isEmpty())continue;
        const auto d=QDir::toNativeSeparators(current().directory(s));
        if(!seen.contains(d.toCaseFolded())){seen.insert(d.toCaseFolded());out.append(d);}
    }
    return out;
}

void ExportRecipeStore::reveal(const QString& folder) const {
    QString u=QDir::cleanPath(QDir::fromNativeSeparators(folder));
    while(!u.isEmpty()&&!QFileInfo(u).isDir()) {
        const auto parent=QFileInfo(u).absolutePath();
        if(parent==u)return;
        u=parent;
    }
    if(!u.isEmpty())QDesktopServices::openUrl(QUrl::fromLocalFile(u));
}
void ExportRecipeStore::revealRecipesFile() const {
    QProcess::startDetached(QStringLiteral("explorer.exe"),{QStringLiteral("/select,")+QDir::toNativeSeparators(path_)});
}
void ExportRecipeStore::openAfterExport(const QStringList& files) const {
    if(files.isEmpty())return;
    const auto& how=current().openWith;
    if(how.isEmpty())return;
    // Only images: the DI's view LUTs ride along in `files`.
    QStringList images;
    for(const auto& f:files)if(!f.endsWith(QLatin1String(".cube"),Qt::CaseInsensitive))images.append(QDir::toNativeSeparators(f));
    if(images.isEmpty())return;
    if(how==QLatin1String("explorer"))
        QProcess::startDetached(QStringLiteral("explorer.exe"),{QStringLiteral("/select,")+images.first()});
    else if(how==QLatin1String("default"))
        for(const auto& f:images)QDesktopServices::openUrl(QUrl::fromLocalFile(f));
    else QProcess::startDetached(how,images);
}
void ExportRecipeStore::copyText(const QString& text) const {
    if(auto* clipboard=QGuiApplication::clipboard())clipboard->setText(text);
}
