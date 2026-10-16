// overscan_raster_apple.cpp -- the imprint raster on macOS: CoreGraphics,
// CoreText and vImage (overscan_raster.hpp).
//
// Moved out of overscan.cpp unchanged (2026-10-16) so the rest of the stage
// could compile everywhere; the Mac's coverage is the same bytes it was. Only
// the bounding box went to overscan.cpp (`group_bounds`), which the portable
// raster shares. build.sh globs src/pipeline/*.cpp, so the whole translation
// unit is guarded; overscan_raster_portable.cpp is its counterpart.
#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>

#include "overscan_raster.hpp"

namespace spk::imprint {

namespace {

CFAttributedStringRef make_text(const Op& op, CTFontRef font, double gain) {
    CFStringRef str = CFStringCreateWithCString(nullptr, op.text.c_str(), kCFStringEncodingUTF8);
    CGFloat white[] = {CGFloat(std::clamp(gain, 0.0, 1.0)), 1.0};
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGColorRef col = CGColorCreate(gray, white);
    CFNumberRef kern = CFNumberCreate(nullptr, kCFNumberCGFloatType, &op.tracking_mm);
    const void* keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName, kCTKernAttributeName};
    const void* vals[] = {font, col, kern};
    CFDictionaryRef attrs = CFDictionaryCreate(nullptr, keys, vals, 3, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(nullptr, str, attrs);
    CFRelease(attrs); CFRelease(kern); CFRelease(col); CFRelease(gray); CFRelease(str);
    return as;
}

}  // namespace

// Rasterise one group into a canvas-aligned coverage bitmap (its bounding box).
bool rasterise(const OverscanLayout& L, const Group& g, std::vector<float>& cov, int& x0, int& y0,
               int& w, int& h, std::string& /*error: CoreGraphics draws every face*/) {
    if (!group_bounds(L, g, x0, y0, w, h)) return false;

    std::vector<uint8_t> px(size_t(w) * size_t(h), 0);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(px.data(), size_t(w), size_t(h), 8, size_t(w), gray,
                                             kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return false;
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, false);
    // User space = film millimetres, t downward: flip to y-down bitmap pixels,
    // shift to this box, scale to mm, then canvas <- film.
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextTranslateCTM(ctx, -x0, -y0);
    CGContextScaleCTM(ctx, 1.0 / L.px, 1.0 / L.px);
    CGContextTranslateCTM(ctx, L.cu, L.cv);
    {
        const double a = L.A[0], b = L.A[1], c = L.A[2], d = L.A[3], det = a * d - b * c;
        // (u, v) = Ainv (s, t): CG's (a, b, c, d) maps x' = a x + c y, y' = b x + d y.
        CGContextConcatCTM(ctx, CGAffineTransformMake(d / det, -c / det, -b / det, a / det, 0, 0));
    }
    CGContextTranslateCTM(ctx, -L.cs, -L.ct);

    for (const Op& op : g.ops) {
        CGContextSetGrayFillColor(ctx, std::clamp(op.gain, 0.0, 1.0), 1.0);
        if (op.kind == Op::Poly) {
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, op.pts[0], op.pts[1]);
            for (size_t k = 2; k + 1 < op.pts.size(); k += 2) CGContextAddLineToPoint(ctx, op.pts[k], op.pts[k + 1]);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
            continue;
        }
        if (op.kind == Op::Circle) {
            const double r = op.size_mm;
            CGContextFillEllipseInRect(ctx, CGRectMake(op.pts[0] - r, op.pts[1] - r, 2 * r, 2 * r));
            continue;
        }
        CFStringRef fname = CFStringCreateWithCString(nullptr, op.font, kCFStringEncodingUTF8);
        CTFontRef font = CTFontCreateWithName(fname, op.size_mm, nullptr);
        CFRelease(fname);
        CFAttributedStringRef as = make_text(op, font, op.gain);
        CTLineRef line = CTLineCreateWithAttributedString(as);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, op.s, op.t);
        CGContextRotateCTM(ctx, op.rot_deg * M_PI / 180.0);
        if (op.scale_advances) CGContextScaleCTM(ctx, op.hscale, 1.0);
        CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(op.scale_advances ? 1.0 : op.hscale, -1.0));   // t is down; glyphs are up
        CGContextSetTextPosition(ctx, 0, 0);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line); CFRelease(as); CFRelease(font);
    }
    CGContextRelease(ctx);

    cov.resize(px.size());
    for (size_t i = 0; i < px.size(); ++i) cov[i] = float(px[i]) * (1.0f / 255.0f);
    // The projection's softness (RFC-031 §3.4): a small Gaussian on the mask.
    // Separable, edges extended, through vImage rather than two scalar loops:
    // the edge-print bands are full-width boxes (8,189 x 512 px at the full
    // tier of a 45 MP frame, sigma ~5 px), and the loops cost 95 ms each at
    // -O2 and ~1.2 s each in the Debug build's -O0 -- the whole of "Film Edge
    // is slow" (2026-10-03). vImage is optimised whatever the build setting.
    const double sigma = g.blur_mm / L.px;
    if (sigma > 0.3) {
        const int r = int(std::ceil(3.0 * sigma));
        std::vector<float> k(size_t(2 * r + 1));
        double sum = 0.0;
        for (int i = -r; i <= r; ++i) { k[size_t(i + r)] = float(std::exp(-0.5 * i * i / (sigma * sigma))); sum += k[size_t(i + r)]; }
        for (float& v : k) v = float(v / sum);
        std::vector<float> tmp(cov.size(), 0.0f);
        vImage_Buffer src{cov.data(), vImagePixelCount(h), vImagePixelCount(w), size_t(w) * sizeof(float)};
        vImage_Buffer dst{tmp.data(), vImagePixelCount(h), vImagePixelCount(w), size_t(w) * sizeof(float)};
        const uint32_t taps = uint32_t(2 * r + 1);
        if (vImageConvolve_PlanarF(&src, &dst, nullptr, 0, 0, k.data(), 1, taps, 0.0f, kvImageEdgeExtend)
                != kvImageNoError ||
            vImageConvolve_PlanarF(&dst, &src, nullptr, 0, 0, k.data(), taps, 1, 0.0f, kvImageEdgeExtend)
                != kvImageNoError)
            return false;
    }
    return true;
}

// A Helvetica-family string's advance in film mm, as CoreText lays it out.
double text_width(const char* font, double size_mm, const std::string& text, double tracking_mm, double hscale) {
    Op op;
    op.font = font; op.size_mm = size_mm; op.text = text; op.tracking_mm = tracking_mm;
    CFStringRef fname = CFStringCreateWithCString(nullptr, font, kCFStringEncodingUTF8);
    CTFontRef f = CTFontCreateWithName(fname, size_mm, nullptr);
    CFRelease(fname);
    CFAttributedStringRef as = make_text(op, f, 1.0);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    const double w = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
    CFRelease(line); CFRelease(as); CFRelease(f);
    return w * hscale;
}

}  // namespace spk::imprint
#endif  // __APPLE__
