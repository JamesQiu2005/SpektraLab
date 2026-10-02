//  DateBackSection.swift — RFC-031's date back: the camera's LEDs exposing a
//  date onto the negative, before the developer and before halation.
//
//  Its own section, under Film Edge, because it works without one: in the bare
//  frame, a date back needs only the camera. With a film edge it can also
//  print **between** the frames. The camera is the film edge's format (the
//  engine reads the film's direction from it, `DateBackSettings.wire`).
//
//  **Which faces a camera has** is `FilmEdgeFormat.draws(_:)`: 135 and half
//  frame carry all three, 645 the data face only, and nothing larger and
//  nothing panoramic prints a date (answers C1, C7). A face the camera cannot
//  draw is greyed with the reason rather than offered and silently dropped.
//
//  **Not here yet:** the data face's colour (answer E12 wants both; the engine
//  has one), the user's own text and the insets. Each needs a decision or
//  engine work before it is a control.

import SwiftUI

struct DateBackSection: View {
    @Bindable var session: Session

    static let key = "dateBack"
    private var date: DateBackSettings { session.params.dateBack }
    private var edge: FilmEdgeSettings { session.params.filmEdge }
    /// The camera the date back is on.
    /// The camera the date back is on: the film edge's format while it is
    /// on, Film Format's otherwise. Nil when Film Format is no camera that
    /// ever carried one.
    private var camera: FilmEdgeFormat? { session.dateBackCamera }
    private func draws(_ face: DateBackFace) -> Bool { camera?.draws(face) ?? false }
    private var cameraHasBack: Bool { DateBackFace.allCases.contains(where: draws) }

