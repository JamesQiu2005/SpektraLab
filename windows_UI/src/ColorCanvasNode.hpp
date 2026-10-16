#pragma once
// The picture half of FrameCanvas's scene graph: the frame drawn through the
// display LUT of ColorPipeline.hpp.
//
// With an RHI (D3D11 by default) the frame is one or more textured quads with
// a custom material (shaders/colorcanvas.*): the frame keeps its own encoding
// in the texture (8-bit, or half float for RGBX16FPx4 and other deep images),
// is sampled as before (Nearest at or above 100 %, Linear below) and then
// goes through the LUT per screen pixel (with the contract's 1-D curves
// around the table when the LUT has them). Under the identity LUT an 8-bit
// frame is drawn by a bare texture read, exactly as Qt's texture node drew
// it. Images larger than the RHI's texture limit (16384 on D3D11) are split
// into tiles with a one-texel apron, so Linear filtering is continuous across
// a seam. One LUT texture per QRhi and LUT key is shared by every canvas of
// the window (the filmstrip has many).
//
// The software backend (QT_QUICK_BACKEND=software, and Qt's own choice on the
// offscreen platform: the self-test, offscreen captures) cannot run a custom
// material; there the frame goes through the same LUT on the CPU and is drawn
// by a plain texture node.
//
// Only the picture goes through the LUT. Letterbox, masks and guides are
// other items and keep their literal display values (AGENTS.md trap 27).
//
// Post-Dev (Layer 2, PostDev.hpp) runs between the sample and the LUT on
// both paths: shaders/postdev.glsl in every RHI variant but the bare copy,
// with the grade in the uniform block and its curves in a 256 x 5 float
// texture per canvas, and Grade::pixel in applyDisplayLutCpu. Each sample is
// graded at its place on the uncropped source (CanvasPaint::sourceMap). An
// identity or absent grade leaves every path exactly as it was.
#include "ColorPipeline.hpp"
#include "PostDevView.hpp"
#include <QImage>
#include <QRectF>
#include <QSGNode>
#include <QSize>
#include <array>
#include <memory>
#include <vector>

class QQuickWindow;
class QSGSimpleTextureNode;

// What one paint of a canvas needs. Filled by FrameCanvas::updatePaintNode on
// the render thread while the GUI thread is blocked.
struct CanvasPaint {
    QImage image;
    quint64 revision = 0;                 // changes whenever image does
    std::shared_ptr<const ColorLut> lut;  // never null; size 0 is identity
    bool dither = false;                  // ColorPipeline::dither()
    QRectF rect;                          // the image in item coordinates
    bool smooth = false;                  // Linear (below 100 %) or Nearest
    // Post-Dev: null, or an identity grade, is none. gradeRevision changes
    // whenever grade does; sourceMap places the image on the source.
    std::shared_ptr<const spk::desktop::postdev::Grade> grade;
    quint64 gradeRevision = 0;
    spk::desktop::postdev::SourceMap sourceMap;
    // The soft proof (ProofTransform.hpp): null, or the export transform the
    // picture goes through per pixel before `lut`, which is then the display
    // LUT for the recipe space. With one, `warning` (rgb a display value, a = 1
    // turns it on) is painted over every pixel the export cannot keep, after
    // the LUT and the dither -- never through the LUT (AGENTS.md trap 27).
    ProofTransformPtr proof;
    std::array<float, 4> warning{};
};

class ColorCanvasNode final : public QSGNode {
public:
    ColorCanvasNode();
    ~ColorCanvasNode() override;
    // False when the frame cannot be drawn (no texture); the caller deletes
    // the node and draws nothing, as the old QSGSimpleTextureNode path did.
    bool update(QQuickWindow* window, const CanvasPaint& paint);

    struct Tile;
    class CurveTable;
    class ProofTable;
private:
    bool updateRhi(QQuickWindow* window, const CanvasPaint& paint);
    bool updateSoftware(QQuickWindow* window, const CanvasPaint& paint);
    void clear();

    std::vector<std::unique_ptr<Tile>> tiles_;
    // The soft proof's C_max texture, for the transform it was made from.
    std::shared_ptr<ProofTable> proofTable_;
    quint64 revision_ = 0;
    int tileLimit_ = 0;
    QSize imageSize_;
    bool deep_ = false, alpha_ = false;
    QSGSimpleTextureNode* software_ = nullptr;
    quint64 softwareLut_ = 0;
    bool softwareLutActive_ = false, softwareDither_ = false;
    // Post-Dev: the curve texture every tile's material shares, and what the
    // software texture was graded with.
    std::shared_ptr<CurveTable> curves_;
    quint64 curvesRevision_ = ~quint64(0), softwareGrade_ = 0;
    spk::desktop::postdev::SourceMap softwareMap_;
    ProofTransformPtr softwareProof_;
    std::array<float, 4> softwareWarning_{};
};

// The CPU form of the shader, for the software backend: Post-Dev (`grade`,
// each pixel at `map` of its centre; null or identity: none), then trilinear
// lookup at the same nodes (inside the shaper and output curves when the LUT
// has them) -- or, with `proof`, the export transform per pixel and `lut` as
// the recipe space's display LUT (spk::color::sampleProof) -- the same clamps
// and dither, the gamut warning over what the export cannot keep (`warning`,
// as CanvasPaint's), rounded to 8 bits. An 8-bit image under the identity
// LUT, no grade and no proof is returned unchanged.
QImage applyDisplayLutCpu(const QImage& image, const ColorLut& lut, bool dither,
                          const spk::desktop::postdev::Grade* grade = nullptr,
                          const spk::desktop::postdev::SourceMap& map = {},
                          const ProofTransform* proof = nullptr, const std::array<float, 4>& warning = {});

// True when `lut` is a usable non-identity LUT (size >= 2, complete data,
// and complete curves if it has any).
bool displayLutActive(const ColorLut& lut);

namespace canvas_testing {
// Tests only: cap the tile size below the RHI's limit (0 restores it), and
// use the 2D atlas even where 3D textures exist. Both take effect at a
// canvas's next paint (call update() on it).
void setMaxTextureSize(int pixels);
void setForceLutAtlas(bool force);
// Tiles in the most recently built RHI node; 0 after a software paint.
int lastTileCount();
}
