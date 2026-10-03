// overscan.cpp -- RFC-032 §26-§27 (this repo) and RFC-031: the film outside
// the frame, and the date back, as exposure on the negative.
//
// Why here and not in the app: a real overscan is the *same* film as the
// picture -- the gate's shadow, grain in the rebate, halation spilling past
// the frame, edge print and fog that develop like any exposure. So the canvas
// is built on the raw exposure (after metering and boost, before halation),
// and everything downstream runs over it unchanged. RFC-032 §26 records why a
// drawn border cannot pass for one.
//
// Randomness has three levels (§26.1), kept apart on purpose:
//   film data  -- fixed per stock and format: edge print text, its period,
//                 numbering, markers, DX. Deterministic.
//   camera     -- `camera_seed`: the machine. Gate corners and side wobble,
//                 gate-to-emulsion gap (penumbra), where the frame sits on the
//                 perforation grid, frame spacing, which spool side leaks.
//   frame      -- `frame_seed`: the film advance (过片) and the scan. Advance
//                 error, weave, scan rotation/offset, fog and leak realisation,
//                 and (on 120, which is not sprocket-locked) where the edge
//                 numbers land.
// Text is rasterised with CoreText/CoreGraphics -- the same C API on macOS and
// iOS -- so both apps get the same glyphs from the same code.
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "pipeline.hpp"
#include "spectral.hpp"
#include "timer.hpp"