    var body: some View {
        PanelSection(L(.sectionDateBack), key: Self.key, initiallyExpanded: false,
                     note: date.active ? nil : L(.edgeOff),
                     foldedNote: summary,
                     toggle: Binding(get: { date.active }, set: { setActive($0) }),
                     toggleHelp: L("Expose the date onto the negative, as a camera's date back did",
                                   zh: "像相机的日期后背一样，把日期曝光在底片上")) {
            RailRows {
                PillSwitchRow(label: L(.dateFace), options: DateBackFace.allCases,
                              selection: bind(\.face), title: { $0.key.map { L($0) } ?? "LCD" },
                              enabled: { draws($0) }, reason: { _ in noFaceReason })
                textRow
                if date.face != .data {
                    PillSwitchRow(label: L(.dateWhere), options: DateBackPlacement.allCases,
                                  selection: bind(\.placement), title: { L($0.key) },
                                  enabled: { $0 == .frame || edge.effective },
                                  reason: { _ in L(.reasonBetweenNeedsFilmEdge) })
                    if !edge.effective {
                        Text(L(.reasonBetweenNeedsFilmEdge))
                            .font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Theme.Metric.sliderLabelWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    cornerRow
                }
                ScrubSlider(label: L(.dateSize), value: bind(\.size), range: sizeRange,
                            zero: DateBackSettings.default.size, snap: 0.1,
                            format: { String(format: "%.1f×", $0) })
                ScrubSlider(label: L(.dateBrightness), sublabel: L(.dateStops),
                            value: bind(\.brightnessEV), range: DateBackSettings.brightnessRange,
                            zero: DateBackSettings.default.brightnessEV, snap: 0.5,
                            format: { String(format: "%+.1f", $0) })
                Text(cameraNote)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rowEnabled(date.active && cameraHasBack,
                        because: cameraHasBack ? L("Switch Date Back on in its header.", zh: "先在标题栏开启日期后背。")
                                               : noBackReason)
        }
    }

    // MARK: rows

    /// The date as it will print, and the order it is written in. The text is
    /// the session's: the date from EXIF in the chosen order, or for the data
    /// face the shooting data.
    @ViewBuilder private var textRow: some View {
        HStack(spacing: 0) {
            RowLabel(date.face == .data ? L(.dateImprint) : L(.dateDate))
            if date.face == .data {
                Text(printed.isEmpty ? "—" : printed)
                    .font(Theme.Font.value).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu {
                    ForEach(DateBackOrder.allCases) { order in
                        Button { set(\.order, order) } label: {
                            let line = "\(example(order))  ·  \(L(order.key))"
                            if order == date.order { Label(line, systemImage: "checkmark") } else { Text(line) }
                        }
                    }
                } label: {
                    HStack(spacing: 0) {
                        Text(printed.isEmpty ? "—" : printed).font(Theme.Font.label).foregroundStyle(Theme.text)
                            .lineLimit(1).fixedSize()
                            .padding(.leading, 10)
                        Spacer(minLength: 4)
                        Triangle()
                            .stroke(Theme.text, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                            .frame(width: 8, height: 5)
                            .padding(.trailing, 9)
                    }
                    .frame(width: Theme.Metric.edgeFormatPillWidth, height: Theme.Metric.controlHeight)
                    .background(Theme.pill, in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("The order the date is written in", zh: "日期的书写顺序"))
            }
            Spacer(minLength: 6)
            // Wraps rather than widens the rail: "no date in EXIF" is the
            // longer of the two and the pill before it is fixed.
            Text(date.text.isEmpty ? L("no date in EXIF", zh: "EXIF 中无日期") : L(.dateFromEXIF))
                .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    /// The camera's corner, **held level**: the pad is the camera's back, so
    /// a turned frame keeps the corner it was shot with.
    private var cornerRow: some View {
        HStack(alignment: .center, spacing: 0) {
            RowLabel(L(.dateCorner))
            CornerPad(selection: bind(\.corner))
                .frame(width: Theme.Metric.dateCornerPad.width, height: Theme.Metric.dateCornerPad.height)
            Text(L("the camera's,\nheld level", zh: "相机的角，\n按横持计"))
                .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: words

    private var printed: String { date.printedText }

    private var summary: String? {
        guard date.active else { return nil }
        let face = date.face.key.map { L($0) } ?? "LCD"
        return printed.isEmpty ? face : "\(face) · \(printed)"
    }

    /// On half frame the data face has only the 1 mm gap (answer B19).
    private var sizeRange: ClosedRange<Double> {
        let r = DateBackSettings.sizeRange
        guard date.face == .data, camera == .f135Half else { return r }
        return r.lowerBound...DateBackSettings.halfFrameDataSizeMax
    }

    /// Which camera it is, where that came from, and which way the date runs.
    /// The film runs down a picture that is taller than wide, so the back —
    /// and the date — turned with it.
    private var cameraNote: String {
        guard let camera else { return noBackReason }
        let name = camera.title
        let source = edge.effective ? L("from Film Edge", zh: "来自片边")
                                    : L("from Film Format", zh: "来自胶片画幅")
        let head = L("Camera: \(name), \(source).", zh: "相机：\(name)，\(source)。")
        guard let px = session.edgePicturePixels else { return head }
        // A half frame held level is the portrait one.
        let turned = (px.h > px.w) != (camera == .f135Half)
        return head + " " + (turned
            ? L("It turned for this frame, so the date runs down the picture.",
                zh: "这一格相机是竖持的，所以日期沿画面纵向排列。")
            : L("It was held level, so the date runs along the picture.",
                zh: "这一格相机是横持的，所以日期沿画面横向排列。"))
    }

    private var noBackReason: String {
        guard let camera else {
            return L("Film Format is no camera with a date back: 135, half frame or 645 has one.",
                     zh: "当前胶片画幅的相机没有日期后背：135、半格和 645 才有。")
        }
        return camera.group == .panoramic
            ? L("No date back on the panoramic formats.", zh: "宽幅画幅没有日期后背。")
            : L("No \(camera.title) camera printed a date.", zh: "\(camera.title) 相机没有日期后背。")
    }

    private var noFaceReason: String {
        L("A \(camera?.title ?? "") back has the data face only.", zh: "\(camera?.title ?? "") 的后背只有数据字体。")
    }

    /// The date in `order`, rebuilt from the printed one. The session writes
    /// it as `DateBackSettings.format` does — three fields, the year behind an
    /// apostrophe — so the fields can be moved without the date itself.
    private func example(_ order: DateBackOrder) -> String {
        let parts = date.text.split(separator: " ").map(String.init)
        guard parts.count == 3 else {
            return DateBackSettings.format(year: 2026, month: 10, day: 1, order: order)
        }
        let (y, m, d) = date.order == .japan ? (parts[0], parts[1], parts[2]) : (parts[2], parts[0], parts[1])
        return order == .japan ? "\(y) \(m) \(d)" : "\(m) \(d) \(y)"
    }

    // MARK: writes

    private func setActive(_ on: Bool) {
        var p = session.params
        p.dateBack.active = on
        // A face the camera cannot draw would turn on to nothing: take the
        // first one it can.
        if on, !draws(p.dateBack.face), let face = DateBackFace.allCases.first(where: draws) {
            p.dateBack.face = face
        }
        session.params = p
        if on { UserDefaults.standard.set(true, forKey: Session.uiKey + "section.\(Self.key)") }
    }

    private func bind<V>(_ kp: WritableKeyPath<DateBackSettings, V>) -> Binding<V> {
        Binding(get: { session.params.dateBack[keyPath: kp] }, set: { set(kp, $0) })
    }

    private func set<V>(_ kp: WritableKeyPath<DateBackSettings, V>, _ value: V) {
        var p = session.params; p.dateBack[keyPath: kp] = value; session.params = p
    }
}

/// The four corners of the camera's back, as a pad: a ring per corner, the
/// chosen one filled.
private struct CornerPad: View {
    @Binding var selection: DateBackCorner

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.plot)
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.pill, lineWidth: 1)
                ForEach(DateBackCorner.allCases) { corner in
                    let on = corner == selection
                    let x = corner == .bl || corner == .tl ? 8 : w - 8
                    let y = corner == .tl || corner == .tr ? 8 : h - 8
                    Circle()
                        .fill(on ? Theme.selection : Color.clear)
                        .overlay(Circle().stroke(on ? Theme.selection : Theme.Ink.tertiary, lineWidth: 1))
                        .frame(width: on ? 6.6 : 5.2, height: on ? 6.6 : 5.2)
                        // A target the size of the pad's quarter, not the dot.
                        .frame(width: w / 2, height: h / 2)
                        .contentShape(Rectangle())
                        .position(x: x < w / 2 ? w / 4 : 3 * w / 4, y: y < h / 2 ? h / 4 : 3 * h / 4)
                        .onTapGesture { selection = corner }
                        .accessibilityLabel(corner.rawValue)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}
