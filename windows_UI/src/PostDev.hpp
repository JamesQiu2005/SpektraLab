#pragma once
// Post-Dev ("Layer 2"): the grade on the finished print -- white balance on
// the scan, exposure, contrast, brightness, saturation, highlights, shadows,
// black/white point, five tone curves, four colour-balance zones and the
// vignette. A port of the macOS app's Model/Adjustments.swift,
// Model/CurveMath.swift and the `layer2` kernel of Canvas/Shaders.metal
// (layer2Tone 270-313, the kernel 315-404). Post-Dev never reaches the engine
// and never touches the film or the paper: "the final look belongs in Layer 2"
// (AGENTS.md). Order is fixed and is the Mac's:
//
//   white balance -> exposure/contrast/brightness -> highlights/shadows
//   -> black/white point -> saturation -> colour balance -> curves -> vignette
//
// Three implementations of one arithmetic, held together by spk_qt_postdev:
//   * Grade::apply   -- the CPU path, float32 like the GPU, threaded by rows;
//   * shaders/postdev.glsl -- `vec3 postdev(...)` for the canvas's fragment
//     shader, fed by std140() and curveTables() below;
//   * the test's double-precision transcription of Shaders.metal, the oracle.
//
// ---------------------------------------------------------------------------
// Integration (who calls what)
//
// Colour (AGENTS.md trap 27). Layer 2 grades *encoded* working-space values,
// as a scan is adjusted after the fact (Shaders.metal:4-17). On the Mac that
// is ProPhoto RGB, ROMM gamma 1.8 (RFC-018). The only encoding-dependent
// number is the tone pivot `midGrey` -- the encoded value of linear 0.18 --
// so pass proPhotoMidGrey for a ProPhoto frame and srgbMidGrey for an sRGB
// one (midGreyFor() reads it off a QColorSpace and refuses anything else,
// linear data in particular). Only a ProPhoto frame grades like the Mac: the
// gains, the saturation and the curves act on whatever primaries the values
// carry. Windows frames are sRGB today (ColorPipeline.hpp:9); grading them is
// what the desktop/ port does (desktop/src/shared/adjustments.ts:236).
//
// Canvas (GPU lane). Include shaders/postdev.glsl in the canvas fragment
// shader and call, *after* sampling the frame and *before* the display LUT:
//     rgb = postdev(rgb, sourceUv, grade, postdevCurves);
// where `rgb` is the sampled frame in its own encoding (not linearised, not
// display-encoded), `sourceUv` is the sample's position on the *uncropped,
// unturned* source in [0,1] (the vignette is the print's, before geometry:
// Shaders.metal:340 takes uv from the Layer 2 texture, which is the source),
// `grade` is a `PostDev` member of the canvas's std140 uniform block filled
// with std140(), 16-byte aligned, and `postdevCurves` is a 256 x 5 R32F 2-D
// texture holding curveTables() row-major (rows rgb, luma, red, green, blue),
// read with texelFetch so it needs no filtering support and gets exact
// weights. Re-upload the texture when the curves change, the block when any
// field does. The Mac runs Layer 2 per *source texel* into a texture and
// then samples it (Renderer.swift:572-602, 819); a fragment shader that
// grades after a filtered sample is the same picture wherever the sampler
// returns a texel (1:1, nearest) and differs only by filtering order where it
// interpolates -- the canvas lane's call. Bypass (Shift-Command-B on the Mac,
// SpektrafilmApp.swift:171-173) is `enabled = false`, a stored edit, so it
// reaches the file as well as the canvas.
//
// Export (output lane). Grade the full-resolution frame on the CPU *before*
// geometry, as Exporter.swift:374-401 does on the GPU: build one Grade from
// the frame's Params and the frame's mid-grey, call Grade::apply on the
// uncropped float or RGBA64 frame (row uv = (y+0.5)/H, column (x+0.5)/W),
// then crop/straighten/turn, resize and convert. Identity params return the
// pixels untouched, bit for bit, so an ungraded export is the print.
//
// Navigator and thumbnails (trap 33). Every surface that shows the frame
// shows the canvas's frame, so each grades the *same source* with the *same*
// Grade before its own geometry: a 320 px thumbnail is Grade::apply on the
// downscaled uncropped print (the uv is normalised, so the vignette lands in
// the same place at any size), then the navigator's crop. Do not grade an
// 8-bit image if a 16-bit one is to hand. (The Mac's filmstrip and navigator
// show the print *without* Layer 2 -- Session.swift:2512-2543 makes the
// thumbnail from the engine texture -- so applying it here is a deliberate
// departure in trap 33's direction, not parity.)
//
// Storage (edit store v2). `state.postDev`, an object with exactly the Mac
// sidecar's `adjustments` keys and nesting (Adjustments.swift Codable;
// CGPoint as [x, y]), so a Mac sidecar's object reads verbatim:
//   { "enabled": true,
//     "temperature": 0, "tint": 0,                         -100..100
//     "exposure": 0,                                       -3..3 (stops)
//     "contrast": 0, "brightness": 0,                      -50..50
//     "saturation": 0, "highlights": 0, "shadows": 0,      -100..100
//     "blackPoint": 0, "whitePoint": 0,                    0..50
//     "curves": { "rgb" | "luma" | "red" | "green" | "blue":
//                 { "points": [[x, y], ...] } },           2..32 points
//     "colorBalance": { "master" | "shadows" | "midtones" | "highlights":
//                       { "hue": 0..360, "saturation": 0..1, "luminance": -1..1 } },
//     "vignette": { "amount": -100..100, "midpoint": 0..100 } }
// Every key is optional and takes its default (no effect) when absent, so a
// record from before Post-Dev, or from a build with fewer controls, loads as
// the pure print. A present key is strict, like the rest of the store: the
// wrong type or a value outside its range refuses the record. A key this
// build does not know is a newer build's: fromJson() reports it and the
// store's overlay (EditStore.cpp:344-355) keeps it through the next save.
// Curve points are x non-decreasing from exactly 0 to exactly 1, both in
// [0,1] (the Mac's invariant, CurveMath.swift:27; the editor's insert can
// repeat an x, so equal x is accepted). 32 points per curve bounds the object
// at about 25 KB as the store indents it, with every coordinate at 17 digits
// (spk_qt_postdev measures it), so the record stays inside the store's 64 KiB
// document; the Mac sets no cap, so a Mac curve of more points is refused.
// ---------------------------------------------------------------------------

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <array>
#include <cstddef>
#include <optional>
#include <utility>
#include <vector>