namespace spk {

namespace {

// Indices into the kernel parameter block; `overscan.metal` mirrors them.
enum OsP : int {
    P_CW = 0, P_CH, P_PX, P_FW, P_FH,
    P_A00, P_A01, P_A10, P_A11, P_CS, P_CT, P_CU, P_CV,
    P_VERTICAL,
    P_GS0, P_GT0, P_GW, P_GH, P_CORNER, P_PENUMBRA,
    P_WOB_A = 20, P_WOB_PH = 32,
    P_FILM_W = 44, P_FOG_AMP, P_FOG_WIDTH, P_FOG_SEED, P_FOG_PERIOD,
    P_FOG_R, P_FOG_G, P_FOG_B,
    P_N_LEAKS = 52, P_LEAKS = 53,
    P_PERFORATED = 83, P_PERF_PITCH, P_PERF_W, P_PERF_H, P_PERF_EDGE, P_PERF_R, P_PERF_PHASE,
    P_HOLE_C = 90, P_HOLE_M, P_HOLE_Y,
    P_FLARE_AMP = 93, P_FLARE_WIDTH,
    P_GATE_R = 95, P_N_Q = 99, P_Q = 100,
    P_ROUGH_AMP = 180, P_ROUGH_PERIOD, P_ROUGH_SEED,
    P_HOLES_LIGHT = 183, P_LIGHT_R, P_LIGHT_G, P_LIGHT_B,
    P_PERF_SEED = 187, P_LIGHT_FALL, P_LIGHT_DIR,
    P_WALL_T = 190, P_WALL_VS, P_WALL_VT, P_WALL_PAR, P_BASE_R, P_BASE_G, P_BASE_B, P_WALL_GLOW, P_WALL_SCATTER,
    P_COUNT = 199
};
constexpr int kMaxLeaks = 6;
constexpr int kMaxQuads = 8;
constexpr double kMidGrey = 0.184;

// splitmix64 streams, one per (level, purpose), so adding a draw to one level
// never shifts another level's values.
struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed) {}
    uint64_t next() {
        s += 0x9E3779B97F4A7C15ull;
        uint64_t z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    double uni() { return double(next() >> 11) * (1.0 / 9007199254740992.0); }
    double uni(double a, double b) { return a + (b - a) * uni(); }
    double normal() {
        const double u1 = std::max(uni(), 1e-12), u2 = uni();
        return std::sqrt(-2.0 * std::log(u1)) * std::cos(2.0 * M_PI * u2);
    }
};
uint64_t stream(uint64_t seed, uint64_t level, uint64_t purpose) {
    return (seed * 0x9E3779B97F4A7C15ull) ^ (level << 40) ^ (purpose << 20) ^ 0xD1B54A32D192ED03ull;
}
enum Level : uint64_t { kFilm = 1, kCamera = 2, kFrame = 3 };

struct Format {
    const char* name;
    double film_w;          // across the film, mm
    double across;          // the gate's size across the film, mm
    double along;           // the gate's nominal size along the film, mm (the format's long edge when > across)
    bool perforated;
    const char* families;   // gate families its real cameras have (RFC-032 §29), for gate = auto
};
constexpr Format kFormats[] = {
    {"135",     35.0, 24.0, 36.0, true,  "square"},            // ISO 1007; 36 x 24 on 8 perforations
    {"135_half", 35.0, 24.0, 18.0, true, "square"},            // half frame: 18 x 24 on 4 perforations, portrait when held level
    {"120_645", 61.0, 56.0, 41.5, false, "eared rounded"},     // ISO 732 nominal width; Mamiya spec frame sizes
    {"120_6x6", 61.0, 56.0, 56.0, false, "kicked square"},
    {"120_6x7", 61.0, 56.0, 69.5, false, "square"},
    {"120_6x8", 61.0, 56.0, 76.0, false, "shouldered"},
    {"120_6x9", 61.0, 56.0, 84.0, false, "square"},
};
constexpr const char* kFormatNames = "135, 135_half, 120_645, 120_6x6, 120_6x7, 120_6x8, 120_6x9";
constexpr const char* kGateFamilies[] = {"square", "rounded", "eared", "shouldered", "kicked"};
const Format* find_format(const std::string& name) {
    for (const Format& f : kFormats) if (name == f.name) return &f;
    return nullptr;
}

// --- imprint drawing ops, in film millimetres (s along, t across, t down) ----
struct Op {
    enum Kind { Text, Poly, Circle } kind = Text;   // Circle: pts = {s, t}, radius = size_mm
    std::string text;
    const char* font = "HelveticaNeue-Bold";
    double size_mm = 1.0;       // font size (em), mm
    double s = 0, t = 0;        // baseline start (Text) in film mm
    double rot_deg = 0;         // about (s, t)
    double tracking_mm = 0;
    double skew = 0;            // horizontal shear (seven-segment slant)
    std::vector<double> pts;    // Poly: s0,t0,s1,t1,... in film mm
    double gain = 1.0;          // this mark's share of the group's exposure (printing variance)
};

struct Group {
    std::vector<Op> ops;
    double exposure[3] = {0, 0, 0};   // raw exposure at full coverage, per layer
    double blur_mm = 0.0;
};

// Seven segments, a b c d e f g, as the data back's LCD: glyph units, digit
// height 1, baseline at 0 (y up), no slant (the op carries the shear).
void seven_seg_polys(const std::string& text, double h, double s0, double t0, Op proto,
                     std::vector<Op>& out) {
    static const char* kSeg[10] = {"abcdef", "bc", "abged", "abgcd", "fgbc",
                                   "afgcd", "afgedc", "abc", "abcdefg", "abcdfg"};
    const double w = 0.52 * h, th = 0.14 * h;
    double x = 0.0;
    auto rect = [&](double x0, double y0, double ww, double hh) {
        Op op = proto;
        op.kind = Op::Poly;
        // (x, y) in glyph space with y up from the baseline; t grows downward.
        const double xs[4] = {x0, x0 + ww, x0 + ww, x0};
        const double ys[4] = {y0, y0, y0 + hh, y0 + hh};
        for (int k = 0; k < 4; ++k) {
            const double gx = xs[k] + proto.skew * ys[k];
            op.pts.push_back(s0 + gx);
            op.pts.push_back(t0 - ys[k]);
        }
        out.push_back(op);
    };
    for (char ch : text) {
        if (ch == ' ') { x += 0.45 * h; continue; }
        if (ch == '\'') { rect(x, 0.72 * h, th, 0.28 * h); x += 0.35 * h; continue; }
        if (ch < '0' || ch > '9') { x += 0.45 * h; continue; }
        const char* segs = kSeg[ch - '0'];
        const double gap = 0.6 * th;
        for (const char* p = segs; *p; ++p) {
            switch (*p) {
                case 'a': rect(x + gap, h - th, w - 2 * gap, th); break;
                case 'g': rect(x + gap, 0.5 * h - 0.5 * th, w - 2 * gap, th); break;
                case 'd': rect(x + gap, 0.0, w - 2 * gap, th); break;
                case 'f': rect(x, 0.5 * h + 0.3 * th, th, 0.5 * h - 0.9 * th); break;
                case 'b': rect(x + w - th, 0.5 * h + 0.3 * th, th, 0.5 * h - 0.9 * th); break;
                case 'e': rect(x, 0.6 * th, th, 0.5 * h - 0.9 * th); break;
                case 'c': rect(x + w - th, 0.6 * th, th, 0.5 * h - 0.9 * th); break;
            }
        }
        x += w + 0.28 * h;
    }
}

double seven_seg_width(const std::string& text, double h) {
    double x = 0.0;
    for (char ch : text) {
        if (ch == ' ') x += 0.45 * h;
        else if (ch == '\'') x += 0.35 * h;
        else x += 0.52 * h + 0.28 * h;
    }
    return std::max(0.0, x - 0.28 * h);
}

// A light's per-layer exposure weights through this film: sum(L * T * S_c) /
// sum(L_ref * S_c), then normalised so the largest layer is 1. `rear` zeroes
// the blue-sensitive layer (the yellow filter stops blue from the base side;
// RFC-031 §3.2). `guide` is RFC-031's orange light guide (absorbs 420-570 nm).
void light_weights(const Colour& colour, const Blob& blob, const Vec& sens, const std::string& ref,
                   double kelvin, bool guide, const double t_layer[3], double out[3]) {
    Vec L, Lref;
    std::string err;
    const auto& wl = colour.wavelengths();
    char name[32];
    std::snprintf(name, sizeof name, "BB%.0f", kelvin);
    if (!standard_illuminant(colour, blob, name, L, err) || !standard_illuminant(colour, blob, ref, Lref, err)) {
        out[0] = 1.0; out[1] = 0.5; out[2] = 0.0;   // never reached with shipped resources
        return;
    }
    double num[3] = {0, 0, 0}, den[3] = {0, 0, 0};
    for (size_t i = 0; i < wl.size(); ++i) {
        double f = 1.0;
        if (guide && wl[i] >= 420.0 && wl[i] <= 600.0) f = 1.0 - 0.95 * std::exp(-std::pow((wl[i] - 525.0) / 35.0, 2));
        for (int c = 0; c < 3; ++c) {
            const double s = sens[3 * i + size_t(c)];
            if (!std::isfinite(s)) continue;
            num[c] += L[i] * f * s;
            den[c] += Lref[i] * s;
        }
    }
    // The film's layers are (R, G, B)-sensitive in channel order 0, 1, 2.
    double m = 0.0;
    for (int c = 0; c < 3; ++c) {
        out[c] = den[c] > 0 ? t_layer[c] * num[c] / den[c] : 0.0;
        m = std::max(m, out[c]);
    }
    for (int c = 0; c < 3; ++c) out[c] = m > 0 ? out[c] / m : 0.0;
}


// --- the gate's shape (RFC-032 §29) ------------------------------------------
// Each family is what the owner's reference scans show, measured on them
// (research/overscan/小红书找的参考, RFC-032 §29.1). Sides: t- and t+ run
// along the film edges, s- and s+ face the gaps between frames. Every number
// is a range the camera seed draws from: one body's gate is fixed, two bodies
// of one model differ.
void gate_shape(OverscanLayout& L, const std::string& family, bool perforated, Rng& rc) {
    // 6x8 back (measured on the owner's Mamiya 6x8 scan, 11.95 px/mm): the
    // gate is not centred on the film. Its ears reach to 1.17-1.34 mm from
    // the edge the stock name is printed on, and the middle of that side sits
    // back ~1.5 mm, at ~2.7 mm, so the edge print runs in the recess between
    // the ears and the ears' tops reach into its band. The other side keeps
    // ~4 mm of rebate.
    if (family == "shouldered") L.gate_t0 = rc.uni(1.10, 1.35) + (L.gate_t0 - 0.5 * (L.film_w - L.gate_across));
    const double s0 = L.gate_s0, t0 = L.gate_t0, GW = L.gate_along, GH = L.gate_across;
    auto quad = [&](std::initializer_list<double> pts, double round, double sign) {
        if (int(L.quads.size()) >= kMaxQuads) return;
        OverscanLayout::Quad q;
        int k = 0;
        for (double v : pts) q.pts[k++] = v;
        if (k == 6) { q.pts[6] = q.pts[4]; q.pts[7] = q.pts[5]; }   // a triangle (k == 4: an ellipse's cs, ct, rs, rt)
        q.round = round; q.sign = sign;
        L.quads.push_back(q);
    };
    // A cut along a film-edge side, between two ears at the corners: the side
    // stands `depth` proud of the opening. Its ends leave the gate's edge at
    // `ear_a` / `ear_b` mm from the corners and reach full depth `slope` mm
    // further in; `round` softens the inner bend. The slanted edges are
    // carried 1 mm past the gate's edge so the cut has no seam there.
    auto side_cut = [&](bool top, double ear_a, double ear_b, double depth, double slope, double round) {
        const double te = top ? t0 : t0 + GH, out = top ? -1.0 : 1.0;
        const double d_in = depth - round, ext = 1.0;
        const double k = slope / std::max(depth, 1e-3);         // mm along per mm across
        const double sa_in = s0 + ear_a + slope - round, sb_in = s0 + GW - ear_b - slope + round;
        const double sa_out = s0 + ear_a - k * ext + round, sb_out = s0 + GW - ear_b + k * ext - round;
        quad({sa_out, te + out * ext, sb_out, te + out * ext, sb_in, te - out * d_in, sa_in, te - out * d_in},
             round, -1.0);
    };
    // A band below an existing cut, `d0`..`d1` deep, whose ends slant from
    // (ear + a0) at d0 to (ear + a1) at d1: the second, shallower leg of a step.
    auto band_cut = [&](bool top, double ear_a, double ear_b, double d0, double d1, double a0, double a1) {
        const double te = top ? t0 : t0 + GH, out = top ? -1.0 : 1.0;
        quad({s0 + ear_a + a0, te - out * d0, s0 + GW - ear_b - a0, te - out * d0,
              s0 + GW - ear_b - a1, te - out * d1, s0 + ear_a + a1, te - out * d1}, 0.02, -1.0);
    };
    auto radii = [&](double lo, double hi) { for (double& r : L.gate_r) r = rc.uni(lo, hi); };

    L.gate_family = family;
    if (family == "rounded") {
        // 645 rangefinder (RF645): true radii, ~0.5 mm, a little different at each corner.
        const double r = rc.uni(0.42, 0.62);
        for (double& ri : L.gate_r) ri = std::max(0.2, r + rc.uni(-0.08, 0.08));
    } else if (family == "eared") {
        // 645 SLR (645N): both film-edge sides stand ~0.5 mm into the opening
        // between thin ears at the corners, joined by a long concave sweep.
        radii(0.02, 0.08);
        // Measured on the 645N reference: the side sits ~0.55 mm in, and its
        // ends sweep out to sharp tips at the corners over ~1.5-2 mm. The
        // sweep is a circular arc through the tip, tangent to the side at full
        // depth: radius R = (L^2 + depth^2) / (2 depth), centred outside the gate.
        for (bool top : {true, false}) {
            const double te = top ? t0 : t0 + GH, out = top ? -1.0 : 1.0;
            const double depth = rc.uni(0.48, 0.65);
            const double ea = rc.uni(0.0, 0.05), eb = rc.uni(0.0, 0.05);
            const double la = rc.uni(1.5, 2.2), lb = rc.uni(1.5, 2.2);
            quad({s0 + ea + la, te + out * 1.0, s0 + GW - eb - lb, te + out * 1.0,
                  s0 + GW - eb - lb, te - out * depth, s0 + ea + la, te - out * depth}, 0.0, -1.0);
            const double Ra = (la * la + depth * depth) / (2.0 * depth), Rb = (lb * lb + depth * depth) / (2.0 * depth);
            quad({s0 + ea + la, te + out * (Ra - depth), Ra, Ra}, 0.0, -2.0);
            quad({s0 + GW - eb - lb, te + out * (Rb - depth), Rb, Rb}, 0.0, -2.0);
        }
    } else if (family == "shouldered") {
        // The recess is a cut along the t- side between the ears: steep where
        // it leaves an ear (~0.35 of the depth in ~0.4 mm), then a long
        // shallow leg (the rest over ~2.2 mm). The other side is plain.
        radii(0.04, 0.12);
        // the ears' outer corners are worn round (~0.4 mm on the reference)
        L.gate_r[0] = rc.uni(0.28, 0.5);
        L.gate_r[1] = rc.uni(0.28, 0.5);
        const double ea = rc.uni(3.1, 3.8), eb = rc.uni(3.1, 3.8), depth = rc.uni(1.35, 1.6);
        const double steep = rc.uni(0.35, 0.45), knee = rc.uni(0.3, 0.4), leg = rc.uni(2.0, 2.6);
        side_cut(true, ea, eb, knee * depth, steep, 0.03);
        band_cut(true, ea, eb, knee * depth - 0.05, depth, steep - 0.03, steep + leg);
        L.top_recess = depth;
    } else if (family == "kicked") {
        // 6x6 insert: square corners; at two of them the film-edge side kicks
        // out ~0.2 mm over the last ~0.8 mm.
        radii(0.02, 0.10);
        const int first = int(rc.uni(0.0, 4.0)) % 4;
        for (int j = 0; j < 2; ++j) {
            const int c = (first + 2 * j + (rc.uni() < 0.3 ? 1 : 0)) % 4;
            const bool right = c == 1 || c == 2, bottom = c == 2 || c == 3;
            const double sc = right ? s0 + GW : s0, tc = bottom ? t0 + GH : t0;
            const double len = rc.uni(0.6, 1.0), kick = rc.uni(0.14, 0.26);
            const double dir = right ? -1.0 : 1.0, out = bottom ? 1.0 : -1.0;
            quad({sc + dir * len, tc - out * 0.05, sc, tc - out * 0.05, sc, tc + out * kick}, 0.01, 1.0);
        }
    } else {
        // square: 135 bodies, 6x7 and 6x9 rangefinders -- radii from a hair to ~0.3 mm.
        if (perforated) radii(0.10, 0.38); else radii(0.06, 0.32);
    }
    // Burrs and nicks: most gates have one or two, a tenth of a millimetre.
    const int nicks = int(rc.uni(0.0, 2.6));
    for (int k = 0; k < nicks; ++k) {
        const int side = int(rc.uni(0.0, 4.0)) % 4;
        const double sz = rc.uni(0.04, 0.12), pos = rc.uni(0.08, 0.92), sign = rc.uni() < 0.5 ? 1.0 : -1.0;
        double a0, b0, a1, b1, ax, bx;                  // base from (a0,b0) to (a1,b1), apex (ax, bx)
        if (side == 0 || side == 2) {
            const double te = side == 0 ? t0 : t0 + GH, out = (side == 0 ? -1.0 : 1.0) * sign;
            const double sc = s0 + pos * GW;
            a0 = sc - sz; b0 = te; a1 = sc + sz; b1 = te; ax = sc + rc.uni(-0.5, 0.5) * sz; bx = te + out * sz;
        } else {
            const double se = side == 3 ? s0 : s0 + GW, out = (side == 3 ? -1.0 : 1.0) * sign;
            const double tc = t0 + pos * GH;
            a0 = se; b0 = tc - sz; a1 = se; b1 = tc + sz; ax = se + out * sz; bx = tc + rc.uni(-0.5, 0.5) * sz;
        }
        quad({a0, b0, a1, b1, ax, bx}, 0.005, sign);
    }
    L.rough_amp = rc.uni(0.003, 0.009);
    L.rough_period = rc.uni(0.08, 0.20);
    L.rough_seed = uint32_t(rc.next() & 0xFFFFFFu);
}

}  // namespace

