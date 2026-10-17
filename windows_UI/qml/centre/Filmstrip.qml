import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The filmstrip (Filmstrip.swift): thumbnails at one height, chevrons at both
// ends stepping the open photo, and -- at the far left, where the Mac puts
// the folder name and count -- the count and the selection's actions.
//
// Each thumbnail is the whole photograph with the crop as the thing you see:
// everything outside it under a nearly opaque mask, turned and flipped as the
// canvas is (CropMaskedThumbnail.swift; the controller's `strip`). Until a
// photo has been rendered it is the file's own preview -- a RAW's embedded
// JPEG -- as on the Mac (ThumbnailCache.swift).
//
// Selection is a white frame round the picture and nothing else: the open
// photo has the strong frame, a photo in the selected set (what Sync, Paste
// and batch export act on) the same frame held back. A plain click opens a
// photo and selects it alone; Ctrl+click adds or removes a photo without
// moving the open one, which cannot leave the set (Session.click); the corner
// box does the same for a pointer that does not know that. Left / Right and
// the chevrons step. Dragging a thumbnail along the strip moves it -- the
// cell it is over gives way as it goes -- and the order is kept for the
// folder when it is let go (FrameOrder.swift).
Rectangle {
    id: strip
    required property EditorState editor
    Layout.fillWidth: true
    implicitHeight: Theme.filmstripHeight
    color: Theme.card
    // The item a drag is carrying, by its current index (-1: none).
    property int dragIndex: -1

    // Files or a folder dropped on the strip open as on the canvas
    // (Session.dropped(files:)); a thumbnail dragged along it is no file drop.
    DropArea {
        anchors.fill: parent
        enabled: strip.editor.canBrowse
        onDropped: function(drop) { if (drop.hasUrls) preview.openFiles(drop.urls) }
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
                text: L10n.tr("strip.count", [preview.libraryCount, preview.selectedCount])
                elide: Text.ElideRight
                color: Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
            }
            PillButton {
                text: L10n.tr("strip.selectAll")
                available: strip.editor.canBrowse && preview.libraryCount > 0
                onClicked: preview.selectAllPhotos(true)
            }
            PillButton {
                text: L10n.tr("strip.clearSelection")
                available: strip.editor.canBrowse && preview.selectedCount > 0
                onClicked: preview.selectAllPhotos(false)
            }
            PillButton {
                text: L10n.tr("strip.sync")
                available: strip.editor.canSync
                toolTip: L10n.tr("strip.syncHelp")
                reason: L10n.tr("clipboard.syncReason")
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
            onClicked: strip.editor.stepPhoto(-1)
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
            // The count, not the list: a new preview, a reorder or a selection
            // updates the cells in place (each reads its item below), so a
            // drag in flight keeps its cell.
            model: preview.libraryCount
            currentIndex: preview.activeIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            // The wheel scrolls the strip across. A horizontal ListView only
            // follows a sideways delta, which an ordinary mouse never sends:
            // here its vertical wheel scrolls too, a notch a cell (down /
            // toward you moves on to later photos), and a touchpad's pixel
            // deltas move the strip 1:1 in either direction.
            WheelHandler {
                target: null
                onWheel: function(event) {
                    const step = Math.round(Theme.thumbHeight * 1.5) + Theme.stripSpacing
                    const pixels = event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.pixelDelta.y
                    const notches = (event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y) / 120
                    const shift = pixels !== 0 ? pixels : notches * step
                    const lo = filmstrip.originX - filmstrip.leftMargin
                    const hi = Math.max(lo, filmstrip.originX + filmstrip.contentWidth + filmstrip.rightMargin - filmstrip.width)
                    filmstrip.contentX = Math.max(lo, Math.min(hi, filmstrip.contentX - shift))
                    event.accepted = true
                }
            }
            ScrollBar.horizontal: ScrollBar {
                id: hbar
                height: 6
                policy: filmstrip.contentWidth > filmstrip.width ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                contentItem: Rectangle { implicitHeight: 3; radius: 1.5; color: Theme.dim; opacity: hbar.active ? 0.8 : 0.35 }
            }
            delegate: Item {
                id: cell
                required property int index
                // One item, read again whenever the library changes.
                readonly property var modelData: { preview.libraryRevision; return preview.libraryItem(index) }
                readonly property bool open: modelData.active === true
                readonly property bool picked: modelData.selected === true
                readonly property bool failed: String(modelData.error || "").length > 0
                readonly property bool carried: strip.dragIndex === index
                width: Math.round(Theme.thumbHeight * 1.5)
                height: filmstrip.height
                opacity: carried ? 0.55 : 1
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
                        enabled: false
                        visible: !cell.failed
                        // A cell read before its item is there has no picture
                        // to assign (undefined is no QImage): it keeps none.
                        Binding on image {
                            when: cell.modelData.strip !== undefined
                            value: cell.modelData.strip
                        }
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
                    // The strip does not scroll from under a thumbnail being
                    // dragged; the wheel and the scroll bar still scroll it.
                    preventStealing: true
                    property real pressX: 0
                    property bool dragging: false
                    property bool dragged: false
                    onPressed: function(mouse) {
                        dragged = false
                        if (mouse.button !== Qt.LeftButton) return
                        pressX = mouse.x; dragging = false
                    }
                    onPositionChanged: function(mouse) {
                        if (!(mouse.buttons & Qt.LeftButton)) return
                        if (!dragging && Math.abs(mouse.x - pressX) > 8) { dragging = true; strip.dragIndex = cell.index }
                        if (!dragging) return
                        // Session.moveFrame: the carried photo takes the place
                        // of the cell it is over, there and then.
                        const p = mapToItem(filmstrip.contentItem, mouse.x, frame.y + frame.height / 2)
                        const target = filmstrip.indexAt(p.x, p.y)
                        if (target >= 0 && target !== strip.dragIndex && preview.moveItem(strip.dragIndex, target))
                            strip.dragIndex = target
                    }
                    onReleased: {
                        if (!dragging) return
                        dragging = false; dragged = true
                        strip.dragIndex = -1
                        preview.itemOrderChanged()
                    }
                    onCanceled: { if (dragging) { dragging = false; strip.dragIndex = -1; preview.itemOrderChanged() } }
                    onClicked: function(mouse) {
                        if (dragged) return
                        if (mouse.button === Qt.RightButton) { cellMenu.popup(); return }
                        const command = (mouse.modifiers & Qt.ControlModifier) !== 0
                        if (!command) strip.editor.cropMode = false
                        preview.clickPhoto(cell.index, command)
                    }
                }
                SquareCheck {
                    anchors.right: frame.right; anchors.top: frame.top
                    anchors.margins: -2
                    visible: (cell.picked || cellMouse.containsMouse) && strip.dragIndex < 0
                    checked: cell.picked
                    available: strip.editor.canBrowse && !(cell.open && cell.picked)
                    toolTip: L10n.tr("strip.selectHelp")
                    onToggledTo: function(on) { if (on !== cell.picked) preview.clickPhoto(cell.index, true) }
                }
                ToolTip.visible: cellMouse.containsMouse && strip.dragIndex < 0
                ToolTip.text: cell.failed ? cell.modelData.name + "\n" + cell.modelData.error : (cell.modelData.name || "")
                ToolTip.delay: 600
                RailMenu {
                    id: cellMenu
                    RailMenuItem {
                        text: L10n.tr("strip.menu.open")
                        enabled: !cell.open
                        onTriggered: { strip.editor.cropMode = false; preview.clickPhoto(cell.index, false) }
                    }
                    RailMenuItem {
                        text: L10n.tr("strip.menu.inSelection")
                        marked: cell.picked
                        enabled: !(cell.open && cell.picked)
                        onTriggered: preview.clickPhoto(cell.index, true)
                    }
                    RailMenuItem {
                        text: L10n.tr("strip.menu.showFolder")
                        onTriggered: {
                            var path = String(cell.modelData.url)
                            Qt.openUrlExternally(path.substring(0, path.lastIndexOf("/") + 1))
                        }
                    }
                    MenuSeparator {}
                    // Session.newPair (Ctrl+J): the selected photographs, in
                    // the strip's order, fill the holes.
                    RailMenuItem {
                        text: L10n.tr("strip.menu.newPair")
                        enabled: preview.canMakePair && strip.editor.canBrowse
                        onTriggered: preview.newPair()
                    }
                    RailMenuItem {
                        visible: cell.modelData.pair === true
                        height: visible ? implicitHeight : 0
                        text: L10n.tr("strip.menu.deletePair")
                        enabled: strip.editor.canBrowse
                        onTriggered: preview.deletePair(cell.index)
                    }
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
            available: strip.editor.canBrowse && preview.activeIndex >= 0 && preview.activeIndex < preview.libraryCount - 1
            toolTip: L10n.tr("strip.next")
            onClicked: strip.editor.stepPhoto(1)
        }
    }
    Text {
        anchors.centerIn: parent
        visible: preview.libraryCount === 0
        text: L10n.tr("strip.empty")
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
    }
}