class QColorSpace;
class QImage;

namespace spk::desktop::postdev {

// --- the model ---------------------------------------------------------------

struct CurvePoint {
    double x = 0, y = 0;
    bool operator==(const CurvePoint&) const = default;
};

// A tone curve: control points in the unit square, sorted by x, first at
// x = 0 and last at x = 1, interpolated by a monotone cubic (Fritsch-Carlson)
// exactly as CurveMath.swift:105-137 does -- the same operations in the same
// order in double (CGFloat), so the two agree to the last bit.
struct Curve {
    std::vector<CurvePoint> points{{0, 0}, {1, 1}};
    static constexpr int maxPoints = 32;

    bool isIdentity() const; // exactly [(0,0), (1,1)], as Curve.isIdentity
    double evaluate(double x) const;

    // The editor's operations (CurveMath.swift:35-103), for the QML lane.
    static double hitTolerance(double width, double height); // 10 px in unit terms
    std::optional<int> indexNear(CurvePoint p, double tolerance) const;
    bool isDeletable(int i) const;
    int insert(CurvePoint p);          // clamped, kept sorted; returns its index
    void move(int i, CurvePoint p);    // ends keep x; interior keeps 0.01 from neighbours
    void remove(int i);                // only a deletable point

    bool operator==(const Curve&) const = default;
};

// The order is the curve table's row order (CurveMath.swift:12-13, 175-179).
enum class CurveChannel { rgb = 0, luma = 1, red = 2, green = 3, blue = 4 };

struct CurveSet {
    Curve rgb, luma, red, green, blue;
    Curve& operator[](CurveChannel channel);
    const Curve& operator[](CurveChannel channel) const;
    bool isIdentity() const;
    bool operator==(const CurveSet&) const = default;
};

// One colour-balance zone: hue in degrees (0 = red, 120 = green, 240 =
// blue), saturation 0..1 (the wheel's radius), luminance -1..1.
struct ColorZone {
    double hue = 0, saturation = 0, luminance = 0;
    bool isNeutral() const { return saturation == 0 && luminance == 0; }
    // The RGB offset the zone adds, in float as Adjustments.swift:25-31
    // computes it: (cos h, cos(h - 120), cos(h + 120)) * saturation * 0.25.
    std::array<float, 3> rgbOffset() const;
    bool operator==(const ColorZone&) const = default;
};

struct ColorBalance {
    ColorZone master, shadows, midtones, highlights;
    bool isNeutral() const;
    bool operator==(const ColorBalance&) const = default;
};

struct Vignette {
    double amount = 0;   // -100..100, negative darkens the corners
    double midpoint = 50; // 0..100, where the fall-off starts
    bool operator==(const Vignette&) const = default;
};

// Adjustments.swift:48-68, field for field. Zero is "nothing applied" for
// every control, so a fresh frame reads as the pure simulation.
struct Params {
    bool enabled = true;
    double temperature = 0; // -100..100, blue <-> amber
    double tint = 0;        // -100..100, green <-> magenta
    double exposure = 0;    // stops, -3..3
    double contrast = 0;    // -50..50
    double brightness = 0;  // -50..50
    double saturation = 0;  // -100..100
    double highlights = 0;  // -100..100
    double shadows = 0;     // -100..100
    double blackPoint = 0;  // 0..50
    double whitePoint = 0;  // 0..50
    CurveSet curves;
    ColorBalance colorBalance;
    Vignette vignette;

