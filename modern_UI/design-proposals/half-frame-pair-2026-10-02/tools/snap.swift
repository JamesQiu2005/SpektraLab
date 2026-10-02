// Render an SVG to PNG at its own size with WebKit (design previews only).
import AppKit
import WebKit
let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let w = Double(args[3])!, h = Double(args[4])!
let app = NSApplication.shared
class D: NSObject, WKNavigationDelegate {
  func webView(_ v: WKWebView, didFinish _: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let c = WKSnapshotConfiguration(); c.rect = CGRect(x: 0, y: 0, width: w, height: h); c.snapshotWidth = NSNumber(value: w)
      v.takeSnapshot(with: c) { img, err in
        guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print(err as Any); exit(1) }
        try! png.write(to: dst); exit(0)
      }
    }
  }
}
let d = D()
let v = WKWebView(frame: CGRect(x: 0, y: 0, width: w, height: h))
v.navigationDelegate = d

v.loadFileURL(src, allowingReadAccessTo: src.deletingLastPathComponent())
app.run()
