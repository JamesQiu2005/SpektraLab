//  CropStage.swift — a picture laid on the screen through a crop, as one map.
//
//  The crop page (the operating system Photos' UX, 2026-10-20) keeps the crop level and still
//  and moves the picture under it: a pan moves the picture, a pinch zooms it,
//  the straighten dial turns it, Vertical and Horizontal re-project it, Rotate
//  turns the whole thing a quarter, Flip mirrors it, and when a corner is let
//  go the crop grows back to fill the room and the picture with it. All of
//  that is one map, from the corrected frame's pixels to the screen
//  (`StageMapping`):
//
//      screen = centre + scale · F · R(φ) · (p − pivot),   φ = 90°·turns − angle
//
//  with the pivot fixed at the frame's middle. It is the crop's own arithmetic
//  read the other way (`Geometry.sourcePoint(forOutput:)`: the flips are undone
//  first, then the turns, then the straighten), so a crop drawn through it is
//  level on the screen and exactly where the render will cut. Because the
//  pivot never moves, an animation of the map's numbers is a straight line
//  between two places for every point of the picture and the crop alike: the
//  crop and the picture cannot part while they glide.
//
//  The picture itself is drawn once, at the size it is shown, and put in
//  place by a projection (`StageEffect`): the map above after the frame's
//  perspective (`Keystone`), a 3×3 matrix the GPU applies. Nothing is
//  rendered for a pan, a pinch, a dial or a glide — the render follows Done.
//
//  The same map draws the finished picture through Edit's crop everywhere
//  else (`GeometryPicture`): the develop page's canvas, the library.

import SwiftUI
import simd

/// The map's numbers, as one vector SwiftUI can interpolate.
struct StageVector: VectorArithmetic, Equatable {
    var v = SIMD8<Double>(repeating: 0)

    static var zero: StageVector { StageVector() }
    static func + (a: StageVector, b: StageVector) -> StageVector { StageVector(v: a.v + b.v) }
    static func - (a: StageVector, b: StageVector) -> StageVector { StageVector(v: a.v - b.v) }
    mutating func scale(by rhs: Double) { v *= rhs }
    var magnitudeSquared: Double { (v * v).sum() }
}

/// Corrected-frame pixels → the screen (see the head of the file).
struct StageMapping: Equatable {
    var centre: CGPoint = .zero
    var scale: CGFloat = 1
    /// φ, degrees clockwise: the quarter turns (counted on, for a glide that
    /// takes the short way) less the straighten.
    var degrees: Double = 0
    var pivot: CGPoint = .zero
    var flipX: CGFloat = 1
    var flipY: CGFloat = 1

    var vector: StageVector {
        get { StageVector(v: SIMD8(centre.x, centre.y, scale, degrees, pivot.x, pivot.y, flipX, flipY)) }
        set {
            let v = newValue.v
            centre = CGPoint(x: v[0], y: v[1]); scale = v[2]; degrees = v[3]
            pivot = CGPoint(x: v[4], y: v[5]); flipX = v[6]; flipY = v[7]
        }
    }

    init() {}
    init(_ vector: StageVector) { self.vector = vector }

