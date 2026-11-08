import Foundation

extension AppServices {
    /// Shared by the visible Develop/Edit Paste action and its workflow check.
    @discardableResult func pasteSettings(into session: OpenFrameSession) -> Bool {
        guard let clip = library.clipboard, clip.missingMaterials.isEmpty else { return false }
        applyLook(clip, to: session)
        return true
    }

    /// The layer is captured before the synchronous transaction. A picked frame's
    /// reset never uses +Film scope, which would also move its surroundings.
    func resetPage(_ scope: PageResetScope, in session: OpenFrameSession) {
        guard let pair = session.pair else {
            session.change { $0 = $0.resetting(scope) }; return
        }
        let layer = session.layer
        let side = pair.pickedSide(layer)
        if scope == .decode {
            guard let focus = side ?? session.placementSide, let source = library.frame(pair[focus]?.frame),
                  source.edit.decode.whiteBalance != .asShot else { return }
            changeDecode(of: focus, in: session.frameID) { d in d.whiteBalance = .asShot }
            keepDecode(of: focus, in: session.frameID)
        } else if let side, [.filmExposure, .enlarger, .preflash, .crop].contains(scope) {
            let trim = pair.trim(on: layer, look: session.edit.params)
            if scope == .filmExposure, pair[side]?.exposureEV == 0 { return }
            if scope == .crop, pair[side]?.placement == HalfFramePair.Placement() { return }
            if scope == .enlarger, trim.brightnessStops == 0 && trim.yFilterShift == 0 && trim.mFilterShift == 0 { return }
            if scope == .preflash, trim.preflashExposure == 0 { return }
            changePair(session.frameID) { piece, look in
                switch scope {
                case .filmExposure: piece[side]?.exposureEV = 0
                case .enlarger, .preflash:
                    var trim = piece.trim(on: layer, look: look.params)
                    if scope == .enlarger { trim.brightnessStops = 0; trim.yFilterShift = 0; trim.mFilterShift = 0 }
                    else { trim.preflashExposure = 0 }
                    piece[side]?.print = trim
                case .crop: piece[side]?.placement = HalfFramePair.Placement()
                default: break
                }
            }
        } else if side == nil, [.enlarger, .preflash].contains(scope) {
            changePair(session.frameID) { piece, look in
                let fields: [PrintField] = scope == .enlarger ? [.brightness, .yellow, .magenta] : [.preflash]
                for field in fields { piece.print(field, 0, on: .film, look: &look.params) }
            }
        } else {
            session.change { $0 = $0.resetting(scope) }
        }
    }

    /// Single photos use the same pure leaf transfer as the clipboard. On a
    /// pair stocks/effects/Layer 2 belong to the piece; decode/exposure/print
    /// belong to the picked frame (film layer applies the shared look).
    func applyLook(_ clip: SettingsClip, to session: OpenFrameSession) {
        guard clip.missingMaterials.isEmpty else { return }
        let ownsHistory = session.beginHistoryTransaction()
        defer { if ownsHistory { session.endHistoryTransaction() } }
        // The picture is the frame's own (a pair's, the piece's), which a pasted film edge lies along
        // (`SettingsClip.turn`); a session whose frame has left the library has nothing to paste onto.
        guard let picture = session.frame?.originalSize else { return }
        guard let pair = session.pair else {
            session.change { $0 = clip.applied(to: $0, picture: picture) }; return
        }
        let layer = session.layer, side = pair.pickedSide(session.layer)
        var shared = clip
        // Decode always belongs to the source frame, including on the film layer.
        shared.groups.subtract([.decode, .enlarger, .preflash])
        if side != nil { shared.groups.subtract([.filmExposure, .enlarger, .preflash, .decode]) }
        let decodeSide = clip.groups.contains(.decode) ? (side ?? session.placementSide) : nil
        if let focus = decodeSide, let source = library.frame(pair[focus]?.frame) {
            let decode = SettingsClip(groups: [.decode], settings: clip.settings, sourceName: "").applied(to: source.edit, picture: source.originalSize).decode
            library.update(source.id) { $0.edit.decode = decode }
        }
        changePair(session.frameID) { piece, look in
            look = shared.applied(to: look, picture: picture)
            guard let side else {
                let from = HalfFramePair.PrintTrim(clip.settings.params)
                if clip.groups.contains(.enlarger) {
                    for field in [PrintField.brightness, .yellow, .magenta] { piece.print(field, from[field], on: .film, look: &look.params) }
                }
                if clip.groups.contains(.preflash) { piece.print(.preflash, from.preflashExposure, on: .film, look: &look.params) }
                return
            }
            if clip.groups.contains(.filmExposure) {
                piece[side]?.exposureEV = clip.settings.params.exposureCompensationEV
                piece[side]?.autoExposure = clip.settings.params.autoExposure
                piece[side]?.meterMethod = clip.settings.params.autoExposureMethod
                piece[side]?.meteredEV = nil; piece[side]?.meteredFor = nil
            }
            var trim = piece.trim(on: layer, look: look.params)
            if clip.groups.contains(.enlarger) {
                trim.brightnessStops = clip.settings.params.printBrightnessStops
                trim.yFilterShift = clip.settings.params.yFilterShift; trim.mFilterShift = clip.settings.params.mFilterShift
            }
            if clip.groups.contains(.preflash) { trim.preflashExposure = clip.settings.params.preflashExposure }
            if clip.groups.contains(.enlarger) || clip.groups.contains(.preflash) { piece[side]?.print = trim }
        }
        if let decodeSide { keepDecode(of: decodeSide, in: session.frameID) }
    }
}