// ---------------------------------------------------------------------------
// Layout: every random choice, once per run, from the seeds.
// ---------------------------------------------------------------------------
bool Pipeline::overscan_wanted() const {
    return params_.film_render.overscan.active;
}

double Pipeline::overscan_gate_long_mm() const {
    const Format* f = find_format(params_.film_render.overscan.format);
    return f ? std::max(f->across, f->along) : params_.camera.film_format_mm;
}

void Pipeline::overscan_frame(uint32_t& frame_w, uint32_t& frame_h) const {
    const bool laid = overscan_wanted() && overscan_.valid;
    frame_w = laid ? overscan_.frame_w : 0;
    frame_h = laid ? overscan_.frame_h : 0;
}

bool Pipeline::set_overscan_frame(uint32_t frame_w, uint32_t frame_h, std::string& error) {
    if (!overscan_wanted() || frame_w == 0 || frame_h == 0) return true;
    if (overscan_.valid && overscan_.frame_w == frame_w && overscan_.frame_h == frame_h &&
        overscan_.px == pixel_size_um_ / 1000.0) return true;
    return overscan_layout(frame_w, frame_h, error);
}

bool Pipeline::overscan_layout(uint32_t frame_w, uint32_t frame_h, std::string& error) {
    const OverscanParams& o = params_.film_render.overscan;
    const Format* fmt = find_format(o.format);
    if (!fmt) { error = "overscan: unknown format '" + o.format + "' (" + kFormatNames + ")"; return false; }
    if (o.mode != "strip" && o.mode != "filed") { error = "overscan: unknown mode '" + o.mode + "' (strip, filed)"; return false; }
    bool family_ok = o.gate == "auto";
    for (const char* f : kGateFamilies) family_ok = family_ok || o.gate == f;
    if (!family_ok) { error = "overscan: unknown gate '" + o.gate + "' (auto, square, rounded, eared, shouldered, kicked)"; return false; }
    if (o.holes != "white" && o.holes != "black") { error = "overscan: unknown holes '" + o.holes + "' (white, black)"; return false; }
    if (params_.settings.striped) {
        error = "overscan: not supported by the striped executor yet (RFC-032 §27); render with striped = false";
        return false;
    }
    // The frame is the gate: its long edge is the format's, and its shape has
    // to be the gate's, either way up. Any other shape was laid out as if it
    // were, and the picture was cut by the film's width.
    {
        const double gate_long = std::max(fmt->along, fmt->across), gate_short = std::min(fmt->along, fmt->across);
        const double frame_long = std::max(frame_w, frame_h), frame_short = std::max(1u, std::min(frame_w, frame_h));
        const double ratio = (frame_long / frame_short) / (gate_long / gate_short);
        if (std::fabs(ratio - 1.0) > 0.05) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "overscan: a %u x %u frame is not the %s gate's shape (%g x %g); crop the picture to the gate first",
                          frame_w, frame_h, fmt->name, gate_long, gate_short);
            error = buf;
            return false;
        }
    }
    OverscanLayout& L = overscan_;
    L = OverscanLayout{};
    L.format = fmt->name;
    L.px = pixel_size_um_ / 1000.0;
    L.frame_w = frame_w;
    L.frame_h = frame_h;
    const double img_w = frame_w * L.px, img_h = frame_h * L.px;
    // The film runs along the image axis whose size is *not* the format's
    // across-the-film size: a portrait 135 frame, a landscape 645, a portrait
    // 6x7 all run vertically. Square frames run horizontally.
    L.vertical = std::fabs(img_w - fmt->across) < std::fabs(img_h - fmt->across) && std::fabs(img_w - img_h) > 1e-6;
    L.gate_along = L.vertical ? img_h : img_w;
    L.gate_across = L.vertical ? img_w : img_h;

    const uint64_t cam = uint64_t(uint32_t(o.camera_seed)), frm = uint64_t(uint32_t(o.frame_seed));
    Rng rc(stream(cam, kCamera, 1)), rf(stream(frm ^ (cam << 32), kFrame, 1));

    // --- film and gate ---------------------------------------------------
    L.film_w = fmt->film_w + (fmt->perforated ? 0.0 : rc.uni(-0.15, 0.15));
    const double t_off = rc.uni(-0.10, 0.10) + rf.normal() * 0.025;      // camera centring + weave
    L.gate_t0 = 0.5 * (L.film_w - L.gate_across) + t_off;
    L.gate_s0 = 0.0;
    for (int side = 0; side < 4; ++side)
        for (int k = 0; k < 3; ++k) {
            L.wob_a[side][k] = rc.normal() * 0.012 / double(k + 1);
            L.wob_ph[side][k] = rc.uni(0.0, 2.0 * M_PI);
        }
    // The gate sits a fraction of a millimetre in front of the emulsion; its
    // shadow's radius is gap / (2 N). EXIF gives N; f/5.6 when unknown.
    const double gate_gap = rc.uni(0.18, 0.40);
    const double N = o.f_number > 0.5 ? o.f_number : 5.6;
    L.penumbra = gate_gap / (2.0 * N);

    // --- the gate's shape: its own stream, so a new family never moves the
    // fog, the perforation phase or anything else this camera already draws.
    {
        Rng rg(stream(cam, kCamera, 2));
        std::string family = o.gate;
        if (family == "auto") {
            std::vector<std::string> fams;
            std::string cur;
            for (const char* c = fmt->families;; ++c) {
                if (*c == ' ' || *c == 0) { if (!cur.empty()) fams.push_back(cur); cur.clear(); if (!*c) break; }
                else cur += *c;
            }
            family = fams[size_t(rg.uni(0.0, double(fams.size()))) % fams.size()];
        }
        gate_shape(L, family, fmt->perforated, rg);
    }
    L.holes_light = o.holes == "white";

    // --- perforations (135): the frame's place on the grid is the camera's,
    // the advance error is the frame's; sprocket-locked, so it is small.
    L.perforated = fmt->perforated;
    if (L.perforated) {
        L.perf_pitch = 4.75; L.perf_w = 1.98; L.perf_h = 2.80; L.perf_edge = 2.00; L.perf_r = 0.50;
        L.perf_phase = std::fmod(rc.uni(0.0, 4.75) + rf.normal() * 0.08 + 47.5, 4.75) - 4.75;
    }

    // --- canvas ------------------------------------------------------------
    double margin_along, t_lo, t_hi;
    if (o.mode == "strip") {
        // 135 full frame advances 8 perforations (38 mm) for a 36 mm gate: ~1 mm
        // a side shows. Half frame advances 4 (19 mm) for 18 mm: ~0.5 mm a side.
        margin_along = fmt->perforated ? (fmt->along < 20.0 ? rc.uni(0.40, 0.50) : rc.uni(0.75, 0.95))
                                       : rc.uni(1.3, 2.1) + rf.uni(-0.25, 0.25);
        // The scan crops a hair inside the film's edges: enough that the
        // largest scan rotation (0.35 degrees, below) never shows a sliver of
        // light past the edge, and fixed per format so every frame's canvas
        // is the same size.
        const double inset = 0.5 * (L.gate_along + 2.0 * margin_along) * std::sin(0.35 * M_PI / 180.0) + 0.02;
        t_lo = inset; t_hi = L.film_w - inset;
    } else {
        margin_along = 0.9 + rf.uni(-0.1, 0.1);
        t_lo = L.gate_t0 - 1.1; t_hi = L.gate_t0 + L.gate_across + 1.1;
    }
    const uint32_t m_px = uint32_t(std::lround(margin_along / L.px));
    const uint32_t along_px = uint32_t(L.vertical ? frame_h : frame_w) + 2 * m_px;
    const uint32_t across_px = uint32_t(std::lround((t_hi - t_lo) / L.px));
    L.canvas_w = L.vertical ? across_px : along_px;
    L.canvas_h = L.vertical ? along_px : across_px;
    // Snap the across origin so the gate lands on pixel boundaries: with no
    // scan rotation the frame is copied, not resampled.
    const double t_origin = L.gate_t0 - std::round((L.gate_t0 - t_lo) / L.px) * L.px;
    const double s_origin = -double(m_px) * L.px;

    // --- scan registration (per frame): the whole film sits a hair off square.
    L.scan_rot = std::clamp(rf.normal() * 0.14, -0.35, 0.35) * M_PI / 180.0;
    const double ds = rf.normal() * 0.08, dt = rf.normal() * 0.06;
    const double cu = 0.5 * L.canvas_w * L.px, cv = 0.5 * L.canvas_h * L.px;
    const double c = std::cos(L.scan_rot), sn = std::sin(L.scan_rot);
    // canvas (u, v) -> film (s, t): the scan rotation R, then for a vertical film
    // a quarter turn (s = v, t = -u). A rotation, never a reflection -- a swap
    // of axes would mirror the edge print (it did, once: RFC-032 §27).
    if (!L.vertical) { L.A[0] = c; L.A[1] = -sn; L.A[2] = sn; L.A[3] = c; }
    else             { L.A[0] = sn; L.A[1] = c; L.A[2] = -c; L.A[3] = sn; }
    L.cu = cu; L.cv = cv;
    const double along_c = s_origin + 0.5 * along_px * L.px, across_c = t_origin + 0.5 * across_px * L.px;
    L.cs = along_c + ds;
    L.ct = across_c + dt;

    // --- fog and leaks: the spool's light at the long edges ------------------
    // Edge fog at the very edge, in EV over 18 % grey at fog = 1. A print only
    // leaves its black once the negative has mid-grey-like exposure, so the
    // brown, lifted edges of real overscans (IMG_6472/6474) need about this
    // much; measured by sweeping it (RFC-032 §27).
    const double fog_ev_edge = 0.3;
    L.fog_amp = o.fog > 0 ? o.fog * kMidGrey * std::pow(2.0, fog_ev_edge + rc.uni(-0.4, 0.4)) : 0.0;
    // 135 fogs from the cassette lips (light piping in the base); 120 from the
    // backing paper's edges, which reaches across the whole rebate band.
    L.fog_width = fmt->perforated ? rc.uni(0.8, 1.8) : rc.uni(1.2, 2.6);
    // Gate flare (the gate's bevel), camera-dependent.
    L.flare_amp = rc.uni(0.10, 0.35);
    L.flare_width = rc.uni(0.03, 0.08);
    L.fog_seed = uint32_t(rf.next() & 0xFFFFFFu);
    L.fog_period = rc.uni(5.0, 11.0);
    const int n_leaks = o.leaks > 0 ? std::min(kMaxLeaks, int(std::lround(1.0 + 2.0 * o.leaks))) : 0;
    const int leak_side = rc.uni() < 0.5 ? 0 : 1;
    const double s_lo = s_origin, s_hi = s_origin + along_px * L.px;
    for (int k = 0; k < n_leaks; ++k) {
        OverscanLayout::Leak lk;
        lk.s = rf.uni(s_lo, s_hi);
        lk.side = (rf.uni() < 0.8) ? leak_side : 1 - leak_side;
        lk.amp = o.leaks * kMidGrey * std::pow(2.0, rf.uni(0.5, 2.5));
        lk.sig_s = rf.uni(1.2, 4.0);
        lk.sig_t = rf.uni(0.4, 1.3);
        L.leaks.push_back(lk);
    }

    // --- light colours, through this film's own sensitivity ----------------
    const std::string& ref = params_.film.info.reference_illuminant;
    const double rear[3] = {1.0, 1.0, 0.0}, front[3] = {1.0, 1.0, 1.0}, edge_t[3] = {1.0, 1.0, 0.3};
    light_weights(*colour_, *blob_, film_sensitivity_, ref, 2800.0, false, front, L.fog_rgb);
    light_weights(*colour_, *blob_, film_sensitivity_, ref, 2700.0, true, rear, L.date_rgb);
    light_weights(*colour_, *blob_, film_sensitivity_, ref, 4500.0, false, edge_t, L.edge_rgb);

    // --- the hole: the cmy that cancels this film's base (least squares) ----
    {
        const Vec& chd = params_.film.data.channel_density;
        const Vec& base = params_.film.data.base_density;
        double AtA[3][3] = {{0}}, Atb[3] = {0};
        for (size_t l = 0; l < base.size(); ++l) {
            const double b = base[l];
            if (!std::isfinite(b)) continue;
            double a[3];
            bool ok = true;
            for (int k = 0; k < 3; ++k) { a[k] = chd[3 * l + size_t(k)]; ok = ok && std::isfinite(a[k]); }
            if (!ok) continue;
            for (int i = 0; i < 3; ++i) {
                Atb[i] += a[i] * (-b);
                for (int j = 0; j < 3; ++j) AtA[i][j] += a[i] * a[j];
            }
        }
        // Solve the 3x3 by Cramer; a degenerate system leaves the hole at zero dye.
        auto det3 = [](double m[3][3]) {
            return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
                   m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
        };
        const double D = det3(AtA);
        for (int k = 0; k < 3; ++k) {
            double M[3][3];
            std::memcpy(M, AtA, sizeof M);
            for (int i = 0; i < 3; ++i) M[i][k] = Atb[i];
            L.hole_cmy[k] = std::fabs(D) > 1e-12 ? det3(M) / D : 0.0;
        }
    }

    // --- the scan's view of the holes (RFC-032 §30.5, §31). White holes are
    // the picture's own white; black holes are a black backing. Either way a
    // hole is bounded by a wall of base: the punch shears the top of the base
    // clean and fractures the rest at 3-11 degrees (per hole, in the kernel),
    // and a scan seen a little off-axis shows the wall on the side away from
    // its axis -- a band of thinning base, brown through the orange mask.
    {
        Rng rl(stream(frm ^ (cam << 32), kFrame, 3));
        for (double& c : L.light_rgb) c = L.holes_light ? 1.0 : 0.0;
        L.light_fall = 0.0;
        L.light_dir = 0.0;
        L.perf_seed = uint32_t(rl.next() & 0xFFFFFFu);
        // The cut's shoulder (RFC-032 §31.5): which way the scan leans, how much
        // the black lifts at the edge (2-6 % linear for white holes, less for
        // black ones), and over what distance (0.02-0.035 mm).
        L.wall_t = 0.125;
        const double ang = rl.uni(0.0, 2.0 * M_PI);
        L.wall_tilt[0] = std::cos(ang);
        L.wall_tilt[1] = std::sin(ang);
        L.wall_parallax = 0.0;
        L.wall_glow = L.holes_light ? rl.uni(0.02, 0.06) : rl.uni(0.01, 0.03);
        L.wall_scatter = rl.uni(0.02, 0.035);
        // the base's own colour: its spectral density through the scan's light,
        // in the picture's white balance (the same adaptation as the print)
        const Profile& scanned = params_.io.scan_film ? params_.film : params_.print;
        const Vec& base = params_.film.data.base_density;
        Vec view;
        std::string err;
        const auto& cmfs = colour_->cmfs_1931_2deg();
        if (standard_illuminant(*colour_, *blob_, scanned.info.viewing_illuminant, view, err) && base.size() == view.size()) {
            double xyz[3] = {0, 0, 0}, vxyz[3] = {0, 0, 0}, vy = 0.0;
            for (size_t i = 0; i < view.size(); ++i) {
                const double tr = std::isfinite(base[i]) ? std::pow(10.0, -base[i]) : 1.0;
                for (int k = 0; k < 3; ++k) { xyz[k] += view[i] * tr * cmfs[3 * i + size_t(k)]; vxyz[k] += view[i] * cmfs[3 * i + size_t(k)]; }
                vy += view[i] * cmfs[3 * i + 1];
            }
            for (int k = 0; k < 3; ++k) { xyz[k] /= vy; vxyz[k] /= vy; }
            double vxy[2];
            Colour::XYZ_to_xy(vxyz, vxy);
            Mat3 m;
            if (colour_->matrix_XYZ_to_RGB(params_.io.output_color_space, vxy, "CAT02", m, err))
                for (int r = 0; r < 3; ++r)
                    L.base_rgb[r] = std::clamp(m.m[r][0] * xyz[0] + m.m[r][1] * xyz[1] + m.m[r][2] * xyz[2], 0.0, 1.0);
        }
    }

    L.valid = true;
    return true;
}

