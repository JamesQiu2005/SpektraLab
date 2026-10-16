#include "ShellCapture.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFont>
#include <QFontInfo>
#include <QFontMetrics>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QMutex>
#include <QQuickWindow>
#include <QTimer>
#include <QVariant>
#include <memory>

namespace {
QMutex messagesLock;
QStringList& qmlMessages() {static QStringList messages;return messages;}
bool fromQml(const QMessageLogContext& context,const QString& message) {
    const QString category=QString::fromLatin1(context.category?context.category:"");
    const QString file=QString::fromLatin1(context.file?context.file:"");
    return category.startsWith(QLatin1String("qml"))||category.startsWith(QLatin1String("js"))||
           file.endsWith(QLatin1String(".qml"))||message.contains(QLatin1String(".qml:"));
}
// Every glyph the shell's QML draws from the system icon font (AppMenu,
// SettingsWindow's tabs, the warning badge, menu checks and chevrons).
constexpr char16_t kShellGlyphs[]={0xE700,0xE713,0xE7F4,0xE9E9,0xE950,0xE9D9,0xE756,0xE946,0xE7BA,0xE73E,0xE76C};
}

ShellCapture::ShellCapture(QQuickWindow& editor,QString output):editor_(editor),output_(std::move(output)) {
    pages_={QStringLiteral("general"),QStringLiteral("display"),QStringLiteral("rendering"),
            QStringLiteral("memory"),QStringLiteral("diagnostics"),QStringLiteral("agents")};
    QTimer::singleShot(60000,this,[this]{finish(false,QStringLiteral("timeout"));});
    later([this]{
        if(!capture(&editor_,QStringLiteral("editor")))return;
        if(!QMetaObject::invokeMethod(&editor_,"openAppMenu")){finish(false,QStringLiteral("openAppMenu"));return;}
        later([this]{
            if(!capture(&editor_,QStringLiteral("app-menu")))return;
            QMetaObject::invokeMethod(&editor_,"closeAppMenu");
            if(!QMetaObject::invokeMethod(&editor_,"openSettings",Q_ARG(QVariant,QVariant(pages_.first())))){
                finish(false,QStringLiteral("openSettings"));return;
            }
            // One page after another, each captured once it has laid out.
            auto next=std::make_shared<std::function<void(int)>>();
            *next=[this,next](int index){
                auto* settings=window("settingsWindow");
                if(!settings){finish(false,QStringLiteral("settings window not found"));return;}
                if(index==pages_.size()) {
                    settings->close();
                    if(!QMetaObject::invokeMethod(&editor_,"openAbout")){finish(false,QStringLiteral("openAbout"));return;}
                    later([this]{
                        auto* about=window("aboutWindow");
                        if(!about||!capture(about,QStringLiteral("about"))){if(!done_)finish(false,QStringLiteral("about window"));return;}
                        if(!QMetaObject::invokeMethod(about,"showLicence",Q_ARG(QVariant,QVariant(QStringLiteral("LICENSE"))))){
                            finish(false,QStringLiteral("showLicence"));return;
                        }
                        later([this,about]{
                            auto* licence=window("licenceWindow");
                            if(!licence||!capture(licence,QStringLiteral("licence"))){if(!done_)finish(false,QStringLiteral("licence window"));return;}
                            licence->close();about->close();
                            later([this]{finish(true,{});});
                        },500);
                    },600);
                    return;
                }
                settings->setProperty("page",pages_[index]);
                later([this,next,index]{
                    auto* settings=window("settingsWindow");
                    if(!settings||!capture(settings,QStringLiteral("settings-")+pages_[index]))return;
                    (*next)(index+1);
                });
            };
            later([next]{(*next)(0);},600);
        });
    },800);
}

void ShellCapture::noteMessage(QtMsgType type,const QMessageLogContext& context,const QString& message) {
    if(type==QtDebugMsg||type==QtInfoMsg||!fromQml(context,message))return;
    QMutexLocker lock(&messagesLock);
    qmlMessages().push_back(message);
}

void ShellCapture::later(std::function<void()> action,int delayMs) {
    QTimer::singleShot(delayMs,this,[this,action=std::move(action)]{if(!done_)action();});
}

QQuickWindow* ShellCapture::window(const char* objectName) const {
    for(auto* top:QGuiApplication::topLevelWindows())
        if(top->objectName()==QLatin1String(objectName)&&top->isVisible())return qobject_cast<QQuickWindow*>(top);
    return nullptr;
}

bool ShellCapture::capture(QQuickWindow* window,const QString& name) {
    const auto image=window?window->grabWindow():QImage();
    const QString file=name+QStringLiteral(".png");
    const bool saved=!image.isNull()&&image.save(QDir(output_).filePath(file));
    captures_.append(QJsonObject{{"name",name},{"file",file},{"saved",saved},{"width",image.width()},{"height",image.height()}});
    if(!saved)finish(false,QStringLiteral("capture ")+name);
    return saved;
}

void ShellCapture::finish(bool success,const QString& error) {
    if(done_)return;done_=true;
    // The icon font Theme.qml picks, and the Windows 10 one beside it.
    QJsonArray missing;
    QJsonArray families;
    for(const auto& family:{QStringLiteral("Segoe Fluent Icons"),QStringLiteral("Segoe MDL2 Assets")}) {
        const QFont font(family);
        if(QFontInfo(font).family()!=family)continue;
        families.append(family);
        const QFontMetrics metrics(font);
        for(const char16_t glyph:kShellGlyphs)
            if(!metrics.inFont(QChar(glyph)))missing.append(QStringLiteral("%1 U+%2").arg(family).arg(int(glyph),4,16,QLatin1Char('0')).toUpper());
    }
    QStringList warnings;{QMutexLocker lock(&messagesLock);warnings=qmlMessages();}
    const bool passed=success&&warnings.isEmpty()&&missing.isEmpty()&&!families.isEmpty();
    QJsonObject report{{"passed",passed},{"error",error},{"captures",captures_},
                       {"qml_warnings",QJsonArray::fromStringList(warnings)},
                       {"icon_fonts",families},{"missing_glyphs",missing},
                       {"platform",QGuiApplication::platformName()},{"qt_version",QString::fromLatin1(qVersion())}};
    QFile file(QDir(output_).filePath(QStringLiteral("report.json")));
    if(file.open(QIODevice::WriteOnly))file.write(QJsonDocument(report).toJson());
    QCoreApplication::exit(passed?0:1);
}
