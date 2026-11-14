//  LensCorrectionPart.swift — 编辑 › 镜头's first part, Capture One's 镜头校正 (2.4.0, the panel's stage; the drawings
//  are PRD/lens-correction-2026-11-13/c1-lens-panel.png and c1-profile-popup.png).
//
//      配置文件   [ Manufacturer Profile          ⌃⌄ ]
//                 ☑ 隐藏畸变区域
//      畸变       ───────────────●──   100
//      光衰减     ●─────────────────     0      (greyed: not live in this build)
//      Corrected by macOS's profile of this lens.
//
//  - **A RAW photograph only.** A JPEG or HEIC, a half-frame pair, a double exposure and a frame whose original is
//    away show the heading and one line saying why; nothing else (a pair's and a double's photographs are each
//    corrected as their own, by their own edits).
//  - **What is in effect** is the session's resolution (`OpenFrameSession.lensResolution`, `LensResolver`): who
//    corrects, with which lens, which controls are live (`adjustsDistortion`, `adjustsHideDistortedAreas`,
//    `adjustsLightFalloff`) and why — said in the line in this page's words, never `why.text` raw. **While it has not
//    settled the last settled answer stays** (`shown`): forgetting the kept answers after a lens install, or a
//    resolution measured for the first time, never blinks the popup to another name and back.
//  - **The popup** (`LensProfilePopUp`) is a real menu, built when it opens: Manufacturer Profile; the lenses the
//    database recommends for this photograph; one row per maker, whose lenses are read only when the row is opened;
//    Add .lcp File… and None. Every choice is one `session.change`, so Undo walks it.
//  - **畸变 and 光衰减** are the one slider, a drag one Undo step (`began(.shoot)` … `ended()`, as the section's other
//    sliders). No 色像差, 衍射校正 or 锐度衰减 rows: nothing true stands behind them (decided 2026-11-13).

import SwiftUI
import UIKit

// MARK: - the part

struct LensCorrectionPart: View {
    let session: OpenFrameSession
    @Environment(AppRouter.self) private var router

    /// The last settled answer of this frame: what the part shows while a new one is being made.
    @State private var shown: LensResolution?
    /// The frame and the choice `shown` is of (`shownKey`).
    @State private var shownFor: String?
    /// Automatic's answer for this photograph whatever is chosen (the popup's Manufacturer Profile: offered where it is
    /// macOS's or the file's own).
    @State private var automatic: LensResolution?
    @State private var automaticFor: String?

    private var edit: FrameEdit { session.edit }
    private var decode: DecodeSettings { edit.decode }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LensPartHeading(title: L("Lens Correction"))
            if let reason = standDown {
                LensPartLine(text: reason)
            } else {
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjust.lens.correction")
        .onAppear { LensLibrary.shared.warm() }
        .onChange(of: session.lensResolution, initial: true) { _, now in keep(now) }
        .task(id: automaticKey) { await resolveAutomatic() }
    }

    /// Why the part stands down, or nil for a RAW photograph that is here.
    private var standDown: String? {
        guard let frame = session.frame else { return L("No photograph is open") }
        if frame.isPair { return L("Each photograph of a pair is corrected by its own edit") }
        if frame.isDouble { return L("Each photograph of a double exposure is corrected by its own edit") }
        if !frame.developsFromRAW { return L("Lens correction is for RAW files") }
        if frame.developSource == nil || session.lensResolution == nil { return L("The original file is not on this Mac") }
        return nil
    }

    /// What the part shows: the session's answer once it has settled; until then the last settled one of this frame,
    /// with the decode's own amounts (a slider moved meanwhile shows where it is).
    private var resolution: LensResolution? {
        guard let now = session.lensResolution else { return nil }
        guard !now.settled, now.on, shownFor == shownKey, let shown else { return now }
        return LensResolution(base: shown.base, decode: decode)
    }

    /// The frame and its choice: an answer kept for automatic is never shown for a chosen lens, nor the reverse.
    private var shownKey: String { session.frameID.uuidString + "|" + (decode.lensProfile?.key ?? "auto") }

    private func keep(_ now: LensResolution?) {
        guard let now, now.settled, now.on else { return }
        shown = now
        shownFor = shownKey
    }

