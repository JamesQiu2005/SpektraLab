#pragma once
// `--capture-shell <new directory>`: open every page of the Settings window,
// the About window, a licence text and the application menu, save a capture
// of each, and exit 0 only if every capture was written, every icon glyph the
// shell draws is in the system icon font, and no QML warning was logged while
// the windows loaded. Hidden from --help; the spk_qt_shell_smoke CTest runs it
// offscreen with the software scene graph, and the captures are the evidence
// a review looks at (the Mac's `--snapshot --settings <page>`,
// SpektrafilmApp.swift `SnapshotRequest.settings`).
//
// It drives the QML by name, as the --self-test does: the editor window's
// openSettings(page), openAbout() and openAppMenu(), the windows found by
// objectName ("settingsWindow", "aboutWindow", "licenceWindow").
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <functional>

class QQuickWindow;

class ShellCapture final:public QObject {
public:
    ShellCapture(QQuickWindow& editor,QString output);

    // Called by the application's message handler for every message, before
    // and during a capture run; it keeps the QML ones.
    static void noteMessage(QtMsgType type,const QMessageLogContext& context,const QString& message);

private:
    void later(std::function<void()> action,int delayMs=350);
    QQuickWindow* window(const char* objectName) const;
    bool capture(QQuickWindow* window,const QString& name);
    void finish(bool success,const QString& error);
    QQuickWindow& editor_;
    QString output_;
    QJsonArray captures_;
    QStringList pages_;
    bool done_=false;
};