void Pipeline::overscan_params_block(std::vector<float>& P) const {
    const OverscanLayout& L = overscan_;
    P.assign(P_COUNT, 0.0f);
    P[P_CW] = float(L.canvas_w); P[P_CH] = float(L.canvas_h); P[P_PX] = float(L.px);
    P[P_FW] = float(L.frame_w); P[P_FH] = float(L.frame_h);
    P[P_A00] = float(L.A[0]); P[P_A01] = float(L.A[1]); P[P_A10] = float(L.A[2]); P[P_A11] = float(L.A[3]);
    P[P_CS] = float(L.cs); P[P_CT] = float(L.ct); P[P_CU] = float(L.cu); P[P_CV] = float(L.cv);
    P[P_VERTICAL] = L.vertical ? 1.0f : 0.0f;
    P[P_GS0] = float(L.gate_s0); P[P_GT0] = float(L.gate_t0);
    P[P_GW] = float(L.gate_along); P[P_GH] = float(L.gate_across);
    P[P_CORNER] = float(L.corner); P[P_PENUMBRA] = float(L.penumbra);
    for (int side = 0; side < 4; ++side)
        for (int k = 0; k < 3; ++k) {
            P[P_WOB_A + side * 3 + k] = float(L.wob_a[side][k]);
            P[P_WOB_PH + side * 3 + k] = float(L.wob_ph[side][k]);
        }
    P[P_FILM_W] = float(L.film_w); P[P_FOG_AMP] = float(L.fog_amp); P[P_FOG_WIDTH] = float(L.fog_width);
    P[P_FOG_SEED] = float(L.fog_seed); P[P_FOG_PERIOD] = float(L.fog_period);
    for (int c = 0; c < 3; ++c) P[P_FOG_R + c] = float(L.fog_rgb[c]);
    P[P_N_LEAKS] = float(std::min<size_t>(L.leaks.size(), kMaxLeaks));
    for (size_t k = 0; k < L.leaks.size() && k < size_t(kMaxLeaks); ++k) {
        const int b = P_LEAKS + 5 * int(k);
        P[b] = float(L.leaks[k].s); P[b + 1] = float(L.leaks[k].side); P[b + 2] = float(L.leaks[k].amp);
        P[b + 3] = float(L.leaks[k].sig_s); P[b + 4] = float(L.leaks[k].sig_t);
    }
    P[P_PERFORATED] = L.perforated ? 1.0f : 0.0f;
    P[P_PERF_PITCH] = float(L.perf_pitch); P[P_PERF_W] = float(L.perf_w); P[P_PERF_H] = float(L.perf_h);
    P[P_PERF_EDGE] = float(L.perf_edge); P[P_PERF_R] = float(L.perf_r); P[P_PERF_PHASE] = float(L.perf_phase);
    for (int c = 0; c < 3; ++c) P[P_HOLE_C + c] = float(L.hole_cmy[c]);
    P[P_FLARE_AMP] = float(L.flare_amp); P[P_FLARE_WIDTH] = float(L.flare_width);
    for (int k = 0; k < 4; ++k) P[P_GATE_R + k] = float(L.gate_r[k]);
    const size_t nq = std::min<size_t>(L.quads.size(), kMaxQuads);
    P[P_N_Q] = float(nq);
    for (size_t k = 0; k < nq; ++k) {
        float* q = P.data() + P_Q + 10 * k;
        for (int j = 0; j < 8; ++j) q[j] = float(L.quads[k].pts[j]);
        q[8] = float(L.quads[k].round);
        q[9] = float(L.quads[k].sign);
    }
    P[P_ROUGH_AMP] = float(L.rough_amp); P[P_ROUGH_PERIOD] = float(L.rough_period); P[P_ROUGH_SEED] = float(L.rough_seed);
    P[P_HOLES_LIGHT] = L.holes_light ? 1.0f : 0.0f;
    for (int c = 0; c < 3; ++c) P[P_LIGHT_R + c] = float(L.light_rgb[c]);
    P[P_PERF_SEED] = float(L.perf_seed); P[P_LIGHT_FALL] = float(L.light_fall); P[P_LIGHT_DIR] = float(L.light_dir);
    P[P_WALL_T] = float(L.wall_t); P[P_WALL_VS] = float(L.wall_tilt[0]); P[P_WALL_VT] = float(L.wall_tilt[1]);
    P[P_WALL_PAR] = float(L.wall_parallax);
    for (int c = 0; c < 3; ++c) P[P_BASE_R + c] = float(L.base_rgb[c]);
    P[P_WALL_GLOW] = float(L.wall_glow); P[P_WALL_SCATTER] = float(L.wall_scatter);
}