    // Adjustments.isNeutral: every field at its default, `enabled` aside
    // (what Reset produces; a zone's hue and the vignette's midpoint count).
    bool isNeutral() const;
    bool operator==(const Params&) const = default;
};

// One scalar control: its JSON path under `state.postDev`, range, default and
// the slider's snap (RightSections.swift:39-82, CameraSection.swift:82-85,
// AgentSchema.swift:202-225; 0 where the control is a wheel or arc).
struct Field {
    const char* path;
    double low, high, initial, snap;
};
const std::vector<Field>& fields();

// --- uniforms ------------------------------------------------------------------

// The encoded value of linear 0.18 -- Layer 2's tone pivot (RFC-018 D1) --
// as the Mac writes them (Adjustments.swift:125-136).
inline constexpr float proPhotoMidGrey = 0.3857f; // pow(0.18, 1/1.8)
inline constexpr float srgbMidGrey = 0.4614f;     // 1.055 * 0.18^(1/2.4) - 0.055
// proPhotoMidGrey for ProPhoto RGB's curve, srgbMidGrey for sRGB's, and
// nothing for any other encoding -- linear data in particular, which Layer 2
// must never grade.
std::optional<float> midGreyFor(const QColorSpace& space);

// Layer2Uniforms (Shaders.metal:22-42, Adjustments.swift:97-124), derived in
// float exactly as Adjustments.uniforms and Layer2Uniforms.tone do
// (Adjustments.swift:72-94, Mask.swift:301-324).
struct Uniforms {
    std::array<float, 3> wbGain{1, 1, 1};
    float exposureGain = 1; // 2^stops; the step runs only when != 1
    float exposureScale = 1; // exposureGain^(1/2.2), see Grade
    float contrast = 0, brightness = 0, saturation = 1, highlights = 0, shadows = 0;
    float blackPoint = 0, whitePoint = 0;
    std::array<float, 3> cbMaster{}, cbShadows{}, cbMidtones{}, cbHighlights{};
    std::array<float, 4> cbLum{}; // master, shadows, midtones, highlights (x 0.25)
    float vignetteAmount = 0, vignetteMidpoint = 0.5f;
    float midGrey = proPhotoMidGrey;
    bool curvesActive = false;
    bool enabled = true;
};
Uniforms uniforms(const Params& params, float midGrey = proPhotoMidGrey);
// True when the layer changes no pixel: bypassed, or every uniform neutral
// and no curve. (The Mac would still clamp to [0,1] and round one
// saturation step; its rgba16Unorm input cannot leave [0,1], so returning
// the input untouched is the same picture.)
bool isIdentity(const Uniforms& u);

// --- curves as a table -----------------------------------------------------------

// Five rows of 256 floats -- rgb, luma, red, green, blue -- each entry
// float(curve.evaluate(i / 255)), the Mac's `curveTable` texture
// (CurveMath.swift:139-142, 175-179; TextureStore.swift:416-430).
inline constexpr int curveTableSize = 256;
using CurveTables = std::array<float, 5 * curveTableSize>;
CurveTables curveTables(const CurveSet& curves);

// One row at x, as the Mac's linear, clamp-to-edge, normalised sampler reads
// it (Shaders.metal:145-147, 336): texel centres sit at (i + 0.5) / 256, so x
// lands at p = clamp(256 x - 0.5, 0, 255) and the result is linear between
// entries floor(p) and floor(p) + 1. Note this is not entry x * 255: the
// Mac's curves are stretched about 0.5 by 256/255 (an identity row reads
// 0.24902 at 0.25), up to half an 8-bit count. It is reproduced, not fixed,
// because it is what the Mac renders; desktop/ indexes x * 255 instead.
float curveLookup(const float* row, float x);

// --- the CPU path ------------------------------------------------------------------

// Where an image sits on the uncropped source, normalised: a tile or a crop
// passes its own rectangle so the vignette stays the print's.
struct SourceRect {
    double x = 0, y = 0, width = 1, height = 1;
};

class Grade {
public:
    explicit Grade(const Params& params, float midGrey = proPhotoMidGrey);
    Grade(const Uniforms& uniforms, const CurveTables& tables);