    /// Corrected pixels → screen points.
    var affine: CGAffineTransform {
        CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: scale * flipX, y: scale * flipY))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }

    func screen(_ corrected: CGPoint) -> CGPoint { corrected.applying(affine) }
    func corrected(_ screen: CGPoint) -> CGPoint { screen.applying(affine.inverted()) }

    /// The map at rest for a crop: the crop fitted in `room`, centred.
    /// `turns` is the quarter turns as the page counts them (not reduced),
    /// so a glide from one rest to the next turns the short way.
    static func rest(_ g: Geometry, imageSize: CGSize, room: CGRect, turns: Int) -> StageMapping {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        var cw = g.crop.width * w, ch = g.crop.height * h
        if ((g.quarterTurns % 4) + 4) % 2 == 1 { swap(&cw, &ch) }
        var m = StageMapping()
        m.pivot = CGPoint(x: w / 2, y: h / 2)
        m.scale = max(min(room.width / max(cw, 1), room.height / max(ch, 1)), 0.0001)
        m.degrees = 90 * Double(turns) - g.angle
        m.flipX = g.flipH ? -1 : 1
        m.flipY = g.flipV ? -1 : 1
        // The crop's centre on the room's.
        m.centre = .zero
        let c = m.screen(CGPoint(x: g.centre.x * w, y: g.centre.y * h))
        m.centre = CGPoint(x: room.midX - c.x, y: room.midY - c.y)
        return m
    }

    /// The map at rest for the whole picture, as Capture One's crop has it (the Mac's crop page,
    /// the owner, 2026-11-05): the corrected frame — the picture as it develops, which is what the
    /// Mac's stage draws (`CropStageView`'s mask) — turned, straightened and flipped, fitted in
    /// `room` and centred, and the crop drawn wherever it is on it. It does not depend on the crop,
    /// so nothing of the picture is ever off the stage: `rest` fits the crop instead, and a crop of
    /// another shape than the room put the rest of the picture past the stage's edge.
    static func whole(_ g: Geometry, imageSize: CGSize, room: CGRect, turns: Int) -> StageMapping {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        var m = StageMapping()
        m.pivot = CGPoint(x: w / 2, y: h / 2)
        m.degrees = 90 * Double(turns) - g.angle
        m.flipX = g.flipH ? -1 : 1
        m.flipY = g.flipV ? -1 : 1
        let outline = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map(m.screen)
        let xs = outline.map(\.x), ys = outline.map(\.y)
        let lo = CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0), hi = CGPoint(x: xs.max() ?? 1, y: ys.max() ?? 1)
        m.scale = max(min(room.width / max(hi.x - lo.x, 1), room.height / max(hi.y - lo.y, 1)), 0.0001)
        // At scale 1 about the origin, the outline's box scales with the map: its middle on the room's.
        m.centre = CGPoint(x: room.midX - (lo.x + hi.x) / 2 * m.scale, y: room.midY - (lo.y + hi.y) / 2 * m.scale)
        return m
    }

    /// The crop's four corners on the screen, clockwise from its own top left.
    func corners(_ g: Geometry, imageSize: CGSize) -> [CGPoint] {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        return g.corners(in: imageSize).map { screen(CGPoint(x: $0.x * w, y: $0.y * h)) }
    }

    /// The crop on the screen, as the rectangle it is at rest.
    func box(_ g: Geometry, imageSize: CGSize) -> CGRect {
        let c = corners(g, imageSize: imageSize)
        let xs = c.map(\.x), ys = c.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The projection that puts a picture laid out at `viewSize` — the whole
    /// source, `imageSize` pixels — where this map and `keystone` put it.
    func projection(viewSize: CGSize, imageSize: CGSize, keystone: Keystone) -> ProjectionTransform {
        let sx = Double(imageSize.width / max(viewSize.width, 0.0001)), sy = Double(imageSize.height / max(viewSize.height, 0.0001))
        let toPixels = simd_double3x3(rows: [SIMD3(sx, 0, 0), SIMD3(0, sy, 0), SIMD3(0, 0, 1)])
        let a = affine
        let toScreen = simd_double3x3(rows: [SIMD3(Double(a.a), Double(a.c), Double(a.tx)),
                                             SIMD3(Double(a.b), Double(a.d), Double(a.ty)),
                                             SIMD3(0, 0, 1)])
        let h = toScreen * keystone.forward * toPixels
        // SwiftUI's matrix is for a row vector: the transpose.
        var p = ProjectionTransform()
        p.m11 = CGFloat(h[0][0]); p.m12 = CGFloat(h[0][1]); p.m13 = CGFloat(h[0][2])
        p.m21 = CGFloat(h[1][0]); p.m22 = CGFloat(h[1][1]); p.m23 = CGFloat(h[1][2])
        p.m31 = CGFloat(h[2][0]); p.m32 = CGFloat(h[2][1]); p.m33 = CGFloat(h[2][2])
        return p
    }
}

/// The picture put in place by a map, animated with it.
struct StageEffect: GeometryEffect {
    var mapping: StageMapping
    let imageSize: CGSize
    let keystone: Keystone

    var animatableData: StageVector {
        get { mapping.vector }
        set { mapping.vector = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        mapping.projection(viewSize: size, imageSize: imageSize, keystone: keystone)
    }
}

/// A picture drawn through a whole geometry — crop, straighten, turns, flips
/// and perspective — filling (or fitted in) the room it is given. Edit's crop
/// of the finished picture on every page that shows it, and a Develop crop
/// with a perspective where a picture is drawn through it on the CPU's side
/// (`CroppedPicture`). `content` is the whole picture, any view of its shape.
struct GeometryPicture<Content: View>: View {
    let geometry: Geometry
    /// The whole picture's size, in the units the geometry was made in.
    let imageSize: CGSize
    var contentMode: ContentMode = .fit
    @ViewBuilder let content: (_ pointSize: CGFloat) -> Content

    var body: some View {
        if geometry.isIdentity {
            content(0)
        } else {
            GeometryReader { geo in
                let out = geometry.outputSize(for: imageSize)
                let sx = geo.size.width / max(out.width, 1), sy = geo.size.height / max(out.height, 1)
                let s = contentMode == .fill ? max(sx, sy) : min(sx, sy)
                let room = CGRect(x: (geo.size.width - out.width * s) / 2, y: (geo.size.height - out.height * s) / 2,
                                  width: out.width * s, height: out.height * s)
                let mapping = StageMapping.rest(geometry, imageSize: imageSize, room: room, turns: geometry.quarterTurns)
                let view = CGSize(width: imageSize.width * s, height: imageSize.height * s)
                ZStack(alignment: .topLeading) {
                    content(max(view.width, view.height))
                        .frame(width: view.width, height: view.height)
                        .modifier(StageEffect(mapping: mapping, imageSize: imageSize, keystone: geometry.keystone(in: imageSize)))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipShape(Path(contentMode == .fill ? CGRect(origin: .zero, size: geo.size) : room))
            }
        }
    }
}
