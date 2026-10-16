import QtQuick
import QtQuick.Shapes

// The hollow, downward triangle the Mac uses for two things that mean "there
// is more under this": a section's disclosure (turned -90 degrees while the
// section is folded) and a pill menu's indicator (SectionHeader.swift's
// Triangle, FormatPicker.swift's chevron).
Shape {
    id: triangle
    property color color: Theme.text
    property real lineWidth: 1.2
    implicitWidth: 12; implicitHeight: 7
    // The curve renderer antialiases without multisampling; where it is not
    // available (the software backend the self-test uses) Qt falls back to
    // the default renderer, which only changes the edge quality.
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
        strokeColor: triangle.color
        strokeWidth: triangle.lineWidth
        fillColor: "transparent"
        joinStyle: ShapePath.RoundJoin
        startX: triangle.lineWidth / 2; startY: triangle.lineWidth / 2
        PathLine { x: triangle.width - triangle.lineWidth / 2; y: triangle.lineWidth / 2 }
        PathLine { x: triangle.width / 2; y: triangle.height - triangle.lineWidth / 2 }
        PathLine { x: triangle.lineWidth / 2; y: triangle.lineWidth / 2 }
    }
}
