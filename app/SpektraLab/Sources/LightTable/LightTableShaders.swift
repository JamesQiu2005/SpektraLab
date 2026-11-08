//  LightTableShaders.swift — the light table's shaders, as a string compiled at run time.
//
//  **The arithmetic is the website's** (`src/lightpad/table.js`' `PAD_FRAG`, `src/table-gl.js`'
//  `VERT`, `NOISE`, `STRIP_FRAG`, `SHADOW_FRAG`, `LOUPE_VERT`, `LOUPE_FRAG`, at `9875092`), GLSL
//  to Metal statement for statement. What differs, and why, none of it a change of look:
//
//  - **Colour.** The website draws in sRGB's encoded values and the browser shows them as sRGB.
//    The host's pictures are the library's, Display P3 (`DevelopedPicture`), and the table shows
//    them in P3 (the view's layer is Display P3), so a film's colours are not pressed into sRGB.
//    The pad's own colours — the desk, the rim, the warm diffuser, the ink, the shadow's brown, the
//    light through a cut edge — are the website's sRGB numbers carried into P3 (`p3`), so they look
//    as they do on the website; the near-neutral ones barely move. A film's multiply onto the light
//    is in P3's encoded values where the website's is in sRGB's: for a saturated colour the two
//    differ by the gamut's shape, not by any setting.
//  - **`pow(x, 2.)` is `x * x`.** GLSL leaves `pow` of a negative base undefined, and the rim's
//    crest and the loupe's ring square a value that goes below zero; GLSL compilers turn the
//    constant square into a product, which is what the drawing relies on. Metal's `pow` with safe
//    math gives NaN there, so the product is written out.
//  - **`mod` is GLSL's** (`gmod`: `x − y·floor(x / y)`), not Metal's `fmod`, which truncates.
//  - **Texture rows.** A Metal texture's first row is v = 0, as the website's uploads are (it flips
//    v in the strip shader for that); the loupe's target is rendered by Metal with its top row
//    first, where GL's is bottom first, so the loupe reads it with v turned (`toUv`).
//  - **Units in the loupe** are points, the website's CSS pixels: its rim and shadow widths
//    (0.4, 12, 16, 9) are in those units, at whatever scale the screen has.
//
//  Compiled once per device with safe math, as `Layer2Kernel` compiles its kernels: no `.metal`
//  file may be in the app's target (`gen_project.py`; AGENTS.md, engine trap 2).

import Foundation
import Metal

enum LightTableShaders {
    enum Failure: Error, CustomStringConvertible {
        case compile(String)
        var description: String { if case .compile(let s) = self { "the light table's shaders did not compile: \(s)" } else { "" } }
    }

    static func library(_ device: MTLDevice) throws -> MTLLibrary {
        let options = MTLCompileOptions()
        if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        do { return try device.makeLibrary(source: source, options: options) } catch { throw Failure.compile("\(error)") }
    }

    /// The number of films the pad's arrays hold (`LightTable.films`).
    static let films = LightTable.films

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ---------------------------------------------------------------- shared
    // A quad on the table: centre (x, y) and its turn's cosine and sine; its size, mm; the camera:
    // the table point in the middle of the target and mm to clip space.
    struct Quad { float4 place; float4 scale; float4 camera; };
    struct VOut { float4 position [[position]]; float2 uv; float2 world; };

