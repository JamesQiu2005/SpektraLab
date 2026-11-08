//  LightTableShare.swift — the light table as a picture to share.
//
//  The website's `share.js` (`poster`): the whole table as it lies, and under it the SpektraLab
//  mark at the left and a QR code for the app's address at the right, so whoever sees the picture
//  can find the app. Laid out in table millimetres exactly as `share.js` lays it out — a margin
//  round the table's frame, then under the table a row with the mark and the code — and drawn at
//  2,400 pixels along the picture's long side. A landscape table's poster is wide, the mark and the
//  code in a column at the table's right; an A5 or A6 table's is composed as A4's
//  (`LightTableExportPlan.Poster`, where every place is measured).
//
//  What differs from the website, and why:
//
//  - **The code is Core Image's own** (`CIQRCodeGenerator`, level M), made here: the website ships
//    the same code as a table of bits, made by Core Image (`scripts/qr.swift`). Its modules are read
//    back and drawn whole, on whole pixels, as the website draws its table. The address is the
//    website's, `https://spektralab.app/`.
//  - **The mark is the app's logo** from its own assets (`Logo`), where the website draws its
//    192-pixel icon; the words are the app's system face, as the website's are the page's.
//  - **Display P3, 8 bits**, the table's own space; the website's canvas is sRGB.
//
//  Nothing is sent: the picture is handed to the caller, which offers the system's share sheet.

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

enum LightTableShare {
    static let site = "spektralab.app"
    static let address = "https://spektralab.app/"
    /// Pixels along the picture's long side (`LONG`).
    static let long = LightTableExportPlan.posterLong
    static let ink = UIColor(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1)
    static let ink2 = UIColor(red: 0x6e / 255, green: 0x6e / 255, blue: 0x73 / 255, alpha: 1)

    /// The code's modules, row by row, true for a dark one: Core Image's, without its quiet zone.
    static func modules(_ text: String = address) -> [[Bool]]? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let w = Int(out.extent.width), h = Int(out.extent.height)
        var px = [UInt8](repeating: 255, count: w * h)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        ctx.render(out, toBitmap: &px, rowBytes: w, bounds: out.extent, format: .L8, colorSpace: nil)
        // Its quiet zone: the rows and columns with no dark module.
        let rows = (0..<h).filter { y in (0..<w).contains { px[y * w + $0] < 128 } }
        let cols = (0..<w).filter { x in (0..<h).contains { px[$0 * w + x] < 128 } }
        guard let y0 = rows.first, let y1 = rows.last, let x0 = cols.first, let x1 = cols.last else { return nil }
        return (y0...y1).map { y in (x0...x1).map { x in px[y * w + x] < 128 } }
    }

    /// The poster (`poster`): `picture` is the table drawn over the poster's rect at the width asked
    /// (`LightTableRenderer.picture`), the tagline and the call to scan in the app's words. The
    /// places are `LightTableExportPlan.poster`'s, in millimetres from the top left.
    static func poster(half: CGSize, picture: (Double, Double, Double, Double, Double) -> CGImage?,
                       tagline: String = L("Not a filter. A print."), scan: String = L("Scan to visit")) -> CGImage? {
        let plan = LightTableExportPlan.poster(half: half)
        guard let table = picture(plan.x0, plan.y0, plan.x1, plan.y1, long * plan.width / max(plan.width, plan.height)) else { return nil }
        let w = table.width, h = table.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(table, in: CGRect(x: 0, y: 0, width: w, height: h))
        // From here the canvas's way up: y down from the top, as `share.js` draws.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let k = Double(w) / plan.width                              // px a mm
        let u = plan.unit
        let fit = plan.wordsWidth.map { $0 * k }

        // the mark: the app's logo, its name, and its line. A shadow's offset is in the context's
        // base space, y up, whatever the CTM: the canvas's 0.35 mm down is −0.35 here.
        if let icon = UIImage(named: "Logo") {
            let s = plan.logoSide * k
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.35 * u * k), blur: 1.6 * u * k, color: UIColor(white: 0, alpha: 0.14).cgColor)
            icon.draw(in: CGRect(x: plan.logo.x * k, y: plan.logo.y * k, width: s, height: s))
            ctx.restoreGState()
        }
        text("SpektraLab", at: CGPoint(x: plan.name.x * k, y: plan.name.y * k), size: plan.nameSize * k, weight: .semibold, color: ink, fit: fit)
        text(tagline, at: CGPoint(x: plan.line.x * k, y: plan.line.y * k), size: plan.smallSize * k, weight: .regular, color: ink2, fit: fit)

        // the code on a white card, whole modules on whole pixels, and where it goes
        if let code = modules() {
            let n = code.count
            let cell = (plan.codeSide * k / Double(n + 4)).rounded(.down), side = cell * Double(n + 4)
            let a = CGPoint(x: plan.codeAnchor.x * k, y: plan.codeAnchor.y * k)
            // portrait: hung from its right edge, its middle on the row's; landscape: from its left
            // edge, its bottom on the table's bottom edge
            let qx = (plan.codeWordsRight ? a.x - side : a.x).rounded(), qy = (plan.codeWordsRight ? a.y - side / 2 : a.y - side).rounded()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.3 * u * k), blur: 1.4 * u * k, color: UIColor(white: 0, alpha: 0.12).cgColor)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: qx, y: qy, width: side, height: side), cornerWidth: 2 * u * k, cornerHeight: 2 * u * k,
                               transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.setFillColor(ink.cgColor)
            for (y, line) in code.enumerated() {
                for (x, dark) in line.enumerated() where dark {
                    ctx.fill(CGRect(x: qx + Double(x + 2) * cell, y: qy + Double(y + 2) * cell, width: cell, height: cell))
                }
            }
            // the address and the call: beside the card (portrait, ending 5 mm before it), or over
            // it (landscape, from its left edge, their baselines measured up from its top)
            let sx = qx + plan.site.x * k, top = plan.codeWordsRight ? 0 : qy
            text(site, at: CGPoint(x: sx, y: top + plan.site.y * k), size: plan.siteSize * k, weight: .semibold, color: ink,
                 right: plan.codeWordsRight, fit: fit)
            text(scan, at: CGPoint(x: qx + plan.scan.x * k, y: top + plan.scan.y * k), size: plan.smallSize * k, weight: .regular,
                 color: ink2, right: plan.codeWordsRight, fit: fit)
        }
        return ctx.makeImage()
    }

    /// A line of words with its baseline at `p` (the canvas's `fillText`), left or right aligned;
    /// set smaller, never cut, when it is wider than `fit` points (the landscape poster's column).
    private static func text(_ s: String, at p: CGPoint, size: Double, weight: UIFont.Weight, color: UIColor, right: Bool = false,
                             fit: Double? = nil) {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        var a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        if let fit, a.size().width > fit {
            font = UIFont.systemFont(ofSize: size * fit / a.size().width, weight: weight)
            a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let width = a.size().width
        // UIKit draws from the line's top: the baseline is the font's ascender below it.
        a.draw(at: CGPoint(x: right ? p.x - width : p.x, y: p.y - font.ascender))
    }
}
