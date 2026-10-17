import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import SpektraLab.Native 1.0

// Settings (SettingsWindow.swift, RFC-026's paged window), opened from the
// application menu and Ctrl+, (SpektrafilmApp.swift `.appSettings`, Cmd+,).
// A tab bar of icon tabs, and on each page plain groups of the editor's own
// rows.
//
// Every Mac page is here, in the Mac's order, with Display added after
// General: Windows manages the canvas to the monitor itself (ColorPipeline),
// and the Mac has nothing to set there because macOS does it. A Mac setting
// with no Windows backend is shown greyed with the reason under it -- the
// page says what is missing rather than pretending the Mac's page is the
// whole story, and it invents nothing the Windows app cannot do.
//
// Values live in AppSettings (the preferences file) and apply at once,
// except the interface scale, which Qt applies at the next start.
//
//   page                 "general", "display", "rendering", "memory",
//                        "diagnostics" or "agents"; remembered, as the Mac's
//                        @AppStorage settingsPage is
//   editorWindow         the editor, for the canvas's graphics adapter
//   openPage(page)       show the window on that page
//   resetLayoutRequested()   Reset All Layout; Main.qml resets the rails
ShellWindow {
    id: settings
    objectName: "settingsWindow"
    title: L10n.tr("settings.title")
    width: 580; height: 700
    minimumWidth: 500; minimumHeight: 480
    property var editorWindow: null
    readonly property var pages: ["general", "display", "rendering", "memory", "diagnostics", "agents"]
    property string page: {
        var saved = String(AppSettings.value("ui.settingsPage", "general"))
        return pages.indexOf(saved) >= 0 ? saved : "general"
    }
    property string graphics: ""
    signal resetLayoutRequested()

    // Only a page someone chose: the initial binding writes nothing, so a run
    // that never opens Settings leaves the preferences file untouched.
    onPageChanged: if (visible) AppSettings.setValue("ui.settingsPage", page)
    onVisibleChanged: if (visible) graphics = AppInfo.graphicsSummary(editorWindow)
    function openPage(name) {
        present()
        if (name && pages.indexOf(name) >= 0) page = name
    }

    // The tabs: an icon over its name, the chosen one on a plate with its
    // icon in the accent (SettingsTabBar, as Capture One draws it). Glyphs
    // from the system icon font, as Icons.qml's.
    readonly property var tabs: [
        { page: "general", glyph: "", title: L10n.tr("settings.tab.general") },
        { page: "display", glyph: "", title: L10n.tr("settings.tab.display") },
        { page: "rendering", glyph: "", title: L10n.tr("settings.tab.rendering") },
        { page: "memory", glyph: "", title: L10n.tr("settings.tab.memory") },
        { page: "diagnostics", glyph: "", title: L10n.tr("settings.tab.diagnostics") },
        { page: "agents", glyph: "", title: L10n.tr("settings.tab.agents") }
    ]

    // A row for a Mac setting Windows does not have: the Mac's label, a dash
    // where its value would be, greyed, the reason on hover and in the
    // group's note.
    component Absent: ParamRow {
        id: absent
        property string value: "—"
        available: false
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: absent.value
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
    }
    // A page: the groups in a column that scrolls when the window is short.
    component Page: ScrollView {
        id: pageView
        default property alias groups: column.data
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical: RailScrollBar { parent: pageView; x: pageView.width - width; height: pageView.availableHeight }
        ColumnLayout {
            id: column
            width: pageView.availableWidth
            spacing: 14
            Item { Layout.preferredHeight: 0 }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Row {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8; Layout.bottomMargin: 8
            spacing: 2
            Repeater {
                model: settings.tabs
                delegate: Rectangle {
                    id: tab
                    required property var modelData
                    readonly property bool chosen: settings.page === modelData.page
                    width: Math.max(64, tabTitle.implicitWidth + 12); height: 48
                    radius: 6
                    color: chosen ? Theme.ground : tabArea.containsMouse ? Theme.hover : "transparent"
                    Column {
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tab.modelData.glyph
                            color: tab.chosen ? Theme.accent : Theme.secondaryText
                            font.family: Theme.iconFamily; font.pixelSize: 17
                        }
                        Text {
                            id: tabTitle
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tab.modelData.title
                            color: tab.chosen ? Theme.text : Theme.dim
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                        }
                    }
                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: settings.page = tab.modelData.page
                    }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.title
                }
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.ruleRegion }
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.topMargin: 8
            currentIndex: Math.max(0, settings.pages.indexOf(settings.page))

            // --- General: language, interface, this session ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.language")
                    ParamRow {
                        label: L10n.tr("settings.language")
                        PillDropdown {
                            id: languagePicker
                            // "Follow the system", then every loaded table
                            // (Localizer.availableLanguages), English first.
                            readonly property var options: {
                                var list = [{ code: "system", label: L10n.tr("settings.languageFollowSystem") }]
                                var loaded = L10n.availableLanguages
                                for (var i = 0; i < loaded.length; ++i) {
                                    var entry = loaded[i]
                                    list.push({ code: entry.code, label: entry.name === entry.englishName ? entry.name : entry.name + " — " + entry.englishName })
                                }
                                return list
                            }
                            model: options
                            textRole: "label"
                            currentIndex: {
                                var list = options
                                for (var i = 0; i < list.length; ++i) if (list[i].code === L10n.language) return i
                                return 0
                            }
                            onActivated: function(index) {
                                var code = options[index].code
                                L10n.setLanguage(code)
                                AppSettings.setValue("general.language", code)
                            }
                        }
                    }
                    Note { text: L10n.tr("settings.languageCaption") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.interface")
                    ParamRow {
                        label: L10n.tr("settings.scale")
                        PillDropdown {
                            readonly property var scales: ["100", "115", "130"]
                            model: ["100 %", "115 %", "130 %"]
                            currentIndex: {
                                AppSettings.revision
                                return Math.max(0, scales.indexOf(String(AppSettings.value("general.interfaceScale", "115"))))
                            }
                            onActivated: function(index) { AppSettings.setValue("general.interfaceScale", scales[index]) }
                        }
                    }
                    Note {
                        text: AppInfo.interfaceScaleFromEnvironment
                            ? L10n.tr("settings.scaleEnvironment")
                            : L10n.tr("settings.scaleCaption", [AppInfo.activeInterfaceScale])
                    }
                    LinkText {
                        Layout.topMargin: 4
                        text: L10n.tr("settings.resetLayout")
                        onClicked: settings.resetLayoutRequested()
                    }
                    Note { text: L10n.tr("settings.resetLayoutCaption") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.session")
                    SettingsReadout { label: L10n.tr("settings.app"); value: L10n.tr("about.version", [AppInfo.version]); selectable: true }
                    SettingsReadout { label: L10n.tr("settings.engine"); value: AppInfo.engineBuild; selectable: true }
                    SettingsReadout { label: L10n.tr("settings.qt"); value: L10n.tr("about.qtBuild", [AppInfo.qtVersion, AppInfo.compiler]); selectable: true }
                    SettingsReadout {
                        label: L10n.tr("settings.canvas")
                        value: settings.graphics.length > 0 ? settings.graphics : L10n.tr("settings.notReported")
                        selectable: true
                    }
                    LinkText {
                        Layout.topMargin: 4
                        text: L10n.tr("settings.checkUpdates")
                        available: false
                        reason: L10n.tr("settings.checkUpdatesReason")
                    }
                    Note { text: L10n.tr("settings.checkUpdatesReason") }
                }
            }

            // --- Display: colour management (Windows only) ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.display.title")
                    ParamRow {
                        label: L10n.tr("settings.display.manageTo")
                        PillSwitch {
                            objectName: "displayModeSwitch"
                            anchors.verticalCenter: parent.verticalCenter
                            readonly property var modes: ["automatic", "srgb", "custom"]
                            sideWidth: 80
                            model: [L10n.tr("settings.display.automatic"), L10n.tr("settings.display.srgb"), L10n.tr("settings.display.custom")]
                            currentIndex: Math.max(0, modes.indexOf(DisplayColour.mode))
                            optionToolTips: [L10n.tr("settings.display.automaticNote"), L10n.tr("settings.display.srgbNote"), L10n.tr("settings.display.customNote")]
                            onActivated: function(index) {
                                if (modes[index] === "custom" && DisplayColour.customProfilePath.length === 0) profileDialog.open()
                                else DisplayColour.mode = modes[index]
                            }
                        }
                    }
                    Note {
                        text: DisplayColour.mode === "srgb" ? L10n.tr("settings.display.srgbNote")
                            : DisplayColour.mode === "custom" ? L10n.tr("settings.display.customNote")
                            : L10n.tr("settings.display.automaticNote")
                    }
                    ParamRow {
                        label: L10n.tr("settings.display.profile")
                        Text {
                            anchors.left: parent.left; anchors.right: chooseProfile.left; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: DisplayColour.customProfilePath.length > 0 ? AppInfo.nativePath(DisplayColour.customProfilePath) : L10n.tr("settings.display.noProfile")
                            elide: Text.ElideMiddle
                            color: DisplayColour.customProfilePath.length > 0 ? Theme.text : Theme.dim
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                            HoverHandler { id: pathHover }
                            ToolTip.visible: pathHover.hovered && DisplayColour.customProfilePath.length > 0
                            ToolTip.text: AppInfo.nativePath(DisplayColour.customProfilePath)
                            ToolTip.delay: 500
                        }
                        PillButton {
                            id: chooseProfile
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: L10n.tr("settings.display.choose")
                            toolTip: L10n.tr("settings.display.chooseHelp")
                            onClicked: profileDialog.open()
                        }
                    }
                    SettingsReadout {
                        Layout.topMargin: 4
                        label: L10n.tr("settings.display.managingTo")
                        value: DisplayColour.displayName.length > 0 ? DisplayColour.displayName : L10n.tr("settings.notReported")
                        selectable: true
                    }
                    SettingsReadout {
                        label: L10n.tr("settings.display.targetSpace")
                        value: DisplayColour.targetDescription
                        visible: DisplayColour.targetDescription.length > 0
                    }
                    SettingsReadout {
                        label: L10n.tr("settings.display.status")
                        value: DisplayColour.status.length > 0 ? DisplayColour.status : L10n.tr("settings.display.statusOk")
                        warning: DisplayColour.status.length > 0
                        selectable: true
                    }
                    PillButton {
                        Layout.topMargin: 4
                        text: L10n.tr("settings.display.reload")
                        toolTip: L10n.tr("settings.display.reloadHelp")
                        onClicked: DisplayColour.reload()
                    }
                    Note { text: L10n.tr("settings.display.reloadNote") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.display.canvas")
                    CheckRow {
                        label: L10n.tr("settings.display.dither")
                        checked: DisplayColour.dither
                        onToggledTo: function(on) { DisplayColour.dither = on }
                    }
                    Note { text: L10n.tr("settings.display.ditherNote") }
                    Note { text: L10n.tr("settings.display.scopeNote") }
                }
            }

            // --- Rendering: the Mac's render settings ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.rendering.preview")
                    // The live tier's long edge (main.cpp reads it at start).
                    ParamRow {
                        label: L10n.tr("settings.rendering.previewResolution")
                        PillDropdown {
                            objectName: "previewResolution"
                            readonly property var edges: [1080, 1920, 2560, 3840]
                            model: ["1080", "1920", L10n.tr("settings.rendering.previewDefault", ["2560"]), "3840"]
                            currentIndex: {
                                AppSettings.revision
                                var i = edges.indexOf(Number(AppSettings.value("rendering.previewLongEdge", 2560)))
                                return i < 0 ? 2 : i
                            }
                            onActivated: function(index) { AppSettings.setValue("rendering.previewLongEdge", edges[index]) }
                        }
                    }
                    Note { text: L10n.tr("settings.rendering.previewNote") }
                    CheckRow { label: L10n.tr("settings.rendering.fastStock"); available: false; reason: L10n.tr("settings.rendering.fastStockReason") }
                    Note { text: L10n.tr("settings.rendering.fastStockReason") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.rendering.di")
                    CheckRow { label: L10n.tr("settings.rendering.blueCompensation"); available: false; reason: L10n.tr("settings.rendering.blueCompensationReason") }
                    Note { text: L10n.tr("settings.rendering.blueCompensationReason") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.rendering.filmEffects")
                    CheckRow { label: L10n.tr("settings.rendering.cropRemaps"); available: false; reason: L10n.tr("settings.rendering.cropRemapsReason") }
                    Note { text: L10n.tr("settings.rendering.cropRemapsReason") }
                    CheckRow { label: L10n.tr("settings.rendering.decouple"); available: false; checked: true; reason: L10n.tr("settings.rendering.decoupleReason") }
                    Note { text: L10n.tr("settings.rendering.decoupleReason") }
                }
            }

            // --- Memory: the Mac's readouts and caps ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.memory.title")
                    Absent { label: L10n.tr("settings.memory.footprint"); reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.peak"); reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.free"); reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.reserve"); reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.cap"); reason: L10n.tr("settings.memory.reason") }
                    CheckRow { label: L10n.tr("settings.memory.unlimited"); available: false; reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.held"); reason: L10n.tr("settings.memory.reason") }
                    Absent { label: L10n.tr("settings.memory.evictable"); reason: L10n.tr("settings.memory.reason") }
                    CheckRow { label: L10n.tr("settings.memory.allowOver"); available: false; reason: L10n.tr("settings.memory.reason") }
                    Note { text: L10n.tr("settings.memory.reason") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.diskCache.title")
                    Absent { label: L10n.tr("settings.diskCache.inUse"); reason: L10n.tr("settings.diskCache.reason") }
                    Absent { label: L10n.tr("settings.diskCache.limit"); reason: L10n.tr("settings.diskCache.reason") }
                    Absent { label: L10n.tr("settings.diskCache.location"); reason: L10n.tr("settings.diskCache.reason") }
                    LinkText { text: L10n.tr("settings.diskCache.empty"); available: false; reason: L10n.tr("settings.diskCache.reason") }
                    Note { text: L10n.tr("settings.diskCache.reason") }
                }
            }

            // --- Diagnostics: the Mac's log controls, and the files this
            // build writes ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.diagnostics.files")
                    SettingsReadout { label: L10n.tr("settings.diagnostics.settingsFile"); value: AppInfo.nativePath(AppInfo.settingsFile); selectable: true }
                    LinkText { text: L10n.tr("settings.showInExplorer"); onClicked: AppInfo.openFolder(AppInfo.settingsFile) }
                    SettingsReadout { label: L10n.tr("settings.diagnostics.edits"); value: AppInfo.nativePath(AppInfo.editDirectory); selectable: true }
                    LinkText { text: L10n.tr("settings.showInExplorer"); onClicked: AppInfo.openFolder(AppInfo.editDirectory) }
                    SettingsReadout { label: L10n.tr("settings.diagnostics.licences"); value: AppInfo.nativePath(AppInfo.licencesDirectory); selectable: true }
                    LinkText { text: L10n.tr("settings.showInExplorer"); onClicked: AppInfo.openFolder(AppInfo.licencesDirectory) }
                    SettingsReadout {
                        visible: AppSettings.lastError.length > 0
                        label: L10n.tr("settings.diagnostics.problem")
                        value: AppSettings.lastError
                        warning: true
                    }
                    Note { text: L10n.tr("settings.diagnostics.filesNote") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.diagnostics.title")
                    Absent { label: L10n.tr("settings.diagnostics.logLevel"); reason: L10n.tr("settings.diagnostics.reason") }
                    CheckRow { label: L10n.tr("settings.diagnostics.perNode"); available: false; reason: L10n.tr("settings.diagnostics.reason") }
                    CheckRow { label: L10n.tr("settings.diagnostics.jobLog"); available: false; reason: L10n.tr("settings.diagnostics.reason") }
                    Note { text: L10n.tr("settings.diagnostics.reason") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.logs.title")
                    Absent { label: L10n.tr("settings.logs.keepFor"); reason: L10n.tr("settings.diagnostics.reason") }
                    Absent { label: L10n.tr("settings.logs.destination"); reason: L10n.tr("settings.diagnostics.reason") }
                    LinkText { text: L10n.tr("settings.logs.clear"); available: false; reason: L10n.tr("settings.diagnostics.reason") }
                }
                SettingsGroup {
                    title: L10n.tr("settings.bundle.title")
                    CheckRow { label: L10n.tr("settings.bundle.fileNames"); available: false; reason: L10n.tr("settings.bundle.reason") }
                    LinkText { text: L10n.tr("settings.bundle.save"); available: false; reason: L10n.tr("settings.bundle.reason") }
                    Note { text: L10n.tr("settings.bundle.reason") }
                }
            }

            // --- Agents: the command line and MCP server ---
            Page {
                SettingsGroup {
                    title: L10n.tr("settings.agents.access")
                    CheckRow { label: L10n.tr("settings.agents.toggle"); available: false; reason: L10n.tr("settings.agents.reason") }
                    Absent { label: L10n.tr("settings.agents.commandLine"); reason: L10n.tr("settings.agents.reason") }
                    Absent { label: L10n.tr("settings.agents.mcp"); reason: L10n.tr("settings.agents.reason") }
                    Note { text: L10n.tr("settings.agents.reason") }
                }
            }
        }
    }

    // .icc / .icm for the custom mode. Choosing a file selects the mode.
    FileDialog {
        id: profileDialog
        title: L10n.tr("settings.display.dialogTitle")
        fileMode: FileDialog.OpenFile
        nameFilters: [L10n.tr("settings.display.filterProfiles") + " (*.icc *.icm)", L10n.tr("dialog.filter.allFiles") + " (*)"]
        onAccepted: {
            DisplayColour.customProfilePath = AppInfo.localPath(selectedFile)
            DisplayColour.mode = "custom"
        }
    }
}
