import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// About SpektraLab (AboutWindow.swift): who made this, under what licence,
// and where the source is. Not a nicety -- CC BY-SA 4.0 on the profiles names
// an About screen as a place the attribution must survive, and the GPL
// requires the licence text and an offer of the corresponding source. So the
// credit is on the front and every text is one click away, read from the
// licenses folder the build deploys beside the executable (engine/
// CMakeLists.txt, build-msvc.ps1): on Windows that adds LibRaw (LGPL 2.1 or
// CDDL), Qt (LGPL 3, with the SDK's SBOMs), TeX Gyre Heros (GUST), stb and
// volk to the Mac's list, and drops metal-cpp, which only the Mac links.
//
//   editorWindow           the editor, for the canvas's graphics adapter
//   showLicence(file)      open one text in the viewer (the --capture-shell
//                          run calls it by name)
ShellWindow {
    id: about
    objectName: "aboutWindow"
    title: L10n.tr("about.title")
    width: 500; height: 720
    minimumWidth: 440; minimumHeight: 420
    property var editorWindow: null
    property string graphics: ""
    property var licences: []
    onVisibleChanged: if (visible) {
        graphics = AppInfo.graphicsSummary(editorWindow)
        licences = AppInfo.licences()
    }

    // Each deployed text's title; a file this list does not know is shown by
    // its name (AppInfo.licences lists everything in the folder).
    function licenceTitle(file) {
        switch (file) {
        case "LICENSE": return L10n.tr("about.licence.gpl")
        case "SPEKTRAFILM_LICENSE.txt": return L10n.tr("about.licence.profiles")
        case "PRODUCT_PROFILES_NOTICE.md": return L10n.tr("about.licence.productProfiles")
        case "LibRaw-LICENSE.LGPL": return L10n.tr("about.licence.librawLgpl")
        case "LibRaw-LICENSE.CDDL": return L10n.tr("about.licence.librawCddl")
        case "LibRaw-COPYRIGHT": return L10n.tr("about.licence.librawCopyright")
        case "Qt-SBOM": return L10n.tr("about.licence.qt")
        case "TeX-Gyre-Heros-GUST-FONT-LICENSE.txt": return L10n.tr("about.licence.texGyre")
        case "stb-LICENSE": return L10n.tr("about.licence.stb")
        case "volk-LICENSE.md": return L10n.tr("about.licence.volk")
        case "THIRD_PARTY.md": return L10n.tr("about.licence.thirdParty")
        }
        return file
    }
    function showLicence(file) { licenceViewer.showFile(file, licenceTitle(file)) }

    // A credit: what, who and under what licence, and where it lives.
    component Credit: ColumnLayout {
        id: credit
        property string heading
        property string line
        property string url
        Layout.fillWidth: true
        spacing: 2
        Text {
            text: credit.heading
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightTitle
        }
        Text {
            Layout.fillWidth: true
            text: credit.line
            wrapMode: Text.WordWrap
            color: Theme.secondaryText
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
        LinkText {
            visible: credit.url.length > 0
            text: credit.url.replace("https://", "")
            toolTip: credit.url
            onClicked: Qt.openUrlExternally(credit.url)
        }
    }
    component Rule: Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }

    ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical: RailScrollBar { parent: scroll; x: scroll.width - width; height: scroll.availableHeight }
        ColumnLayout {
            width: scroll.availableWidth
            spacing: 0

            // The header: the name, the version, what it is.
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 20
                spacing: 14
                Rectangle {
                    Layout.preferredWidth: 64; Layout.preferredHeight: 64
                    Layout.alignment: Qt.AlignTop
                    radius: 14
                    color: Theme.ground
                    Text {
                        anchors.centerIn: parent
                        text: Icons.photo
                        color: Theme.accent
                        font.family: Theme.iconFamily; font.pixelSize: 30
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 3
                    Text {
                        text: L10n.tr("app.name")
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: 22; font.weight: Theme.weightTitle
                    }
                    Text {
                        text: L10n.tr("about.version", [AppInfo.version])
                        color: Theme.secondaryText
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                    }
                    Text {
                        Layout.fillWidth: true
                        text: L10n.tr("about.tagline")
                        wrapMode: Text.WordWrap
                        color: Theme.dim
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                    }
                }
            }
            Rule {}
            // The build: what a bug report quotes.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 20
                spacing: 4
                SettingsReadout { label: L10n.tr("settings.engine"); value: AppInfo.engineBuild; selectable: true }
                SettingsReadout { label: L10n.tr("settings.qt"); value: L10n.tr("about.qtBuild", [AppInfo.qtVersion, AppInfo.compiler]); selectable: true }
                SettingsReadout {
                    label: L10n.tr("settings.canvas")
                    value: about.graphics.length > 0 ? about.graphics : L10n.tr("settings.notReported")
                    selectable: true
                }
            }
            Rule {}
            // The credits, in the form CC BY-SA suggests: author, canonical
            // source, licence.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 20
                spacing: 12
                Note { text: L10n.tr("about.usesSpektrafilm"); color: Theme.secondaryText }
                Credit {
                    heading: L10n.tr("about.credit.science")
                    line: L10n.tr("about.credit.scienceLine")
                    url: AppInfo.upstreamUrl
                }
                Credit {
                    heading: L10n.tr("about.credit.monochrome")
                    line: L10n.tr("about.credit.monochromeLine")
                }
                Credit {
                    heading: L10n.tr("about.credit.app")
                    line: L10n.tr("about.credit.appLine")
                    url: AppInfo.sourceUrl
                }
                Note { text: L10n.tr("about.lutNote") }
            }
            Rule {}
            // Every text the build carries, and any it should carry but does
            // not -- said rather than hidden.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 20
                spacing: 2
                Text {
                    Layout.bottomMargin: 4
                    text: L10n.tr("about.licences")
                    color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightTitle
                }
                Repeater {
                    model: about.licences
                    delegate: Rectangle {
                        id: licenceRow
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: 24
                        radius: 4
                        color: rowArea.containsMouse && modelData.present ? Theme.hover : "transparent"
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: 6
                            anchors.right: chevron.left; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: licenceRow.modelData.present ? about.licenceTitle(licenceRow.modelData.file)
                                : L10n.tr("about.licenceAbsent", [about.licenceTitle(licenceRow.modelData.file)])
                            elide: Text.ElideRight
                            color: licenceRow.modelData.present ? Theme.text : Theme.warning
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                        }
                        Text {
                            id: chevron
                            anchors.right: parent.right; anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            visible: licenceRow.modelData.present
                            text: Icons.chevronRight
                            color: Theme.dim
                            font.family: Theme.iconFamily; font.pixelSize: 9
                        }
                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: licenceRow.modelData.present
                            cursorShape: Qt.PointingHandCursor
                            onClicked: about.showLicence(licenceRow.modelData.file)
                        }
                    }
                }
                LinkText {
                    Layout.topMargin: 8
                    text: L10n.tr("about.showLicenceFiles")
                    onClicked: AppInfo.openFolder(AppInfo.licencesDirectory)
                }
            }
        }
    }

    LicenceWindow { id: licenceViewer }
}