// ---------------------------------------------------------------------------
// Imprints: the edge print (film data, placed by the layout) and the date.
// ---------------------------------------------------------------------------
namespace {

void film_to_canvas_px(const OverscanLayout& L, double s, double t, double& x, double& y) {
    // Inverse of canvas -> film: (u, v) = A^-1 ((s, t) - (cs, ct)) + (cu, cv).
    const double a = L.A[0], b = L.A[1], c = L.A[2], d = L.A[3];
    const double det = a * d - b * c;
    const double ds = s - L.cs, dt = t - L.ct;
    const double u = (d * ds - b * dt) / det + L.cu, v = (-c * ds + a * dt) / det + L.cv;
    x = u / L.px;
    y = v / L.px;
}

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

// Rasterise one group into a canvas-aligned coverage bitmap (its bounding box).
bool rasterise(const OverscanLayout& L, const Group& g, std::vector<float>& cov, int& x0, int& y0,
               int& w, int& h) {
    // Bounding box in canvas px from each op's film-space extent (generous for text).
    double xmin = 1e30, ymin = 1e30, xmax = -1e30, ymax = -1e30;
    auto grow = [&](double s, double t) {
        double x, y;
        film_to_canvas_px(L, s, t, x, y);
        xmin = std::min(xmin, x); ymin = std::min(ymin, y); xmax = std::max(xmax, x); ymax = std::max(ymax, y);
    };
    for (const Op& op : g.ops) {
        if (op.kind == Op::Poly) {
            for (size_t k = 0; k + 1 < op.pts.size(); k += 2) grow(op.pts[k], op.pts[k + 1]);
        } else if (op.kind == Op::Circle) {
            grow(op.pts[0] - op.size_mm, op.pts[1] - op.size_mm);
            grow(op.pts[0] + op.size_mm, op.pts[1] + op.size_mm);
        } else {
            const double len = (0.75 * op.size_mm + op.tracking_mm) * double(op.text.size()) + op.size_mm;
            const double r = op.rot_deg * M_PI / 180.0;
            const double ex = std::cos(r), ey = std::sin(r);
            for (double a : {-0.3 * op.size_mm, len})
                for (double b : {-1.1 * op.size_mm, 0.4 * op.size_mm})
                    grow(op.s + a * ex - b * ey, op.t + a * ey + b * ex);
        }
    }
    const double pad = 3.0 + 3.0 * g.blur_mm / L.px;
    x0 = std::max(0, int(std::floor(xmin - pad)));
    y0 = std::max(0, int(std::floor(ymin - pad)));
    const int x1 = std::min(int(L.canvas_w), int(std::ceil(xmax + pad)));
    const int y1 = std::min(int(L.canvas_h), int(std::ceil(ymax + pad)));
    w = x1 - x0; h = y1 - y0;
    if (w <= 0 || h <= 0) return false;

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
        CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1.0, -1.0));   // t is down; glyphs are up
        CGContextSetTextPosition(ctx, 0, 0);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line); CFRelease(as); CFRelease(font);
    }
    CGContextRelease(ctx);

    cov.resize(px.size());
    for (size_t i = 0; i < px.size(); ++i) cov[i] = float(px[i]) * (1.0f / 255.0f);
    // The projection's softness (RFC-031 §3.4): a small Gaussian on the mask.
    const double sigma = g.blur_mm / L.px;
    if (sigma > 0.3) {
        const int r = int(std::ceil(3.0 * sigma));
        std::vector<float> k(size_t(2 * r + 1));
        double sum = 0.0;
        for (int i = -r; i <= r; ++i) { k[size_t(i + r)] = float(std::exp(-0.5 * i * i / (sigma * sigma))); sum += k[size_t(i + r)]; }
        for (float& v : k) v = float(v / sum);
        std::vector<float> tmp(cov.size(), 0.0f);
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x) {
                float acc = 0;
                for (int i = -r; i <= r; ++i) { const int xx = std::clamp(x + i, 0, w - 1); acc += k[size_t(i + r)] * cov[size_t(y) * size_t(w) + size_t(xx)]; }
                tmp[size_t(y) * size_t(w) + size_t(x)] = acc;
            }
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x) {
                float acc = 0;
                for (int i = -r; i <= r; ++i) { const int yy = std::clamp(y + i, 0, h - 1); acc += k[size_t(i + r)] * tmp[size_t(yy) * size_t(w) + size_t(x)]; }
                cov[size_t(y) * size_t(w) + size_t(x)] = acc;
            }
    }
    return true;
}