    // VERT: the quad's uv runs as three.js' PlaneGeometry has it, (0, 0) bottom left, v up.
    vertex VOut lt_vertex(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {
      float2 corner = float2((vid & 1) ? .5 : -.5, (vid & 2) ? .5 : -.5);
      float2 l = corner * q.scale.xy;
      float2 w = q.place.xy + float2(l.x * q.place.z - l.y * q.place.w, l.x * q.place.w + l.y * q.place.z);
      VOut o;
      o.position = float4((w - q.camera.xy) * q.camera.zw, 0., 1.);
      o.uv = corner + .5;
      o.world = w;
      return o;
    }

    // NOISE
    float hash(float2 p) { float3 q = fract(float3(p.xyx) * .1031); q += dot(q, q.yzx + 33.33); return fract((q.x + q.y) * q.z); }
    float vnoise(float2 p) {
      float2 i = floor(p), f = fract(p); f = f * f * (3. - 2. * f);
      return mix(mix(hash(i), hash(i + float2(1., 0.)), f.x), mix(hash(i + float2(0., 1.)), hash(i + float2(1., 1.)), f.x), f.y);
    }
    float gmod(float x, float y) { return x - y * floor(x / y); }

    // The website's sRGB numbers as Display P3 values: decoded, carried across, encoded again.
    float3 lin(float3 c) { return select(pow((c + .055) / 1.055, 2.4), c / 12.92, c <= .04045); }
    float3 enc(float3 c) { c = max(c, 0.); return select(1.055 * pow(c, 1. / 2.4) - .055, c * 12.92, c <= .0031308); }
    float3 p3(float3 srgb) {
      float3 l = lin(srgb);
      float3 p = float3(dot(l, float3(.8224621, .1775380, 0.)), dot(l, float3(.0331941, .9668058, 0.)), dot(l, float3(.0170827, .0723974, .9105199)));
      return enc(p);
    }

    // ---------------------------------------------------------------- the pad (PAD_FRAG)
    struct Pad { float4 halfSize; float4 frame; float4 box[\(films)]; float4 turn[\(films)]; float4 count; float4 look; };

    float box(float2 p, float2 b, float r) { float2 q = abs(p) - b + r; return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r; }
    float2 boxNormal(float2 p, float2 b, float r) {
      float2 q = abs(p) - b + r;
      float2 g = (q.x > 0. || q.y > 0.) ? normalize(max(q, 0.) + 1e-5) : (q.x > q.y ? float2(1., 0.) : float2(0., 1.));
      return g * sign(p + 1e-5);
    }

    // An export's shadow (`look`): a rectangle of half size b blurred by a Gaussian of `sigma`, at p
    // from its centre -- the product of two edges' error functions (Abramowitz and Stegun 7.1.27).
    float2 erf2(float2 x) { float2 s = sign(x), a = abs(x); x = 1. + (.278393 + (.230389 + .078108 * (a * a)) * a) * a; x *= x; return s - s / (x * x); }
    float boxShadow(float2 p, float2 b, float sigma) {
      float2 t = .5 * (erf2((p + b) / (sigma * 1.4142136)) - erf2((p - b) / (sigma * 1.4142136)));
      return t.x * t.y;
    }

    // One edge's scale: t mm along the edge from the corner, d mm in from it.
    float ticks(float t, float d, float len) {
      float n = floor(t + .5);
      if (n < 1. || n > len - .5 || d < 0.) return 0.;
      float cm = 1. - step(.5, gmod(n, 10.)), h5 = 1. - step(.5, gmod(n, 5.));
      float l = mix(mix(1.8, 2.8, h5), 4.2, cm);
      float hw = mix(.075, .1, cm);
      float fw = max(fwidth(t), 1e-4), fd = max(fwidth(d), 1e-4);
      return clamp((hw - abs(t - n)) / fw + .5, 0., 1.) * clamp((l - d) / fd + .5, 0., 1.);
    }

    constant float2 CELL = float2(5.7, 3.8);
    float figures(float2 p, float n, texture2d<float> tex, sampler s) {
      if (p.x < 0. || p.y < 0. || p.x > CELL.x || p.y > CELL.y) return 0.;
      float2 c = p / CELL, k = float2(1. / 6., 1. / 5.);
      float2 uv = (float2(gmod(n - 1., 6.), floor((n - 1.) / 6.)) + c) * k;
      return tex.sample(s, uv, gradient2d(dfdx(c) * k, dfdy(c) * k)).r;
    }

    fragment float4 lt_pad(VOut in [[stage_in]], constant Pad &u [[buffer(0)]],
                           texture2d<float> figuresTex [[texture(0)]], sampler s [[sampler(0)]]) {
      float2 p = in.world;
      float2 uHalf = u.halfSize.xy;
      float3 uFrame = u.frame.xyz;
      float dIn = box(p, uHalf, uFrame.y);
      float dOut = box(p, uHalf + uFrame.x, uFrame.z);
      float px = max(fwidth(dOut), 1e-4);

      // the desk
      float t = clamp((p.y + uHalf.y + 40.) / (2. * uHalf.y + 80.), 0., 1.);
      float3 col = mix(float3(.918, .918, .925), float3(.945, .945, .952), t);
      float dS = box(p - float2(0., -2.4), uHalf + uFrame.x, uFrame.z);
      col *= 1. - .13 * exp(-max(dS, 0.) / 7.) - .14 * exp(-max(dOut, 0.) / .45);
      // the dark desk (the page's, `halfSize.z`): the app's black, the lamp's warm light spilling
      // onto it round the frame and falling away within a few millimetres
      float3 spill = float3(1., .965, .9) * (.1 * exp(-max(dOut, 0.) / 5.) + .035 * exp(-max(dOut, 0.) / 18.));
      col = mix(col, spill, u.halfSize.z);

      // the frame
      float uu = clamp(-dOut / uFrame.x, 0., 1.);
      float2 n = boxNormal(p, uHalf + uFrame.x, uFrame.z);
      float facing = dot(n, float2(-.26, .966));
      float shade = .875 + .03 * facing;
      shade -= .13 * (1. - smoothstep(0., .18, uu)) * (.75 - .25 * facing);
      float crest = (uu - .22) / .07;
      shade += .09 * exp(-(crest * crest)) * (.55 + .45 * facing);
      float2 tg = float2(-n.y, n.x);
      shade += (vnoise(float2(dot(p, tg) * .3, dot(p, n) * 26.)) - .5) * .025;
      shade -= .2 * smoothstep(.8, .95, uu) * (1. - smoothstep(.95, 1., uu));
      float3 rim = float3(shade) * float3(.985, .99, 1.);
      rim = mix(rim, float3(1., .985, .96), .5 * smoothstep(.93, 1., uu));

      // the diffuser
      float inset = max(-dIn, 0.);
      float fall = smoothstep(0., 30., inset);
      float lum = mix(.95, 1., pow(fall, .7)) * (1. - .05 * exp(-inset / .5));
      float3 lit = mix(float3(.995, .975, .945), float3(1., .997, .99), fall) * lum;
      lit += (vnoise(p * 4.) - .5) * .014 + (hash(in.position.xy) - .5) * .006;

      // the scale, from the top left corner, left out under every film
      float a = p.x + uHalf.x, b = uHalf.y - p.y;
      float ink = max(ticks(a, b, 2. * uHalf.x), ticks(b, a, 2. * uHalf.y));
      float kt = floor(a / 10. + .5), kl = floor(b / 10. + .5);
      if (kt >= 1. && kt * 10. < 2. * uHalf.x - 2.) ink = max(ink, figures(float2(a - kt * 10. + .5 * CELL.x, b - 4.35), kt, figuresTex, s));
      if (kl >= 1. && kl * 10. < 2. * uHalf.y - 2.) ink = max(ink, figures(float2(a - 3.6, b - kl * 10. + .5 * CELL.y), kl, figuresTex, s));
      int count = int(u.count.x);
      if (ink > 0.) for (int i = 0; i < \(films); i++) {
        if (i >= count) break;
        float4 f = u.box[i], r = u.turn[i];
        float2 d = p - f.xy;
        float2 q = abs(float2(d.x * r.x + d.y * r.y, -d.x * r.y + d.y * r.x)) - f.zw;
        ink *= 1. - r.z * (1. - smoothstep(-.5 * px, .5 * px, max(q.x, q.y)));
      }
      lit = mix(lit, lit * float3(.33, .335, .35), .82 * ink);

      col = mix(col, rim, 1. - smoothstep(-px, px, dOut));
      col = mix(col, lit, 1. - smoothstep(-px, px, dIn));
      // An export's look (`LightTableExport`): 2 the sheet alone, flat white paper with its scale;
      // 1 the table alone on nothing, under a window's shadow (premultiplied, black, falling to 0).
      if (u.look.x > 1.5) return float4(p3(mix(float3(1.), float3(.33, .335, .35), .82 * ink)), 1.);
      if (u.look.x > .5) {
        float cov = 1. - smoothstep(-px, px, dOut);
        float3 table = mix(rim, lit, 1. - smoothstep(-px, px, dIn));
        float2 e = uHalf + uFrame.x;
        float sh = u.look.w * boxShadow(p + float2(0., u.look.z), e, u.look.y) + .22 * boxShadow(p + float2(0., .3), e, .6);
        sh = clamp(sh, 0., 1.) * (1. - cov);
        return float4(p3(table) * cov, cov + sh);
      }
      return float4(p3(col), 1.);
    }

    // ---------------------------------------------------------------- a film (STRIP_FRAG)
    // size and quad, mm; the lamp's reflection (table mm) and its strength, and the mip bias;
    // presence.
    struct Strip { float4 sizeQuad; float4 sheen; float4 misc; };

    fragment float4 lt_strip(VOut in [[stage_in]], constant Strip &u [[buffer(0)]],
                             texture2d<float> map [[texture(0)]], sampler s [[sampler(0)]]) {
      float2 uSize = u.sizeQuad.xy, uQuad = u.sizeQuad.zw;
      float2 l = (in.uv - .5) * uQuad;
      float2 q = abs(l) - .5 * uSize;
      float d = max(q.x, q.y);
      float px = max(fwidth(d), 1e-4);
      float cov = 1. - smoothstep(-.5 * px, .5 * px, d);
      float2 uv = clamp(l / uSize + .5, 0., 1.);
      uv.y = 1. - uv.y; // the picture's top row first
      float3 tr = map.sample(s, uv, bias(u.sheen.w)).rgb;
      float2 sv = in.world - u.sheen.xy;
      float broad = exp(-dot(sv, sv) / 2400.);
      float2 r = float2x2(float2(.906, .423), float2(-.423, .906)) * sv;
      float streak = exp(-(r.y * r.y) / 36. - (r.x * r.x) / 4200.);
      float gloss = u.sheen.z * (.5 * broad + .7 * streak) + .01;
      float3 col = tr + gloss * (1. - .8 * tr);
      col = mix(col, p3(float3(1., .99, .97)), .22 * exp(min(d, 0.) / .22));
      return float4(col * cov, cov) * u.misc.x;
    }

    // ---------------------------------------------------------------- its shadow (SHADOW_FRAG)
    struct Shadow { float4 sizeQuad; float4 shadow; };

    float sdBox(float2 p, float2 b) { float2 q = abs(p) - b; return length(max(q, 0.)) + min(max(q.x, q.y), 0.); }

    fragment float4 lt_shadow(VOut in [[stage_in]], constant Shadow &u [[buffer(0)]]) {
      float2 uSize = u.sizeQuad.xy, uQuad = u.sizeQuad.zw;
      float3 uShadow = u.shadow.xyz;
      float2 l = (in.uv - .5) * uQuad;
      float ds = sdBox(l - uShadow.xy, .5 * uSize - .5);
      float a = u.shadow.w * (1. - smoothstep(-.7 * uShadow.z, uShadow.z, ds));
      float dc = sdBox(l, .5 * uSize);
      a += .1 * exp(-max(dc, 0.) / .35);
      float px = max(fwidth(dc), 1e-4);
      a *= smoothstep(-.5 * px, .5 * px, dc);
      return float4(p3(float3(.11, .085, .06)) * a, a);
    }

    // ---------------------------------------------------------------- the loupe (LOUPE_VERT, LOUPE_FRAG)
    // at: the lens's centre on the screen and the quad's side, points; view: the target, points.
    struct LoupeQ { float4 at; float4 view; };
    // R, rim, pad, fade.
    struct Loupe { float4 lens; };
    struct LOut { float4 position [[position]]; float2 vP; };

    vertex LOut lt_loupe_vertex(uint vid [[vertex_id]], constant LoupeQ &q [[buffer(0)]]) {
      float2 corner = float2((vid & 1) ? .5 : -.5, (vid & 2) ? .5 : -.5);
      float2 vP = corner * q.at.z;               // y up, as the website's overlay camera has it
      float2 p = q.at.xy + float2(vP.x, -vP.y);  // the screen's points, y down
      LOut o;
      o.position = float4(p.x / q.view.x * 2. - 1., 1. - p.y / q.view.y * 2., 0., 1.);
      o.vP = vP;
      return o;
    }

    fragment float4 lt_loupe(LOut in [[stage_in]], constant Loupe &u [[buffer(0)]],
                             texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
      float uR = u.lens.x, uRim = u.lens.y, uPad = u.lens.z, uA = u.lens.w;
      float2 vP = in.vP;
      // the target's top row first: v turned against GL's
      #define toUv(nn) (float2((nn).x, -(nn).y) / uPad * .5 + .5)
      float d = length(vP);
      float fw = max(fwidth(d), 1e-3);
      float r = d / uR;
      float2 n = vP / uR;
      float2 dir = vP / max(d, 1e-3);
      float2 light = float2(-.5, .866);

      float2 b = n * (1. + .09 * r * r);
      float ca = .014 * r * r * r;
      float3 lens = float3(tex.sample(s, toUv(b * (1. + ca))).r, tex.sample(s, toUv(b)).g, tex.sample(s, toUv(b * (1. - ca))).b);
      lens *= 1. - .14 * smoothstep(.72, 1., r);
      lens += .1 * smoothstep(.6, .97, r) * smoothstep(.3, .95, dot(dir, light));
      lens += .025 * (1. - smoothstep(0., .8, length(n - light * .45)));

      float tr = clamp((d - uR) / uRim, 0., 1.);
      float3 rim = tex.sample(s, toUv(dir * (1.24 + .18 * tr))).rgb;
      float facing = dot(dir, light) * .5 + .5;
      rim = mix(rim, float3(1.), .5 + .3 * facing) * (.86 + .14 * facing);
      float ring = (tr - .3) / .16;
      rim += .3 * exp(-(ring * ring)) * smoothstep(.5, 1., facing);

      float3 col = mix(lens, rim, smoothstep(uR - fw, uR + fw, d));
      col *= 1. - .22 * (1. - smoothstep(0., 1.2 * fw + .4, abs(d - uR)));
      col *= 1. - .45 * (1. - smoothstep(0., 1.2 * fw + .4, abs(d - uR - uRim)));

      float disc = 1. - smoothstep(uR + uRim - fw, uR + uRim + fw, d);
      float sd = length(vP + float2(0., 9.)) - (uR + uRim);
      float shadow = .17 * (1. - smoothstep(-12., 16., sd));
      return float4(col * disc, disc + shadow * (1. - disc)) * uA;
      #undef toUv
    }
    """
}
