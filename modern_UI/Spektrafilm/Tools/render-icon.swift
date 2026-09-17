//  render-icon.swift — the app's icon as macOS draws it, to a PNG.
//
//      swiftc -O Tools/render-icon.swift -o /tmp/render-icon
//      /tmp/render-icon "$PWD/build/DerivedData/Build/Products/Debug/SpektraLab.app" \
//                       ../../screenshots/app-icon.png 1024
//
//  Why the built app and not `Spektrafilm/SpektraLab.icon`: the Icon Composer
//  document is layers, a shadow and a translucency value, not a picture. What
//  a person sees is `actool`'s composite of it — the shape mask, the material,
//  the specular edge — and that only exists after a build. Reading it back out
//  of the bundle also proves the icon reached the bundle, which is the half of
//  this that can silently fail: a name with no document behind it compiles to
//  an app with no icon and no error.
//
//  `NSWorkspace.icon(forFile:)` is deliberate too. It is the same call the
//  Finder and the Dock make, so the file this writes is what they show; the
//  `.icns` beside it in the bundle stops at 256 px, while the catalogue holds
//  renditions up to 2048. The size printed on stderr is the largest one there,
//  so a request above it is an upscale and says so.

import AppKit

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[3]), px > 0 else {
    FileHandle.standardError.write(Data("usage: render-icon <app> <out.png> <px>\n".utf8))
    exit(2)
}
// A path that does not exist is the failure this tool is most likely to have,
// and it fails *quietly*: `icon(forFile:)` answers a missing file with the
// generic blank-document icon, which is a 1024 px PNG of nothing that looks
// like a successful run. A relative path resolved against the wrong working
// directory is the way it happens. So: absolute, and it must be there.
let app = URL(fileURLWithPath: args[1]).standardizedFileURL
guard FileManager.default.fileExists(atPath: app.path) else {
    FileHandle.standardError.write(Data("no such bundle: \(app.path)\n".utf8))
    exit(1)
}
let icon = NSWorkspace.shared.icon(forFile: app.path)
let largest = icon.representations.map(\.pixelsWide).max() ?? 0
FileHandle.standardError.write(Data("largest rendition: \(largest) px\n".utf8))
if px > largest {
    FileHandle.standardError.write(Data("warning: \(px) px is an upscale of \(largest)\n".utf8))
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
          from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