    @ViewBuilder private var controls: some View {
        let r = resolution
        HStack(alignment: .center, spacing: 8) {
            Text(L("Profile", as: "a lens"))
                .font(Theme.Font.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 92, alignment: .trailing)
            LensProfilePopUp(state: menuState(r), act: act)
                .frame(maxWidth: .infinity)
        }
        HStack(spacing: 8) {
            Color.clear.frame(width: 92, height: 1)
            Button {
                session.change { $0.decode.lensHideDistortedAreas.toggle() }
            } label: {
                HStack(spacing: 8) {
                    TickBox(on: decode.lensHideDistortedAreas, side: 16)
                    Text(L("Hide Distorted Areas")).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Hide Distorted Areas"))
            .accessibilityValue(decode.lensHideDistortedAreas ? L("On") : L("Off"))
            .accessibilityIdentifier("adjust.lens.hide")
            .rowEnabled(r?.adjustsHideDistortedAreas == true)
            Spacer(minLength: 0)
        }
        ValueSlider(title: L("Distortion", as: "a lens"),
                    value: Binding(get: { decode.lensDistortion }, set: { session.setLensDistortion($0) }),
                    range: DecodeSettings.lensAmountRange, rest: DecodeSettings.defaultLensDistortion,
                    text: { String(format: "%.0f", $0) }, detentAtRest: true,
                    onEditingChanged: session.editing(.shoot))
            .rowEnabled(r?.adjustsDistortion == true)
            .accessibilityIdentifier("adjust.lens.distortion")
        ValueSlider(title: L("Light Falloff"),
                    value: Binding(get: { decode.lensLightFalloff }, set: { session.setLensLightFalloff($0) }),
                    range: DecodeSettings.lensAmountRange, rest: DecodeSettings.defaultLensLightFalloff,
                    text: { String(format: "%.0f", $0) }, detentAtRest: true, showsRest: false,
                    onEditingChanged: session.editing(.shoot))
            .rowEnabled(r?.adjustsLightFalloff == true)
            .accessibilityIdentifier("adjust.lens.falloff")
        LensPartLine(text: r.map { LensWords.line($0) } ?? "")
            .accessibilityIdentifier("adjust.lens.why")
    }

    // MARK: the popup's state and acts

    private func menuState(_ r: LensResolution?) -> LensProfilePopUp.State {
        let auto = automatic?.settled == true ? automatic : nil
        let manufacturer = auto.map { [.coreImage, .embedded].contains($0.base.corrector) }
        let databaseEmpty = LensLibrary.shared.isEmpty || LensLibrary.shared.database == nil
        return LensProfilePopUp.State(
            face: r.map { LensWords.face($0, pick: decode.lensProfile) } ?? "",
            on: decode.lensCorrection,
            manufacturerTicked: decode.lensCorrection && decode.lensProfile == nil
                && (r.map { [.coreImage, .embedded].contains($0.base.corrector) } ?? false),
            manufacturer: manufacturer,
            inEffect: r?.corrector == .database ? r?.lens?.key : nil,
            recommended: session.recommendedLenses.map(\.lens),
            makers: LensLibrary.shared.makers,
            databaseEmpty: databaseEmpty,
            revision: LensLibrary.shared.revision)
    }

    private func act(_ a: LensProfilePopUp.Act) {
        switch a {
        case .manufacturer:
            guard !(decode.lensCorrection && decode.lensProfile == nil) else { return }
            session.change { $0.decode.lensCorrection = true; $0.decode.lensProfile = nil }
        case .lens(let lens):
            let pick = DecodeSettings.LensPick(key: lens.key, name: lens.name)
            guard !(decode.lensCorrection && decode.lensProfile == pick) else { return }
            session.change { $0.decode.lensCorrection = true; $0.decode.lensProfile = pick }
        case .none:
            guard decode.lensCorrection else { return }
            session.setLensCorrection(false)
        case .add:
            Task { @MainActor in
                guard let file = await MacOpenPanel.chooseLensProfile() else { return }
                await addProfile(file)
            }
        case .openSettings:
            guard router.cover == nil else { return }
            router.dismissAllSheets()
            SettingsRequest.next = .previewSize
            router.show(.settings)
        }
    }

    /// Add .lcp File…: into the same database, then chosen for this photograph.
    func addProfile(_ file: URL) async {
        guard let lens = await LensLibrary.shared.add(file: file) else { return }
        session.change { $0.decode.lensCorrection = true; $0.decode.lensProfile = DecodeSettings.LensPick(key: lens.key, name: lens.name) }
    }

    // MARK: automatic, whatever is chosen

    private var automaticKey: String {
        guard let frame = session.frame, frame.developsFromRAW, !frame.isComposite, let url = frame.developSource else { return "" }
        return url.path + "|\(LensLibrary.shared.revision)"
    }

    private func resolveAutomatic() async {
        let key = automaticKey
        guard !key.isEmpty, let url = session.frame?.developSource else { automatic = nil; return }
        if automaticFor != key { automatic = nil }
        var d = decode
        d.lensCorrection = true
        d.lensProfile = nil
        let made = await Task.detached(priority: .utility) { await LensResolver.resolve(url, decode: d) }.value
        guard !Task.isCancelled else { return }
        automatic = made
        automaticFor = key
    }
}

/// A part's heading inside the section (`LensEdgePanels`' `PartHeading`, which is private there).
struct LensPartHeading: View {
    let title: String
    var body: some View {
        Text(title).font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The part's quiet line: who corrects and why. It wraps rather than end in "…".
struct LensPartLine: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - the words

/// The part's words for a resolution, in this page's language (`LensResolution.Why` is English, for the log).
enum LensWords {
    /// What the popup's face says is in effect.
    static func face(_ r: LensResolution, pick: DecodeSettings.LensPick?) -> String {
        guard r.on else { return L("None", as: "a lens profile") }
        if let pick { return pick.name }
        switch r.base.corrector {
        case .coreImage, .embedded: return L("Manufacturer Profile")
        case .database: return r.lens?.name ?? L("Manufacturer Profile")
        case .nobody: return L("No Profile Found")
        }
    }

    /// Who corrects, and why: one line.
    static func line(_ r: LensResolution) -> String {
        let name = r.lens?.name ?? ""
        switch r.why {
        case .off: return L("Lens correction is off.")
        case .notRAW: return L("Lens correction is for RAW files")
        case .alreadyCorrected: return L("Not corrected: this file's lens is corrected already.")
        case .coreImage: return L("Corrected by macOS's profile of this lens.")
        case .coreImageUnresolved: return L("Corrected by macOS where it has a profile of this lens.")
        case .coreImageChangesNothing: return L("Not corrected: macOS's profile of this lens changes nothing, and no other profile matches it.")
        case .embedded: return L("Corrected from the lens parameters in the file.")
        case .exif: return L("Corrected with \(name) from the lens library.")
        case .chosen: return L("Corrected with \(name).")
        case .chosenMissing: return L("Not corrected: the chosen lens is not in the lens library.")
        case .noProfile: return L("Not corrected: no profile of this lens on this Mac.")
        case .profileWithoutDistortion: return L("Not corrected: the profile has no distortion model.")
        }
    }
}

// MARK: - the popup

/// 配置文件's popup: Capture One's, as a real menu (a `UIButton` whose menu is its primary action). The whole menu is
/// made when it opens (`UIDeferredMenuElement`, from `state` as it is then), and a maker's lenses only when its row is
/// opened, so 2,139 lenses cost nothing until one maker's are asked for. `LensMenuTimes` keeps how long each took.
struct LensProfilePopUp: UIViewRepresentable {
    struct State {
        var face: String
        var on: Bool
        var manufacturerTicked: Bool
        /// Whether this photograph has a manufacturer's profile (macOS's or the file's own); nil: not known yet.
        var manufacturer: Bool?
        /// The database lens in effect.
        var inEffect: String?
        var recommended: [LensDatabase.Lens]
        var makers: [String]
        var databaseEmpty: Bool
        var revision: Int
    }
    enum Act { case manufacturer, lens(LensDatabase.Lens), none, add, openSettings }

    let state: State
    let act: (Act) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        let face = UIHostingController(rootView: LensProfileFace(text: state.face))
        face.view.backgroundColor = .clear
        face.view.translatesAutoresizingMaskIntoConstraints = false
        face.view.isUserInteractionEnabled = false
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "adjust.lens.profile"
        host.addSubview(face.view)
        host.addSubview(button)
        for v in [face.view!, button] {
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        }
        context.coordinator.face = face
        context.coordinator.button = button
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak coordinator] done in
            done(coordinator?.menu() ?? [])
        }])
        LensProfilePopUp.shownButton = button
        LensProfilePopUp.lastCoordinator = coordinator
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.state = state
        context.coordinator.act = act
        context.coordinator.face?.rootView = LensProfileFace(text: state.face)
        context.coordinator.button?.accessibilityLabel = L("Profile", as: "a lens")
        context.coordinator.button?.accessibilityValue = state.face
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        guard let face = context.coordinator.face else { return nil }
        let w = proposal.width ?? 200
        let fit = face.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(fit.height, 26))
    }

    /// The popup on the page now (a check presents its menu, as a click does).
    @MainActor static weak var shownButton: UIButton?
    @MainActor static weak var lastCoordinator: Coordinator?

    @MainActor
    final class Coordinator {
        var state: State?
        var act: (Act) -> Void = { _ in }
        weak var button: UIButton?
        var face: UIHostingController<LensProfileFace>?

        /// The menu as it opens, from the state as it is now.
        func menu() -> [UIMenuElement] {
            let started = DispatchTime.now().uptimeNanoseconds
            defer { LensMenuTimes.record("menu", since: started) }
            guard let s = state else { return [] }
            let act = self.act
            // Manufacturer Profile: automatic. Ticked where macOS or the file corrects; greyed with a note where this
            // photograph has neither.
            let manufacturer = UIAction(title: L("Manufacturer Profile"), state: s.manufacturerTicked ? .on : .off) { _ in act(.manufacturer) }
            manufacturer.accessibilityIdentifier = "lens.menu.manufacturer"
            if s.manufacturer == false && !s.manufacturerTicked {
                manufacturer.attributes = .disabled
                manufacturer.subtitle = L("This photograph has none")
            }
            // What the database recommends for this photograph.
            var recommended: [UIMenuElement] = s.recommended.map { lens in
                let a = UIAction(title: lens.name, state: s.on && s.inEffect == lens.key ? .on : .off) { _ in act(.lens(lens)) }
                return a
            }
            if s.databaseEmpty {
                recommended = [UIAction(title: L("Install Lens Profiles in Settings…")) { _ in act(.openSettings) }]
            } else if recommended.isEmpty {
                recommended = [UIAction(title: L("No lens profile matches this photograph"), attributes: .disabled) { _ in }]
            }
            // One row a maker; its lenses read when it is opened.
            let makers: [UIMenuElement] = s.makers.map { maker in
                UIMenu(title: maker, children: [UIDeferredMenuElement { done in
                    let asked = DispatchTime.now().uptimeNanoseconds
                    Task { @MainActor in
                        let lenses = await LensLibrary.shared.lenses(maker: maker)
                        let items: [UIMenuElement] = lenses.map { lens in
                            let a = UIAction(title: lens.name, state: s.on && s.inEffect == lens.key ? .on : .off) { _ in act(.lens(lens)) }
                            if !lens.rectilinear { a.attributes = .disabled; a.subtitle = L("Fisheye: not applied") }
                            return a
                        }
                        done(items)
                        LensMenuTimes.record("maker " + maker, since: asked)
                    }
                }])
            }
            let add = UIAction(title: L("Add .lcp File…")) { _ in act(.add) }
            let none = UIAction(title: L("None", as: "a lens profile"), state: s.on ? .off : .on) { _ in act(.none) }
            return [UIMenu(options: .displayInline, children: [manufacturer]),
                    UIMenu(options: .displayInline, children: recommended),
                    UIMenu(options: .displayInline, children: makers),
                    UIMenu(options: .displayInline, children: [add, none])]
        }
    }
}

/// The popup's face: what is in effect, and the up-down chevron, on the card colour (the drawing's).
struct LensProfileFace: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text)
                .lineLimit(2).minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// How long the popup took to make: the whole menu as it opens, and each maker's lenses (milliseconds, the last of each).
@MainActor
enum LensMenuTimes {
    private(set) static var last: [String: Double] = [:]
    static func record(_ what: String, since started: UInt64) {
        last[what] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    }
    static func clear() { last = [:] }
}
