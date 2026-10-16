#pragma once
// Display colour management for the canvases (FrameCanvas: the main canvas,
// the navigator and the filmstrip thumbnails). This header is the contract
// between the colour core (ColorPipeline.cpp, DisplayColor.*, ColorLut.*) and
// the GPU canvas (FrameCanvas.* with its material and shaders); both sides
// code against it, and additions must not change what is declared here.
//
// A canvas draws a QImage whose colorSpace() says how its pixels are encoded
// (ProPhoto RGB, the session's working space; sRGB for an sRGB session). It
// asks its window's pipeline for the LUT that maps those encoded values to the
// display's encoded values and applies it per screen pixel, after sampling, so
// filtering stays in the source space. UI chrome (letterbox, crop mask,
// guides) never goes through it: in legacy (non-ACM) Windows the OS does not
// manage chrome, so a UI literal is a display value (AGENTS.md trap 27).
#include "ProofTransform.hpp"
#include <QColorSpace>
#include <QObject>
#include <QString>
#include <array>
#include <memory>
#include <vector>

class QQuickWindow;
namespace spk::color { class ProfileSource; }

// The display transform sampled on an N x N x N grid over the source's encoded
// RGB in [0,1]. Node (r, g, b) is at index ((b * N + g) * N + r) * 4. RGB hold
// the display's encoded values (outside [0,1] where the source is out of the
// display's gamut; the shader clamps after interpolating). A is 1 where the
// node lies inside the target gamut and 0 where it was clipped -- the gamut
// warning's input; 1 everywhere when not computed.
//
// Optional 1-D curves around the table (curveSize > 0 sets both). One table
// over encoded values cannot follow a pure power response near black -- sRGB
// to a gamma-2.2 Adobe RGB display missed by 7 counts at (255,29,0), sRGB
// carried in ProPhoto by 14.5 (spk_qt_color_core) -- while a matrix/TRC
// display is exact as decode -> 3x3 -> encode, and trilinear interpolation
// reproduces a 3x3 exactly. With curves the canvas evaluates, per channel:
//     t   = shaper(clamp(source, 0, 1))          (e.g. the source's decode)
//     u   = table(t)                              (then RGB clamped to [0,1])
//     out = output(sqrt(u))                       (e.g. the display's encode)
// The output curve is indexed by sqrt(u) so that a display encoding (about
// u^(1/2.2)) is nearly linear in the index and a uniform curve stays accurate
// in the shadows. Each curve has curveSize entries, RGB per entry (A unused),
// sampled with linear filtering at texel centres like the table:
// coordinate = x * (curveSize - 1) / curveSize + 0.5 / curveSize. The gamut
// flag stays in the table's alpha. Without curves (curveSize == 0) the table
// maps encoded source to encoded display directly, as above -- the right
// choice for LUT-based (A2B/B2A) display profiles.
struct ColorLut {
    int size = 0;              // N; 0 means identity: draw without a LUT
    std::vector<float> rgba;   // size^3 * 4 floats
    quint64 key = 0;           // unique per content; a canvas re-uploads when it changes
    int curveSize = 0;         // entries per curve; 0 = no curves
    std::vector<float> shaper; // curveSize * 4 floats
    std::vector<float> output; // curveSize * 4 floats, indexed by sqrt(table output)
    bool isIdentity() const { return size == 0; }
    bool hasCurves() const { return curveSize > 0; }
};


class ColorPipeline : public QObject {
    Q_OBJECT
    // "automatic" (the OS profile of the window's monitor), "srgb" (assume an
    // sRGB display: identity for sRGB sources), "custom" (customProfilePath).
    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY changed)
    Q_PROPERTY(QString customProfilePath READ customProfilePath WRITE setCustomProfilePath NOTIFY changed)
    // What is being managed to, for the status line, e.g.
    // "DELL U2720Q - U2720Q_D65_2026-09-01.icc" or "sRGB (assumed)". English.
    Q_PROPERTY(QString displayName READ displayName NOTIFY changed)
    // Empty, or an English warning (unreadable profile, fell back to sRGB,
    // Windows Auto Color Management limits output to sRGB, ...).
    Q_PROPERTY(QString status READ status NOTIFY changed)
    // Triangular dither of one output LSB before 8-bit quantisation.
    Q_PROPERTY(bool dither READ dither WRITE setDither NOTIFY changed)
public:
    // One pipeline per top-level window, created on first use and owned by
    // the window; it follows the window's screen. Call on the GUI thread or
    // from QQuickItem::updatePaintNode (the GUI thread is blocked then).
    static ColorPipeline* forWindow(QQuickWindow* window);

    // Never null. Identity when `source` already matches the display or when
    // management is off. Cheap enough to call on every paint: cached per
    // source space. A rebuild runs off the GUI and render threads; until it
    // lands the previous LUT is returned, and changed() is emitted when the
    // new one is ready (canvases then update()).
    std::shared_ptr<const ColorLut> lut(const QColorSpace& source) const;

    // lut(source) once it is the LUT for this display -- built and landed, or
    // the identity because source already is the display's encoding -- and
    // null while it is still being built (changed() follows). The soft proof
    // draws through lut(recipe space) and waits for it here rather than show
    // a recipe space unconverted (ProofTransform.hpp).
    std::shared_ptr<const ColorLut> readyLut(const QColorSpace& source) const;

    QString mode() const;
    void setMode(const QString& mode);
    QString customProfilePath() const;
    void setCustomProfilePath(const QString& path);
    QString displayName() const;
    QString status() const;
    bool dither() const;
    void setDither(bool dither);

    // Tests only: force this LUT for every source (nullptr clears the override).
    void setLutOverrideForTesting(std::shared_ptr<const ColorLut> lut);

    ~ColorPipeline() override;

    // The colour space LUTs are built to now: the display profile, or sRGB
    // in every fallback (srgb mode, Auto Color Management, HDR, a profile Qt
    // cannot use as a target).
    QColorSpace targetColorSpace() const;

    // Tests only: replace the Windows queries (DisplayColor.hpp) with
    // simulated monitors, and pretend the window is on `screenId`.
    void setProfileSourceForTesting(std::shared_ptr<spk::color::ProfileSource> source);
    void setScreenForTesting(const QString& screenId);

public slots:
    // Ask the OS about the window's monitor again now. Windows announces no
    // profile change, so this also runs after screen changes, display and
    // setting messages, application activation and on a 3 s poll.
    void reload();

signals:
    void changed();

protected:
    explicit ColorPipeline(QQuickWindow* window);

private:
    struct Impl;
    std::unique_ptr<Impl> d_;
};
