// svgshot: draw SVG files to PNGs as WebKit draws them (the system font's real weights), at a scale.
// usage: svgshot <scale> <outdir> <svg>...
import AppKit
import WebKit

let a = CommandLine.arguments
guard a.count >= 4, let scale = Double(a[1]) else { print("usage: svgshot <scale> <outdir> <svg>..."); exit(2) }
let outDir = URL(fileURLWithPath: a[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

final class Shooter: NSObject, WKNavigationDelegate {
    var files: [URL]
    let scale: Double, outDir: URL
    var web: WKWebView!
    var window: NSWindow!
    var failed = 0
    init(files: [URL], scale: Double, outDir: URL) { self.files = files; self.scale = scale; self.outDir = outDir }

    func size(of url: URL) -> CGSize? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func attr(_ n: String) -> Double? {
            guard let r = s.range(of: "\(n)=\"", options: [], range: s.startIndex..<s.endIndex) else { return nil }
            let rest = s[r.upperBound...]
            guard let e = rest.firstIndex(of: "\"") else { return nil }
            return Double(rest[..<e])
        }
        guard let w = attr(" width"), let h = attr(" height") else { return nil }
        return CGSize(width: w, height: h)
    }

    func next() {
        guard let url = files.first else { exit(failed == 0 ? 0 : 1) }
        guard let sz = size(of: url) else { print("FAIL size \(url.lastPathComponent)"); failed += 1; files.removeFirst(); next(); return }
        let frame = NSRect(origin: .zero, size: sz)
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: frame, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        let html = "<html><body style='margin:0;background:#000'><img src='\(url.lastPathComponent)' width='\(sz.width)' height='\(sz.height)' style='display:block'></body></html>"
        _ = html
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let url = self.files.removeFirst()
            let cfg = WKSnapshotConfiguration()
            cfg.rect = webView.bounds
            cfg.snapshotWidth = NSNumber(value: Double(webView.bounds.width) * self.scale / Double(NSScreen.main?.backingScaleFactor ?? 2))
            webView.takeSnapshot(with: cfg) { image, error in
                if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let out = self.outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
                    try? png.write(to: out)
                    print("\(url.lastPathComponent) -> \(rep.pixelsWide)x\(rep.pixelsHigh)")
                } else { print("FAIL \(url.lastPathComponent) \(String(describing: error))"); self.failed += 1 }
                self.next()
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("FAIL load \(files.first?.lastPathComponent ?? "") \(error)"); failed += 1; files.removeFirst(); next()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shooter = Shooter(files: a[3...].map { URL(fileURLWithPath: $0) }, scale: scale, outDir: outDir)
DispatchQueue.main.async { shooter.next() }
app.run()
