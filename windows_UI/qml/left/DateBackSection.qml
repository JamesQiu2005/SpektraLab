import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Date Back (DateBackSection.swift, RFC-031): the camera's LEDs exposing a
// date onto the negative. Its own section, under Film Edge, because it works
// without one: in the bare frame a date back needs only the camera. With a
// film edge it can also print between the frames, and print the shooting
// data beside the frame as well as the date.
//
// The camera is the film edge's format while it is on, else the one Film
// Format describes (135, half frame or 645); a face that camera cannot draw
// is greyed with the reason rather than offered and silently dropped. On 120
// the date prints in the film margin, so it has no corner and needs the
// film edge. The controller's `dateBack` says all of this; the rows only
// show it.
//
// The printed text is the shooting date from the RAW's EXIF, in the order
// the menu chooses, or -- Source: Typed -- the user's own line (the Mac's
// README: "the shooting date (or a date you type)"). The Mac draws no inset
// control yet, and neither does this.
MacSection {
    id: section
    sectionId: "dateBack"
    title: L10n.tr("dateBack.title")
    defaultExpanded: on

    readonly property var p: preview.parameters
    readonly property var date: preview.dateBack
    readonly property bool on: p.date_imprint_active === true
    readonly property bool hasBack: date.hasBack === true
    readonly property bool usable: on && hasBack && preview.settingsEditable
    readonly property string face: p.date_imprint_style === undefined ? "lcd" : p.date_imprint_style
    readonly property bool dataFace: face === "data"
    readonly property bool typed: p.date_back_text_source === "typed"
    readonly property string cameraTitle: date.camera === "135_half" ? L10n.tr("filmEdge.format.half") : (date.cameraTitle || "")
    readonly property string dataNeedsEdge: L10n.tr(date.printsInMargin ? "dateBack.dataNeedsEdge120" : "dateBack.dataNeedsEdge")
    readonly property string noBackReason: {
        if (!date.camera) return L10n.tr("dateBack.noCamera")
        if (date.onCamera && date.onCamera.lcd) return dataNeedsEdge
        return date.panoramic ? L10n.tr("dateBack.panoramic") : L10n.tr("dateBack.noFace", [cameraTitle])
    }
    readonly property string offReason: hasBack ? L10n.tr("dateBack.switchOn") : noBackReason
    function faceTitle(f) {
        return f === "data" ? L10n.tr("dateBack.face.data") : f === "dots" ? L10n.tr("dateBack.face.dots") : L10n.tr("dateBack.face.lcd")
    }
    function prints(f) { return date.prints !== undefined && date.prints[f] === true }
    function faceReason(f) { return date.onCamera && date.onCamera[f] ? dataNeedsEdge : L10n.tr("dateBack.noFace", [cameraTitle]) }
    function set(key, value) { preview.setParameter(key, value) }

    headerCheckVisible: true
    headerChecked: on
    headerCheckAvailable: preview.settingsEditable
    headerCheckToolTip: L10n.tr("dateBack.toggleHelp")
    onHeaderToggled: function(checked) {
        if (preview.setDateBackActive(checked) && checked) section.setExpanded(true)
    }
    caption: on ? "" : L10n.tr("filmEdge.off")
    foldedCaption: on ? (date.printed && date.printed.length > 0 ? faceTitle(face) + " · " + date.printed : faceTitle(face)) : ""

    ParamRow {
        label: L10n.tr("dateBack.face")
        available: section.usable
        reason: section.offReason
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            sideWidth: 48
            readonly property var keys: ["lcd", "dots", "data"]
            model: [section.faceTitle("lcd"), section.faceTitle("dots"), section.faceTitle("data")]
            currentIndex: Math.max(0, keys.indexOf(section.face))
            optionEnabled: [section.prints("lcd"), section.prints("dots"), section.prints("data")]
            optionToolTips: [section.prints("lcd") ? "" : section.faceReason("lcd"),
                             section.prints("dots") ? "" : section.faceReason("dots"),
                             section.prints("data") ? "" : section.faceReason("data")]
            onActivated: function(index) { section.set("date_imprint_style", keys[index]) }
        }
    }
    Note {
        visible: section.hasBack && !section.prints(section.face)
        Layout.leftMargin: Theme.labelWidth
        text: section.faceReason(section.face)
    }
    // The date as it will print, and the order it is written in; for the
    // data face, the shooting data.
    ParamRow {
        label: section.dataFace ? L10n.tr("dateBack.imprint") : L10n.tr("dateBack.date")
        available: section.usable
        reason: section.offReason
        Text {
            visible: section.dataFace || section.typed
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - exifNote.width - 6
            elide: Text.ElideRight
            text: section.date.printed && section.date.printed.length > 0 ? section.date.printed : "—"
            color: Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
        PillDropdown {
            visible: !section.dataFace && !section.typed
            fill: false
            x: 0
            readonly property var keys: ["japan", "us"]
            model: [section.date.examples.japan + "  ·  " + L10n.tr("dateBack.order.japan"),
                    section.date.examples.us + "  ·  " + L10n.tr("dateBack.order.us")]
            currentIndex: { model; return Math.max(0, keys.indexOf(section.p.date_back_order)) }
            displayText: section.date.printed && section.date.printed.length > 0 ? section.date.printed : "—"
            toolTip: L10n.tr("dateBack.orderHelp")
            onActivated: function(index) { section.set("date_back_order", keys[index]) }
        }
        Text {
            id: exifNote
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            visible: !section.typed
            text: section.date.hasExifDate ? L10n.tr("dateBack.fromExif") : L10n.tr("dateBack.noExif")
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
    }
    // Where the text comes from: the shooting date, or a line you type.
    ParamRow {
        label: L10n.tr("dateBack.source")
        available: section.usable
        reason: section.offReason
        toolTip: L10n.tr("dateBack.source.help")
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            sideWidth: 56
            model: [L10n.tr("dateBack.source.exif"), L10n.tr("dateBack.source.typed")]
            currentIndex: section.typed ? 1 : 0
            onActivated: function(index) { section.set("date_back_text_source", index === 1 ? "typed" : "exif") }
        }
    }
    ParamRow {
        visible: section.typed
        label: L10n.tr("dateBack.typed")
        available: section.usable
        reason: section.offReason
        toolTip: L10n.tr("dateBack.typedHelp")
        Rectangle {
            width: parent.width; height: Theme.controlHeight
            anchors.verticalCenter: parent.verticalCenter
            radius: Theme.fieldRadius
            color: Theme.plot
            border.width: typedInput.activeFocus ? 1 : 0
            border.color: Theme.accent
            TextInput {
                id: typedInput
                objectName: "dateBackTypedText"
                anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: Theme.text
                selectionColor: Theme.accent
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                maximumLength: 32
                validator: RegularExpressionValidator { regularExpression: /[\x20-\x7e]{0,32}/ }
                text: section.p.date_back_custom_text === undefined ? "" : section.p.date_back_custom_text
                onEditingFinished: if (text !== section.p.date_back_custom_text) section.set("date_back_custom_text", text)
            }
        }
    }
    CheckRow {
        visible: !section.dataFace
        label: L10n.tr("dateBack.withData")
        sublabel: section.p.date_back_with_data === true && section.date.dataText.length > 0 ? section.date.dataText
                                                                                          : L10n.tr("dateBack.withDataWhere")
        checked: section.p.date_back_with_data === true
        available: section.usable && section.date.dataPrintable === true
        reason: section.on && section.hasBack ? section.dataNeedsEdge : section.offReason
        toolTip: L10n.tr("dateBack.withDataHelp")
        onToggledTo: function(checked) { section.set("date_back_with_data", checked) }
    }
    Note {
        visible: !section.dataFace && section.date.printsInMargin === true
        Layout.leftMargin: Theme.labelWidth
        text: L10n.tr("dateBack.marginNote")
        opacity: section.usable ? 1 : Theme.disabledOpacity
    }
    ParamRow {
        visible: !section.dataFace && section.date.printsInMargin !== true
        label: L10n.tr("dateBack.where")
        available: section.usable
        reason: section.offReason
        PillSwitch {
            anchors.verticalCenter: parent.verticalCenter
            sideWidth: 56
            model: [L10n.tr("dateBack.where.frame"), L10n.tr("dateBack.where.between")]
            currentIndex: section.p.date_imprint_placement === "rebate" ? 1 : 0
            optionEnabled: [true, section.p.overscan_active === true]
            optionToolTips: ["", section.p.overscan_active === true ? "" : L10n.tr("dateBack.betweenNeedsEdge")]
            onActivated: function(index) { section.set("date_imprint_placement", index === 1 ? "rebate" : "frame") }
        }
    }
    Note {
        visible: !section.dataFace && section.date.printsInMargin !== true && section.p.overscan_active !== true
        Layout.leftMargin: Theme.labelWidth
        text: L10n.tr("dateBack.betweenNeedsEdge")
        opacity: section.usable ? 1 : Theme.disabledOpacity
    }
    // The camera's corner, held level: the pad is the camera's back, so a
    // turned frame keeps the corner it was shot with.
    ParamRow {
        visible: !section.dataFace && section.date.printsInMargin !== true
        label: L10n.tr("dateBack.corner")
        available: section.usable
        reason: section.offReason
        implicitHeight: 36
        Rectangle {
            id: pad
            y: (36 - height) / 2 - 2
            width: 44; height: 30
            radius: 4
            color: Theme.plot
            border.width: 1; border.color: Theme.pill
            Repeater {
                model: ["tl", "tr", "bl", "br"]
                delegate: Item {
                    required property string modelData
                    required property int index
                    readonly property bool chosen: section.p.date_imprint_corner === modelData
                    x: (index % 2) * pad.width / 2; y: Math.floor(index / 2) * pad.height / 2
                    width: pad.width / 2; height: pad.height / 2
                    Rectangle {
                        width: parent.chosen ? 6.6 : 5.2; height: width; radius: width / 2
                        x: (parent.index % 2 === 0 ? 8 : parent.width - 8) - width / 2
                        y: (parent.index < 2 ? 8 : parent.height - 8) - height / 2
                        color: parent.chosen ? Theme.selection : "transparent"
                        border.width: 1; border.color: parent.chosen ? Theme.selection : Theme.dim
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: section.set("date_imprint_corner", parent.modelData)
                    }
                }
            }
        }
        Text {
            anchors.left: pad.right; anchors.leftMargin: 8
            anchors.verticalCenter: pad.verticalCenter
            text: L10n.tr("dateBack.cornerNote")
            color: Theme.dim
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
        }
    }
    ScrubSlider {
        label: L10n.tr("dateBack.size")
        from: 0.4; to: section.date.sizeMax === undefined ? 3 : section.date.sizeMax; defaultValue: 1
        step: 0.05; snap: 0.1; decimals: 1; suffix: "×"
        value: Number(section.p.date_imprint_size)
        gestureKey: "date_imprint_size"
        available: section.usable
        reason: section.offReason
        onMoved: function(v) { section.set("date_imprint_size", v) }
    }
    ScrubSlider {
        label: L10n.tr("dateBack.brightness")
        sublabel: L10n.tr("dateBack.stops")
        from: -2; to: 8; defaultValue: 3.5
        step: 0.1; snap: 0.5; decimals: 1; signed: true
        value: Number(section.p.date_imprint_ev)
        gestureKey: "date_imprint_ev"
        available: section.usable
        reason: section.offReason
        onMoved: function(v) { section.set("date_imprint_ev", v) }
    }
    // Which camera it is, where that came from, and which way the date runs.
    Note {
        text: {
            if (!section.date.camera) return section.noBackReason
            var head = L10n.tr("dateBack.camera", [section.cameraTitle,
                L10n.tr(section.date.cameraFromEdge ? "dateBack.fromFilmEdge" : "dateBack.fromFilmFormat")])
            if (!section.date.pictureKnown) return head
            return head + " " + L10n.tr(section.date.turned ? "dateBack.turned" : "dateBack.level")
        }
    }
}