    bool isIdentity() const { return identity_; }
    const Uniforms& uniforms() const { return u_; }
    const CurveTables& tables() const { return tables_; }

    // Steps 1-6 (layer2Tone), the part a mask would share.
    std::array<float, 3> tone(std::array<float, 3> rgb) const;
    // The whole layer for one pixel at source position (u, v). Identity
    // returns `rgb` unchanged; otherwise the result is clamped to [0,1] as
    // the kernel's final saturate (Shaders.metal:403).
    std::array<float, 3> pixel(std::array<float, 3> rgb, float u, float v) const;

    // In place over interleaved float RGB(A): `channels` 3 or 4 (alpha is
    // never touched), `rowStride` in floats (0 = width * channels).
    // `threads` 0 uses every hardware thread. Rows are the unit of work and
    // every pixel is a pure function of its value and position, so the
    // result is bit-identical for any thread count.
    void apply(float* data, int width, int height, int channels, std::ptrdiff_t rowStride = 0,
               int threads = 0, SourceRect source = {}) const;
    // In place over a QImage: RGBX64/RGBA64, RGBX32FPx4/RGBA32FPx4,
    // RGBX8888/RGBA8888 and RGB32/ARGB32. Colour is treated as straight
    // (not premultiplied) and alpha is left alone; 16- and 8-bit results
    // round to nearest. Any other format throws std::invalid_argument.
    void apply(QImage& image, int threads = 0, SourceRect source = {}) const;

private:
    Uniforms u_;
    CurveTables tables_{};
    bool identity_ = true;
};

// --- the GPU block -----------------------------------------------------------------

// The std140 image of `struct PostDev` in shaders/postdev.glsl: ten vec4,
// 160 bytes, all float. Place it at a 16-byte-aligned offset in the uniform
// block. Index (float) -> meaning:
//    0- 3  wbExposure    white-balance gains r, g, b; exposure scale
//    4- 7  tone          contrast, brightness, saturation, highlights
//    8-11  range         shadows, black point, white point, mid-grey
//   12-15  cbMaster      colour-balance offset r, g, b; 0
//   16-19  cbShadows     "
//   20-23  cbMidtones    "
//   24-27  cbHighlights  "
//   28-31  cbLum         luminance: master, shadows, midtones, highlights
//   32-35  vignette      amount, midpoint, 0, 0
//   36-39  switches      active, curves active, exposure active, 0 (1 or 0)
// "active" is 0 for an identity grade, so the shader returns its input
// untouched exactly when Grade::apply does.
inline constexpr std::size_t std140Bytes = 160;
std::array<float, std140Bytes / sizeof(float)> std140(const Grade& grade);

// --- JSON (edit store v2, `state.postDev`; schema above) ------------------------

QJsonObject toJson(const Params& params);
// Throws std::runtime_error naming the field. Keys this build does not know
// are appended to `unknown` as "<label>.<path>"; with `unknown` null they are
// an error instead.
Params fromJson(const QJsonObject& object, QStringList* unknown = nullptr,
                const QString& label = QStringLiteral("state.postDev"));

// --- the colour-balance wheel (ColorWheel.swift), for the QML lane ---------------

namespace wheel {
// The wheel's own square, `diameter` on a side, y down. The point's angle is
// the hue and its distance over (diameter/2 - 5) the saturation, clamped to
// 1 (ColorWheel.swift:219-234). zoneAt keeps the zone's luminance.
ColorZone zoneAt(double x, double y, double diameter, ColorZone zone = {});
std::pair<double, double> pointOf(const ColorZone& zone, double diameter);

// The two arc sliders beside it (ColorWheel.swift:480-553): saturation on
// the left arc (245 deg at the bottom to 115 at the top), luminance on the
// right (-65 to 65). Angles in degrees, 0 = right, 90 = up.
enum class Side { left, right };
double arcTheta(double fraction, Side side);
double arcAngle(double px, double py, double cx, double cy); // y down, (-180, 180]
double arcValue(double thetaDegrees, Side side, double low, double high);
double arcFraction(double value, double low, double high);
} // namespace wheel

} // namespace spk::desktop::postdev