// A 5x7 dot-matrix face (rows top to bottom, bit 4 = left column): the
// data backs that print shooting data (645N, F5/F6) and the dot-matrix date
// backs use one, and it reads the same at 0.5 mm as at 1 mm.
const uint8_t* glyph5x7(char ch) {
    static const struct { char c; uint8_t r[7]; } kFont[] = {
        {'0', {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E}}, {'1', {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E}},
        {'2', {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}}, {'3', {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E}},
        {'4', {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}}, {'5', {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E}},
        {'6', {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}}, {'7', {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
        {'8', {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}}, {'9', {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C}},
        {'A', {0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11}}, {'B', {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E}},
        {'C', {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E}}, {'D', {0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C}},
        {'E', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F}}, {'F', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10}},
        {'G', {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F}}, {'H', {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}},
        {'I', {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E}}, {'J', {0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C}},
        {'K', {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}}, {'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F}},
        {'M', {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11}}, {'N', {0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11}},
        {'O', {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}}, {'P', {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10}},
        {'Q', {0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D}}, {'R', {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11}},
        {'S', {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E}}, {'T', {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
        {'U', {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}}, {'V', {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04}},
        {'W', {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A}}, {'X', {0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11}},
        {'Y', {0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04}}, {'Z', {0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F}},
        {'m', {0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11}}, {'v', {0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04}},
        {'s', {0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x1E}}, {'.', {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C}},
        {'/', {0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00}}, {'-', {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00}},
        {'+', {0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00}}, {':', {0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00}},
        {'\'', {0x0C, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00}}, {'(', {0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02}},
        {')', {0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08}},
    };
    for (const auto& g : kFont) if (g.c == ch) return g.r;
    if (ch >= 'a' && ch <= 'z') return glyph5x7(char(ch - 'a' + 'A'));
    return nullptr;
}

// Lay `text` out in the 5x7 face: character height h (7 rows), left of the
// baseline at glyph (0, 0), y up; each lit cell becomes a dot (`round`) or a
// square, handed to `emit(x, y, pitch)` at its centre.
template <class Emit>
double dot_matrix(const std::string& text, double h, Emit emit) {
    const double pitch = h / 7.0;
    double x = 0.0;
    for (char ch : text) {
        if (ch == ' ') { x += 4.0 * pitch; continue; }
        const uint8_t* g = glyph5x7(ch);
        if (!g) { x += 4.0 * pitch; continue; }
        for (int row = 0; row < 7; ++row)
            for (int col = 0; col < 5; ++col)
                if (g[row] & (0x10 >> col)) emit(x + (col + 0.5) * pitch, (6 - row + 0.5) * pitch, pitch);
        x += 6.0 * pitch;
    }
    return std::max(0.0, x - pitch);
}

// The DX film-edge bar code (ISO 1007, frame-number version): 31 modules in
// 13 mm. Clock track, nearer the perforations: a 5-module bar, 23 single
// modules alternating from white, a 3-module bar. Data track, at the film's
// edge: start b/w/b/w/b, 23 bits under the clock's singles, stop b/w/b. Bits:
// [0] 0, [1..7] DX part 1, [8] 0, [9..12] DX part 2, [13..18] frame number,
// [19] half frame, [20] 0, [21] parity (set bits before it, mod 2), [22] 0.
// Cross-checked against an independent reader's encoder/decoder
// (lexluthor0304/NegativeConverter `filmEdgeReader.js`, MIT).
void dx_bits(int dx_extract, int frame, bool half, int bits[23]) {
    for (int i = 0; i < 23; ++i) bits[i] = 0;
    const int p1 = (dx_extract >> 4) & 0x7F, p2 = dx_extract & 0xF;
    for (int i = 0; i < 7; ++i) bits[1 + i] = (p1 >> (6 - i)) & 1;
    for (int i = 0; i < 4; ++i) bits[9 + i] = (p2 >> (3 - i)) & 1;
    for (int i = 0; i < 6; ++i) bits[13 + i] = (std::clamp(frame, 0, 63) >> (5 - i)) & 1;
    bits[19] = half ? 1 : 0;
    int sum = 0;
    for (int i = 0; i < 21; ++i) sum += bits[i];
    bits[21] = sum % 2;
}

// DX numbers (part 1 x 16 + part 2) of the stocks we ship, from The Big Film
// Database (dxdatabase, CC BY-SA 4.0) as excerpted by NegativeConverter's
// `dxFilmTable.js`. A stock with no DX code (motion-picture film, Kodachrome
// here) prints no bars -- an empty edge is truer than an invented code.
int dx_extract_for(const std::string& stock) {
    static const struct { const char* id; int dx; } kDx[] = {
        {"kodak_portra_400", 1277}, {"kodak_portra_800", 1278}, {"kodak_portra_800_push1", 1278},
        {"kodak_portra_800_push2", 1278}, {"kodak_portra_160", 1275}, {"kodak_gold_200", 1250},
        {"kodak_ektar_100", 1307}, {"kodak_ultramax_400", 1313}, {"kodak_ektachrome_100", 382},
        {"fujifilm_c200", 625}, {"fujifilm_xtra_400", 626}, {"fujifilm_pro_400h", 584},
        {"fujifilm_provia_100f", 557}, {"fujifilm_velvia_100", 523},
    };
    for (const auto& e : kDx) if (stock == e.id) return e.dx;
    return -1;
}

// **We assumed it wrong for every Fujifilm stock** (owner, 2026-10-03). The
// film data below -- the edge print's typeface, size and placement, the
// frame numbering, the DX code's layout and the 120 markers -- was measured
// on Kodak film and is drawn for every stock the same way. Fujifilm's edge
// marks are not Kodak's: C200, X-Tra 400, Pro 400H, Provia 100F and Velvia
// 100 render with Kodak's layout and are wrong. C200 is likely made by Kodak
// and so nearer to it, but was not checked either. The owner is supplying
// references for RVP (Velvia), RDP (Provia) and Pro 400H; until a per-stock
// layout exists, treat every Fujifilm film edge as a placeholder.
void imprint_groups(const OverscanLayout& L, const Params& params, double frame_w_mm, double frame_h_mm,
                    std::vector<Group>& out) {
    const OverscanParams& o = params.film_render.overscan;
    const DateImprintParams& d = params.film_render.date_imprint;
    const uint64_t cam = uint64_t(uint32_t(o.camera_seed)), frm = uint64_t(uint32_t(o.frame_seed));
    Rng rf(stream(frm ^ (cam << 32), kFrame, 7));

    const double s_min = L.cs - 0.75 * (L.vertical ? L.canvas_h : L.canvas_w) * L.px;
    const double s_max = L.cs + 0.75 * (L.vertical ? L.canvas_h : L.canvas_w) * L.px;
    const double edge_ev = 3.2;                                   // fitted to the owner's 120 references
    const double e_edge = kMidGrey * std::pow(2.0, edge_ev);

    auto group_for = [&](const double rgb[3], double e, double blur_mm) {
        Group g;
        for (int c = 0; c < 3; ++c) g.exposure[c] = rgb[c] * e;
        g.blur_mm = blur_mm;
        return g;
    };
    auto rect = [](double s0, double t0, double s1, double t1) {
        Op op;
        op.kind = Op::Poly;
        op.pts = {s0, t0, s1, t0, s1, t1, s0, t1};
        return op;
    };

    // The edge print has a slot between the numbers; text longer than the
    // slot would run under the next number and over itself. Helvetica's caps
    // average ~0.68 em, so that is the width taken: whole words are dropped
    // from the end until it fits, and the first word is cut if it alone does
    // not. A stock's name fits; this is for a host that sends anything.
    auto fit_edge_text = [](std::string text, double slot_mm, double size_mm, double tracking_mm) {
        const double per_char = 0.68 * size_mm + tracking_mm;
        const size_t max_chars = size_t(std::max(1.0, std::floor(slot_mm / per_char)));
        if (text.size() <= max_chars) return text;
        const size_t cut = text.rfind(' ', max_chars);
        if (cut != std::string::npos && cut > 0) return text.substr(0, cut);
        return text.substr(0, max_chars);
    };
    if (L.valid && L.perforated) {
        // Film data on a half-frame grid (4 perforations = 19.00 mm) anchored
        // to the perforations. Sizes and positions measured on a real Kodak
        // strip (RFC-032 §29.2, 23.1 px/mm): the top band carries the stock
        // name and the full-frame numbers, cap 1.15 mm, baseline 1.43 mm from
        // the edge; the bottom band carries the DX code -- 13 mm long, the
        // whole 2.2 mm between the perforations and the edge -- then the
        // frame number: "13" at cap 1.3 mm, or "12A" at cap 0.72 mm over an arrow.
        const int n0 = 1 + int(uint64_t(uint32_t(o.frame_seed)) % 34u);    // film data: which frame this is
        const double grid0 = L.perf_phase + 0.62;
        Group top = group_for(L.edge_rgb, e_edge, 0.022);
        Group bot = group_for(L.edge_rgb, e_edge, 0.022);
        const double W = L.film_w, kCap = 0.714;                 // Helvetica Neue's cap height per em
        const double t_top = 1.43;
        const int dx = dx_extract_for(params.film.info.stock);
        const double mod = 13.0 / 31.0;
        const double clock_t0 = W - 2.17, data_t0 = W - 0.87, data_t1 = W + 0.10;
        const int m_lo = int(std::floor((s_min - grid0) / 19.0)) - 1, m_hi = int(std::ceil((s_max - grid0) / 19.0)) + 1;
        for (int m = m_lo; m <= m_hi; ++m) {
            const double s = grid0 + 19.0 * m;
            const int half = 2 * n0 + m;
            const int num = half / 2 - (half < 0 && half % 2 ? 1 : 0);
            const bool a_half = (half % 2) != 0;
            Op op;
            op.font = "HelveticaNeue-Bold";
            op.size_mm = 1.15 / kCap;
            op.tracking_mm = 0.04;
            if (!a_half) {
                op.text = std::to_string(num); op.s = s + 14.6; op.t = t_top; top.ops.push_back(op);
            } else if (!o.edge_text.empty()) {
                // From s + 1.5 to the next number at s + 19 + 14.6, less a space.
                op.text = fit_edge_text(o.edge_text, 19.0 + 14.6 - 1.5 - 2.0, op.size_mm, 0.06);
                op.s = s + 1.5; op.t = t_top; op.tracking_mm = 0.06; top.ops.push_back(op);
            }
            // The DX code, as runs of black modules so neighbours do not seam.
            if (dx >= 0) {
                int bits[23];
                dx_bits(dx, std::max(0, num), a_half, bits);
                int clock[31], data[31];
                for (int i = 0; i < 31; ++i) {
                    clock[i] = (i < 5 || i >= 28) ? 1 : ((i - 5) % 2);
                    data[i] = i < 5 ? (i % 2 == 0) : (i >= 28 ? ((i - 28) % 2 == 0) : bits[i - 5]);
                }
                for (int track = 0; track < 2; ++track) {
                    const int* row = track == 0 ? clock : data;
                    const double ta = track == 0 ? clock_t0 : data_t0, tb = track == 0 ? data_t0 : data_t1;
                    for (int i = 0; i < 31;) {
                        if (!row[i]) { ++i; continue; }
                        int j = i;
                        while (j < 31 && row[j]) ++j;
                        bot.ops.push_back(rect(s + i * mod, ta, s + j * mod, tb + (track == 0 ? 0.01 : 0.0)));
                        i = j;
                    }
                }
            }
            Op nb = op;
            nb.tracking_mm = 0.03;
            if (a_half) {
                nb.text = std::to_string(num) + "A";
                nb.size_mm = 0.72 / kCap; nb.s = s + 13.0 + 2.7; nb.t = W - 0.95;
                bot.ops.push_back(nb);
                // the arrow under it, pointing the way the film winds on
                const double a0 = s + 13.0 + 1.9, a1 = s + 13.0 + 5.4, ta = W - 0.47, th = 0.09;
                bot.ops.push_back(rect(a0, ta - th, a1 - 0.45, ta + th));
                Op head;
                head.kind = Op::Poly;
                head.pts = {a1 - 0.6, ta - 0.26, a1, ta, a1 - 0.6, ta + 0.26};
                bot.ops.push_back(head);
            } else {
                nb.text = std::to_string(num);
                nb.size_mm = 1.30 / kCap; nb.s = s + 13.0 + 3.1; nb.t = W - 0.22;
                bot.ops.push_back(nb);
            }
        }
        out.push_back(top);
        out.push_back(bot);
    } else if (L.valid) {
        // 120 (measured on the owner's IMG_6472-6474): top band, stock text
        // between numbers that count along the roll, period ~49.5 mm; bottom
        // band, ► markers, some followed by a digit. Not sprocket-locked, so
        // where they land relative to the frame is the frame's draw.
        Group top = group_for(L.edge_rgb, e_edge, 0.038);
        Group bot = group_for(L.edge_rgb, e_edge, 0.038);
        const double period = 49.5, cap = 1.3, size = cap / 0.714;
        const double roll = rf.uni(0.0, period);
        const int n0 = 12 + int(rf.uni(0.0, 40.0));
        // The stock name's baseline sits ~0.85 mm above the gate's edge where
        // it runs: the recess, on a shouldered gate (measured: 1.84 mm from the
        // film's edge on the 6x8 reference), so the ears reach into its band.
        const double t_top = std::max(0.9, L.gate_t0 + L.top_recess - 0.85);
        const double t_bot = L.film_w - std::max(0.35, 0.5 * (L.film_w - L.gate_t0 - L.gate_across) - 0.6);
        const int j_lo = int(std::floor((s_min + roll) / period)) - 1, j_hi = int(std::ceil((s_max + roll) / period)) + 1;
        for (int j = j_lo; j <= j_hi; ++j) {
            const double s = -roll + j * period;
            Op num;
            num.size_mm = size; num.tracking_mm = 0.05;
            num.text = std::to_string(n0 + j); num.s = s; num.t = t_top;
            top.ops.push_back(num);
            if (!o.edge_text.empty()) {
                Op tx = num;
                tx.text = fit_edge_text(o.edge_text, period - 10.8 - 3.0, size, 0.14);
                tx.s = s + 10.8; tx.tracking_mm = 0.14;
                top.ops.push_back(tx);
            }
        }
        const double mark_period = 29.0, mroll = rf.uni(0.0, mark_period);
        const int k_lo = int(std::floor((s_min + mroll) / mark_period)) - 1, k_hi = int(std::ceil((s_max + mroll) / mark_period)) + 1;
        const double mh = 0.95;
        for (int k = k_lo; k <= k_hi; ++k) {
            const double s = -mroll + k * mark_period;
            Op tri;
            tri.kind = Op::Poly;
            tri.pts = {s, t_bot - mh, s + 1.9 * mh, t_bot - 0.5 * mh, s, t_bot};
            bot.ops.push_back(tri);
            if (((k % 2) + 2) % 2 == 0) {
                Op dg;
                dg.size_mm = 1.0 / 0.714; dg.text = std::to_string(1 + ((k / 2) % 9 + 9) % 9);
                dg.s = s + 2.9; dg.t = t_bot;
                bot.ops.push_back(dg);
            }
        }
        out.push_back(top);
        out.push_back(bot);
    }

    // The manufacturer's printing is not uniform: each mark's density varies a
    // little (film data would fix it per roll; the frame's draw stands in).
    for (Group& g : out)
        for (Op& op : g.ops) op.gain = std::clamp(0.80 + 0.2 * rf.uni() + 0.05 * rf.normal(), 0.6, 1.0);

    // The date back (RFC-031 §8): one mechanism -- a light behind the film
    // through a mask -- in three faces. lcd and dots go in the picture (or
    // between frames with placement = rebate) on 135 and 135 half frame; data
    // is shooting data in the 5x7 face, between frames on 135 (F5/F6 backs)
    // and in the film margin on 645 (645N). No other format had a back that
    // printed.
    //
    // The back is part of the camera (RFC-032 §32): everything is placed and
    // turned in the *film's* frame -- s along the film, t across it, +t the
    // camera's "down" -- never the picture's. Turn a full-frame camera for a
    // portrait and the date turns with it: it runs along the film, beside the
    // picture, not upright in it. A half-frame camera held level makes a
    // portrait frame with the film running across it, so there the date is
    // upright in the portrait.
    if (!d.active || d.text.empty()) return;
    const std::string fmt = L.valid ? L.format : (o.format == "135_half" ? std::string("135_half") : std::string("135"));
    const bool data = d.style == "data";
    const bool is135 = fmt == "135" || fmt == "135_half";
    if (!is135 && !(data && fmt == "120_645")) return;
    Group g;
    const double e = kMidGrey * std::pow(2.0, d.exposure_ev);
    for (int c = 0; c < 3; ++c) g.exposure[c] = L.date_rgb[c] * e;
    g.blur_mm = 0.015;
    const double k = std::clamp(d.size, 0.4, 3.0);
    // A face's glyphs, laid out in glyph space (x right, y up from the
    // baseline) and mapped to film mm by `place(x, y) -> (s, t)`.
    auto draw = [&](double h, auto place) {
        if (d.style == "lcd") {
            Op proto;
            proto.skew = std::tan(8.0 * M_PI / 180.0);
            std::vector<Op> segs;
            seven_seg_polys(d.text, h, 0.0, 0.0, proto, segs);
            for (Op& op : segs) {
                // seven_seg_polys writes (s0 + gx, t0 - gy); undo to glyph space, then place
                for (size_t i = 0; i + 1 < op.pts.size(); i += 2) {
                    double ss, tt;
                    place(op.pts[i], -op.pts[i + 1], ss, tt);
                    op.pts[i] = ss; op.pts[i + 1] = tt;
                }
                g.ops.push_back(op);
            }
            return;
        }
        const bool dots = d.style == "dots";
        dot_matrix(d.text, h, [&](double x, double y, double pitch) {
            if (dots) {
                Op c;
                c.kind = Op::Circle;
                double ss, tt;
                place(x, y, ss, tt);
                c.pts = {ss, tt};
                c.size_mm = 0.36 * pitch;
                g.ops.push_back(c);
            } else {
                Op q;
                q.kind = Op::Poly;
                const double hp = 0.5 * pitch * 1.02;
                const double xs[4] = {x - hp, x + hp, x + hp, x - hp}, ys[4] = {y - hp, y - hp, y + hp, y + hp};
                for (int i = 0; i < 4; ++i) {
                    double ss, tt;
                    place(xs[i], ys[i], ss, tt);
                    q.pts.push_back(ss); q.pts.push_back(tt);
                }
                g.ops.push_back(q);
            }
        });
    };
    auto text_width = [&](double h) {
        if (d.style == "lcd") return seven_seg_width(d.text, h);
        return dot_matrix(d.text, h, [](double, double, double) {});
    };

    const double gw = L.valid ? L.gate_along : frame_w_mm, gh = L.valid ? L.gate_across : frame_h_mm;
    const double gs = L.valid ? L.gate_s0 : 0.0, gt = L.valid ? L.gate_t0 : 0.0;
    const double gap = L.valid ? std::max(0.6, (L.vertical ? L.canvas_h : L.canvas_w) * L.px - L.gate_along) * 0.5 : 0.0;
    if (data && fmt == "120_645") {
        // 645N: one line in the margin beside the frame, reading along the
        // film, ~0.3 mm off the gate, on the side away from the stock name.
        const double h = 0.55 * k;
        const double t_base = gt + gh + 0.30 + h;
        const double s0 = gs + 0.08 * gw;
        draw(h, [&](double x, double y, double& ss, double& tt) { ss = s0 + x; tt = t_base - y; });
    } else if ((data || d.placement == "rebate") && L.valid) {
        // Between frames, rotated, as the F6/MF-28 place data (RFC-033 §5):
        // to the left of the frame, reading up the film's width.
        const double h = (data ? 0.50 : 0.55) * k;
        const double w = text_width(h);
        const double s_c = gs - 0.5 * gap;
        const double t_c = gt + 0.5 * gh + 0.5 * w;
        draw(h, [&](double x, double y, double& ss, double& tt) { ss = s_c + 0.5 * h - y; tt = t_c - x; });
    } else if (!data) {
        // In the frame, at the chosen corner of the *film's* frame (the corner
        // as the camera's back sees it, held level), inset from the gate.
        const double h = (d.style == "dots" ? 0.95 : 1.3) * k;
        const double w = text_width(h);
        const bool right = d.corner == "br" || d.corner == "tr", bottom = d.corner == "br" || d.corner == "bl";
        // With overscan the layout is already in film mm. The date alone draws
        // on the bare frame, so the film's direction comes from its shape: a
        // full frame taller than wide, or a half frame wider than tall, was
        // shot with the camera turned, and the film runs down the picture
        // (the same quarter turn the overscan layout uses).
        bool turned = false;
        double fs = gs, ft = gt, fw = gw, fh = gh;
        if (!L.valid) {
            turned = fmt == "135_half" ? frame_w_mm > frame_h_mm : frame_h_mm > frame_w_mm;
            fs = 0.0; ft = 0.0;
            fw = turned ? frame_h_mm : frame_w_mm;
            fh = turned ? frame_w_mm : frame_h_mm;
        }
        // Kept inside the frame: a large face or an inset past the frame's
        // middle would otherwise carry the text off its edge. Text wider than
        // the frame starts at its left and is clipped by the gate.
        const double over = (d.style == "lcd" ? h * std::tan(8.0 * M_PI / 180.0) : 0.0) + 0.1;   // the slant, and the blur
        const double s0 = std::clamp(right ? fs + fw - d.inset_x - w : fs + d.inset_x, fs + 0.1, std::max(fs + 0.1, fs + fw - w - over));
        const double base = std::clamp(bottom ? ft + fh - d.inset_y : ft + d.inset_y + h, std::min(ft + h + 0.1, ft + fh - 0.1), ft + fh - 0.1);
        draw(h, [&](double x, double y, double& ss, double& tt) {
            const double sf = s0 + x, tf = base - y;
            if (!turned) { ss = sf; tt = tf; }
            else { ss = fh - tf; tt = sf; }       // picture x = across - t, y = s
        });
    }
    out.push_back(g);
}

}  // namespace

// ---------------------------------------------------------------------------
// The nodes.
// ---------------------------------------------------------------------------
bool Pipeline::node_overscan(const Image& in, Image& out, std::string& error) {
    const DateImprintParams& di = params_.film_render.date_imprint;
    if (di.active) {
        if (di.style != "lcd" && di.style != "dots" && di.style != "data") {
            error = "date_imprint: unknown style '" + di.style + "' (lcd, dots, data)";
            return false;
        }
        if (di.corner != "br" && di.corner != "bl" && di.corner != "tr" && di.corner != "tl") {
            error = "date_imprint: unknown corner '" + di.corner + "' (br, bl, tr, tl)";
            return false;
        }
        if (di.placement != "frame" && di.placement != "rebate") {
            error = "date_imprint: unknown placement '" + di.placement + "' (frame, rebate)";
            return false;
        }
    }
    const bool date_only = !overscan_wanted() && di.active;
    if (!overscan_wanted() && !date_only) { out = in; return true; }
    Timer t(this, "filming.expose.overscan");
    frame_w_mm_ = in.w * pixel_size_um_ / 1000.0;
    frame_h_mm_ = in.h * pixel_size_um_ / 1000.0;

    Image canvas;
    if (overscan_wanted()) {
        if (!overscan_layout(in.w, in.h, error)) return false;
        std::vector<float> P;
        overscan_params_block(P);
        gpu::BufferRef pb = gpu_->upload(P.data(), P.size() * sizeof(float), error);
        if (!pb) return false;
        canvas.h = overscan_.canvas_h; canvas.w = overscan_.canvas_w; canvas.c = 3;
        canvas.buf = gpu_->alloc(canvas.bytes(), error);
        if (!canvas.buf) return false;
        const uint32_t n[1] = {uint32_t(canvas.pixels())};
        if (!gpu_->dispatch("spk_overscan_canvas",
                            {gpu::Arg::buf(in.buf), gpu::Arg::buf(pb), gpu::Arg::inline_bytes(n, 1),
                             gpu::Arg::buf(canvas.buf)},
                            canvas.pixels(), error)) return false;
    } else {
        // The date alone, on the frame: an identity layout over the frame.
        overscan_ = OverscanLayout{};
        OverscanLayout& L = overscan_;
        L.px = pixel_size_um_ / 1000.0;
        L.canvas_w = in.w; L.canvas_h = in.h;
        L.A[0] = 1; L.A[1] = 0; L.A[2] = 0; L.A[3] = 1;
        L.cu = 0; L.cv = 0; L.cs = 0; L.ct = 0;
        {
            const double rear[3] = {1.0, 1.0, 0.0};
            light_weights(*colour_, *blob_, film_sensitivity_, params_.film.info.reference_illuminant,
                          2700.0, true, rear, L.date_rgb);
        }
        canvas.h = in.h; canvas.w = in.w; canvas.c = 3;
        canvas.buf = gpu_->alloc(canvas.bytes(), error);
        if (!canvas.buf) return false;
        double s[3] = {1, 1, 1}, z[3] = {0, 0, 0};
        if (!blur_.affine(in, s, z, canvas, error)) return false;
    }

    std::vector<Group> groups;
    imprint_groups(overscan_, params_, frame_w_mm_, frame_h_mm_, groups);
    for (const Group& gg : groups) {
        std::vector<float> cov;
        int x0, y0, w, h;
        if (!rasterise(overscan_, gg, cov, x0, y0, w, h)) continue;
        gpu::BufferRef mb = gpu_->upload(cov.data(), cov.size() * sizeof(float), error);
        if (!mb) return false;
        const float M[9] = {float(x0), float(y0), float(w), float(h), float(canvas.w), float(canvas.h),
                            float(gg.exposure[0]), float(gg.exposure[1]), float(gg.exposure[2])};
        const uint32_t n[1] = {uint32_t(size_t(w) * size_t(h))};
        if (!gpu_->dispatch("spk_overscan_add_mask",
                            {gpu::Arg::buf(mb), gpu::Arg::inline_bytes(M, 9), gpu::Arg::inline_bytes(n, 1),
                             gpu::Arg::buf(canvas.buf)},
                            size_t(w) * size_t(h), error)) return false;
    }
    out = canvas;
    return true;
}

bool Pipeline::node_overscan_film_present(const Image& in, Image& out, std::string& error) {
    if (!overscan_wanted()) { out = in; return true; }
    if (!overscan_.valid || in.w != overscan_.canvas_w || in.h != overscan_.canvas_h) {
        error = "overscan: the negative does not match this pipeline's overscan layout";
        return false;
    }
    Timer t(this, "printing.overscan.film_present");
    std::vector<float> P;
    overscan_params_block(P);
    gpu::BufferRef pb = gpu_->upload(P.data(), P.size() * sizeof(float), error);
    if (!pb || !alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.pixels())};
    return gpu_->dispatch("spk_overscan_film_present",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(pb), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::node_overscan_light(const Image& in, Image& out, std::string& error) {
    if (!overscan_wanted()) { out = in; return true; }
    if (!overscan_.valid || in.w != overscan_.canvas_w || in.h != overscan_.canvas_h) {
        error = "overscan: the print does not match this pipeline's overscan layout";
        return false;
    }
    Timer t(this, "printing.overscan.light");
    std::vector<float> P;
    overscan_params_block(P);
    gpu::BufferRef pb = gpu_->upload(P.data(), P.size() * sizeof(float), error);
    if (!pb || !alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.pixels())};
    return gpu_->dispatch("spk_overscan_light",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(pb), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

}  // namespace spk
