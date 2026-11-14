//  NeutralPickSession.swift — the page's side of the neutral-grey eyedroppers (`NeutralPick`): which one is
//  out, whether this frame can take it, and the click on the canvas turned into a white balance.
//
//  The canvas hands over the click as a point of the picture it shows (normalised, top-left): the develop
//  through Edit's crop of the finished picture. That is taken back through that crop to the develop
//  (`Geometry.sourcePoint(forOutput:)`) — where the print's eyedropper reads its colour — and on through the
//  photo's own cut, its straighten, turns and perspective, to the original (`Geometry.originalPoint`), where
//  the decode's eyedropper does.

import ImageIO
import SwiftUI

extension OpenFrameSession {
    /// Why this frame's `target` eyedropper cannot be used, or nil when it can.
    func neutralPickRefusal(_ target: NeutralPick.Target) -> String? {
        guard let frame else { return L("This picture cannot be opened") }
        if frame.isPair { return L("Not on a half-frame pair") }
        switch target {
        case .print:
            return nil
        case .decode:
            if !frame.isRAW { return L("RAW files only") }
            // The develop is then the film's whole canvas, its border and holes round the picture: a point on it
            // is no point of the original.
            if edit.filmEdge.effective { return L("Not with a film edge on") }
            if frame.developSource.map({ FileManager.default.fileExists(atPath: $0.path) }) != true { return L("Original missing") }
            return nil
        }
    }

    /// The eyedropper's button: out, or put away when it is out already.
    func toggleNeutralPick(_ target: NeutralPick.Target) {
        neutralNote = nil
        neutralPick = neutralPick == target ? nil : target
    }

    /// A click on the canvas while an eyedropper is out, `n` in the picture shown (normalised, top-left).
    func pickNeutral(at n: CGPoint) {
        guard let target = neutralPick, let frame else { return }
        neutralPick = nil
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { neutralNote = L("Click on the picture"); return }
        guard let image = developedCGImage ?? Self.keptDevelop(frame) else { neutralNote = L("The picture is still developing"); return }
        let size = CGSize(width: image.width, height: image.height)
        // Through Edit's crop of the finished picture, to the develop.
        let onDevelop = edit.printCrop.isIdentity ? n : edit.printCrop.sourcePoint(forOutput: n, imageSize: size)
        switch target {
        case .print:
            guard let c = NeutralPick.sample(image, at: onDevelop),
                  let balance = NeutralPick.printBalance(r: c.x, g: c.y, b: c.z) else {
                neutralNote = L("Too dark to have a colour: choose a lighter grey")
                return
            }
            beganEdit()
            changeEdit { a in
                a[.temperature] = balance.temperature.rounded()
                a[.tint] = balance.tint.rounded()
            }
            endedEdit()
            neutralNote = balance.clamped ? L("As near grey as Temperature and Tint reach")
                : L("Temperature \(Fmt.signed(balance.temperature.rounded(), decimals: 0)), Tint \(Fmt.signed(balance.tint.rounded(), decimals: 0))")
        case .decode:
            guard let url = frame.developSource else { return }
            let original = CGSize(width: frame.originalSize.width, height: frame.originalSize.height)
            let point = edit.geometry.originalPoint(forOutput: onDevelop, imageSize: original)
            let settings = edit.decode, start = (edit.decode.temperature, edit.decode.tint)
            neutralNote = L("Measuring the grey…")
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    NeutralPick.decodeBalance(url: url, settings: settings, at: point, start: start)
                }.value
                guard let self else { return }
                guard let found else { self.neutralNote = L("Too dark to have a colour: choose a lighter grey"); return }
                #if DEBUG
                NSLog("[neutral] decode at (%.4f, %.4f): %.0f K, tint %.1f, residual %.4f after %d steps",
                      point.x, point.y, found.temperature, found.tint, found.residual, found.steps)
                #endif
                self.change { e in
                    e.decode.whiteBalance = .custom
                    e.decode.temperature = found.temperature.rounded()
                    e.decode.tint = found.tint.rounded()
                }
                self.neutralNote = found.residual < 0.02
                    ? L("White balance \(Int(found.temperature.rounded())) K, tint \(Fmt.signed(found.tint.rounded(), decimals: 0))")
                    : L("As near grey as the white balance reaches")
            }
        }
    }

    /// The frame's kept develop, read from its file: the picture the canvas shows before the page's own lands.
    private static func keptDevelop(_ frame: LibraryFrame) -> CGImage? {
        guard let url = frame.shownDevelop?.picture.fileURL ?? frame.picture.fileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The eyedropper's button, at a white balance's ↺: out (lit) or put away, and greyed where this frame cannot take it.
struct NeutralPickButton: View {
    let session: OpenFrameSession
    let target: NeutralPick.Target
    var diameter: CGFloat = 28

    var body: some View {
        let refusal = session.neutralPickRefusal(target)
        let out = session.neutralPick == target
        Button { session.toggleNeutralPick(target) } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: diameter * 0.5, weight: .medium))
                .foregroundStyle(out ? Theme.onSelection : Theme.text)
                .frame(width: diameter, height: diameter)
                .background(out ? Theme.selection : Theme.card, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(refusal != nil)
        .opacity(refusal == nil ? 1 : Theme.disabledOpacity)
        .help(refusal ?? L("Click a neutral grey in the picture"))
        .accessibilityLabel(L("Neutral grey"))
        .accessibilityHint(refusal ?? L("Click a neutral grey in the picture"))
        .accessibilityAddTraits(out ? .isSelected : [])
        .accessibilityIdentifier("neutral.\(target.rawValue)")
    }
}
