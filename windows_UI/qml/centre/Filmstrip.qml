import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The filmstrip (Filmstrip.swift): thumbnails at one height, chevrons at both
// ends stepping the open photo, and -- at the far left, where the Mac puts
// the folder name and count -- the count and the selection's actions.
//
// Selection is a white frame round the picture and nothing else: the open
// photo has the strong frame, a photo in the selected set (what Sync and
// batch export act on) the same frame held back. Ctrl+click adds or removes a
// photo from the set, as Cmd+click does on the Mac; the corner box does the
// same for a pointer that does not know that, and the context menu has the
// rest. A plain click opens the photo (and leaves the crop editor).
Rectangle {
    id: strip
    required property EditorState editor
    Layout.fillWidth: true
    implicitHeight: Theme.filmstripHeight
    color: Theme.card

    function step(delta) {
        var next = preview.activeIndex + delta
        if (next < 0 || next >= preview.libraryItems.length) return
        strip.editor.cropMode = false
        preview.selectImage(next)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        // Count and selection actions.
        ColumnLayout {
            // Explicitly not filling: a layout fills by default when any child
            // does (the count's Text), and this column would take the strip.
            Layout.fillWidth: false
            Layout.preferredWidth: 132
            Layout.fillHeight: true
            Layout.leftMargin: 12
            Layout.topMargin: 12; Layout.bottomMargin: 12
            spacing: 6
            Text {
                Layout.fillWidth: true
                text: L10n.tr("strip.count", [preview.libraryItems.length, preview.selectedCount])
                elide: Text.ElideRight
                color: Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            }
            PillButton {
                text: L10n.tr("strip.selectAll")
                available: strip.editor.canBrowse && preview.libraryItems.length > 0
                onClicked: preview.selectAllPhotos(true)
            }
            PillButton {
                text: L10n.tr("strip.clearSelection")
                available: strip.editor.canBrowse && preview.selectedCount > 0
                onClicked: preview.selectAllPhotos(false)
            }
            PillButton {
                text: L10n.tr("strip.sync")
                available: strip.editor.canBrowse && preview.hasFrame && preview.selectedCount > 0
                toolTip: L10n.tr("strip.syncHelp")
                reason: L10n.tr("strip.syncHelp")
                onClicked: preview.syncSelectedSettings(false)
            }
            Item { Layout.fillHeight: true }
        }
        IconButton {
            Layout.preferredWidth: 20; Layout.fillHeight: true
            size: 20; glyphSize: 11
            glyph: Icons.chevronLeft
            available: strip.editor.canBrowse && preview.activeIndex > 0
            toolTip: L10n.tr("strip.previous")
            onClicked: strip.step(-1)
        }
        ListView {
            id: filmstrip
            objectName: "photoStrip"
            Layout.fillWidth: true; Layout.fillHeight: true
            orientation: ListView.Horizontal
            spacing: Theme.stripSpacing
            leftMargin: 10; rightMargin: 10
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: preview.libraryItems
            currentIndex: preview.activeIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            ScrollBar.horizontal: ScrollBar {
                id: hbar
                height: 6
                policy: filmstrip.contentWidth > filmstrip.width ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                contentItem: Rectangle { implicitHeight: 3; radius: 1.5; color: Theme.dim; opacity: hbar.active ? 0.8 : 0.35 }
            }
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool open: modelData.active === true
                readonly property bool picked: modelData.selected === true
                readonly property bool failed: String(modelData.error || "").length > 0
                width: Math.round(Theme.thumbHeight * 1.5)
                height: filmstrip.height
                // The picture, letterboxed in a 3:2 cell.
                Item {
                    id: frame
                    width: parent.width; height: Theme.thumbHeight
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                        anchors.fill: parent
                        visible: thumb.imageRect.width <= 0 || cell.failed
                        radius: 2
                        color: Theme.well
                        Column {
                            anchors.centerIn: parent
                            spacing: 4
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: cell.failed ? Icons.warning : Icons.photo
                                font.family: Theme.iconFamily; font.pixelSize: 18
                                color: cell.failed ? Theme.warning : Theme.dim
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: cell.failed ? L10n.tr("strip.unreadable") : L10n.tr("strip.clickToPreview")
                                color: cell.failed ? Theme.warning : Theme.dim
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                            }
                        }
                    }
                    FrameCanvas {
                        id: thumb
                        anchors.fill: parent
                        image: cell.modelData.thumbnail
                        enabled: false
                        visible: !cell.failed
                    }
                    // The white frame, round the picture rather than the cell.
                    Rectangle {
                        readonly property rect r: thumb.imageRect.width > 0 && !cell.failed ? thumb.imageRect : Qt.rect(0, 0, frame.width, frame.height)
                        x: r.x - 2; y: r.y - 2; width: r.width + 4; height: r.height + 4
                        radius: 2
                        color: "transparent"
                        visible: cell.open || cell.picked
                        border.width: cell.open ? 1.5 : 1
                        border.color: Theme.selectionFrame
                        opacity: cell.open ? 1 : 0.5
                    }
                }
                MouseArea {
                    id: cellMouse
                    anchors.fill: parent
                    enabled: strip.editor.canBrowse
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.RightButton) { cellMenu.popup(); return }
                        if (mouse.modifiers & Qt.ControlModifier) { preview.setItemSelected(cell.index, !cell.picked); return }
                        strip.editor.cropMode = false
                        preview.selectImage(cell.index)
                    }
                }
                SquareCheck {
                    anchors.right: frame.right; anchors.top: frame.top
                    anchors.margins: -2
                    visible: cell.picked || cellMouse.containsMouse
                    checked: cell.picked
                    available: strip.editor.canBrowse
                    toolTip: L10n.tr("strip.selectHelp")
                    onToggledTo: function(on) { preview.setItemSelected(cell.index, on) }
                }
                ToolTip.visible: cellMouse.containsMouse
                ToolTip.text: cell.failed ? cell.modelData.name + "\n" + cell.modelData.error : cell.modelData.name
                ToolTip.delay: 600
                RailMenu {
                    id: cellMenu
                    RailMenuItem {
                        text: L10n.tr("strip.menu.open")
                        enabled: !cell.open
                        onTriggered: { strip.editor.cropMode = false; preview.selectImage(cell.index) }
                    }
                    RailMenuItem {
                        text: L10n.tr("strip.menu.inSelection")
                        marked: cell.picked
                        onTriggered: preview.setItemSelected(cell.index, !cell.picked)
                    }
                    RailMenuItem {
                        text: L10n.tr("strip.menu.showFolder")
                        onTriggered: {
                            var path = String(cell.modelData.url)
                            Qt.openUrlExternally(path.substring(0, path.lastIndexOf("/") + 1))
                        }
                    }
                    MenuSeparator {}
                    RailMenuItem { text: L10n.tr("strip.menu.newPair"); enabled: false }
                    RailMenuItem {
                        text: L10n.tr("info.resetPhoto")
                        enabled: cell.open && preview.settingsEditable
                        onTriggered: preview.resetSettings()
                    }
                }
            }
        }
        IconButton {
            Layout.preferredWidth: 20; Layout.fillHeight: true
            size: 20; glyphSize: 11
            glyph: Icons.chevronRight
            available: strip.editor.canBrowse && preview.activeIndex >= 0 && preview.activeIndex < preview.libraryItems.length - 1
            toolTip: L10n.tr("strip.next")
            onClicked: strip.step(1)
        }
    }
    Text {
        anchors.centerIn: parent
        visible: preview.libraryItems.length === 0
        text: L10n.tr("strip.empty")
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
    }
}
