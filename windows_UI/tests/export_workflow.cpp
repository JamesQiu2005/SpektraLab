// The export page through the real controller, engine and a RAW: recipe
// persistence across stores, sRGB byte-identity with the old export on a
// developed frame, EXIF from the camera file, a batch that holds the open
// frame and stops when asked, the existing-file policies end to end, the
// Digital Intermediate, and -- from a ProPhoto RGB session (Milestone B's
// working space) -- sRGB, Display P3, Adobe RGB and ProPhoto exports checked
// against an independent conversion of the frame's own pixels.
//
// Arguments as the other workflow tests: <resources> <RAW> <rejected-RAW>
// <new-output-directory>. The RAW is copied; nothing is written beside it.
#include "PreviewController.hpp"
#include "ExportRecipeStore.hpp"
#include "PostDev.hpp"
#include <QColorSpace>
#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <stdexcept>

namespace {
namespace recipes = spk::desktop::recipes;
int checks = 0;
void check(bool ok, const QString& what) { ++checks; if(!ok) throw std::runtime_error(what.toUtf8().toStdString()); }
std::filesystem::path native(const QString& p) { return std::filesystem::path(p.toStdWString()); }
void waitFor(const std::function<bool()>& condition, const QString& what, int ms = 240000) {
    if(condition()) return;
    QEventLoop loop; QTimer poll, deadline;
    poll.setInterval(10); deadline.setSingleShot(true);
    QObject::connect(&poll, &QTimer::timeout, &loop, [&] { if(condition()) loop.quit(); });
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    poll.start(); deadline.start(ms); loop.exec();
    check(condition(), "timed out waiting for " + what);
}
void idle(PreviewController& c, const QString& what) {
    waitFor([&] { return !c.busy() && !c.dirty() && !c.batchExporting() && c.pictureSettled(); }, what);
}
QByteArray readAll(const QString& path) { QFile f(path); check(f.open(QIODevice::ReadOnly), "read " + path); return f.readAll(); }
QByteArray sha(const QString& path) { return QCryptographicHash::hash(readAll(path), QCryptographicHash::Sha256).toHex(); }

// A recipe in the page's JSON, through the model so the shape is the real one.
recipes::Recipe recipe(recipes::Format format, const QString& space, const QString& folder, bool exif) {
    recipes::Recipe r; r.name = QStringLiteral("workflow"); r.format = format; r.colorSpace = space;
    r.besideOriginal = false; r.folder = folder; r.subfolder.clear();
    r.naming.tokens = {recipes::Token::originalName}; r.metadata.exif = exif;
    return r;
}
struct Result { QString summary; bool warning = false; QStringList files; bool done = false; };
Result run(PreviewController& c, const recipes::Recipe& r, const std::function<void()>& during = {}) {
    Result result;
    auto connection = QObject::connect(&c, &PreviewController::exportFinished, [&](const QString& s, bool w, const QStringList& f) {
        result.summary = s; result.warning = w; result.files = f; result.done = true;
    });
    c.exportWithRecipe(r.toJson().toVariantMap());
    check(c.batchExporting(), "the recipe export starts");
    if(during) during();
    waitFor([&] { return result.done && !c.busy(); }, "the recipe export");
    QObject::disconnect(connection);
    return result;
}
int leftovers(const QString& dir) {
    int n = 0;
    for(QDirIterator it(dir, {".spektralab-export-*", "*.partial*"}, QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot,
                        QDirIterator::Subdirectories); it.hasNext(); it.next()) ++n;
    return n;
}

// The 16-bit RGB pixels of a TIFF the writers produced (IFD0 strips).
struct TiffImage { int w = 0, h = 0, bits = 0; QByteArray icc; std::vector<std::uint16_t> rgb; std::uint32_t next = 0; };
TiffImage readTiff(const QString& path) {
    const QByteArray d = readAll(path);
    auto u16 = [&](qsizetype a) { return std::uint32_t(std::uint8_t(d[a]) | (std::uint8_t(d[a+1]) << 8)); };
    auto u32 = [&](qsizetype a) { return u16(a) | (u16(a+2) << 16); };
    check(d.startsWith("II"), "little-endian TIFF");
    const std::uint32_t at = u32(4);
    std::map<int, std::vector<std::uint32_t>> v; std::map<int, std::pair<std::uint32_t, std::uint32_t>> raw;
    const auto n = u16(at);
    for(std::uint32_t i = 0; i < n; ++i) {
        const qsizetype e = at + 2 + i*12;
        const int tag = int(u16(e)), type = int(u16(e+2)); const std::uint32_t count = u32(e+4);
        const int size = type == 3 ? 2 : type == 4 ? 4 : 1;
        const std::uint32_t bytes = count * size, where = bytes <= 4 ? std::uint32_t(e+8) : u32(e+8);
        raw[tag] = {where, bytes};
        for(std::uint32_t k = 0; k < count && (type == 3 || type == 4); ++k) v[tag].push_back(type == 3 ? u16(where + 2*k) : u32(where + 4*k));
    }
    TiffImage t; t.w = int(v[256][0]); t.h = int(v[257][0]); t.bits = int(v[258][0]); t.next = u32(at + 2 + n*12);
    if(raw.count(34675)) t.icc = d.mid(raw[34675].first, raw[34675].second);
    QByteArray all; for(std::size_t s = 0; s < v[273].size(); ++s) all += d.mid(v[273][s], v[279][s]);
    if(t.bits == 16) { t.rgb.resize(std::size_t(all.size()/2)); std::memcpy(t.rgb.data(), all.constData(), std::size_t(all.size()/2)*2); }
    return t;
}
// Independent colour science for the ProPhoto-session check (CIE values).
using M3 = std::array<double, 9>;
using V3 = std::array<double, 3>;
V3 mul(const M3& m, const V3& x) { return {m[0]*x[0]+m[1]*x[1]+m[2]*x[2], m[3]*x[0]+m[4]*x[1]+m[5]*x[2], m[6]*x[0]+m[7]*x[1]+m[8]*x[2]}; }
M3 mul(const M3& a, const M3& b) { M3 c{}; for(int i=0;i<3;++i) for(int j=0;j<3;++j) for(int k=0;k<3;++k) c[i*3+j] += a[i*3+k]*b[k*3+j]; return c; }
M3 inv(const M3& m) {
    const double d = m[0]*(m[4]*m[8]-m[5]*m[7]) - m[1]*(m[3]*m[8]-m[5]*m[6]) + m[2]*(m[3]*m[7]-m[4]*m[6]);
    return {(m[4]*m[8]-m[5]*m[7])/d, (m[2]*m[7]-m[1]*m[8])/d, (m[1]*m[5]-m[2]*m[4])/d, (m[5]*m[6]-m[3]*m[8])/d,
            (m[0]*m[8]-m[2]*m[6])/d, (m[2]*m[3]-m[0]*m[5])/d, (m[3]*m[7]-m[4]*m[6])/d, (m[1]*m[6]-m[0]*m[7])/d, (m[0]*m[4]-m[1]*m[3])/d};
}
V3 xyz(double x, double y) { return {x/y, 1, (1-x-y)/y}; }
M3 toXyz(const double p[8]) {
    const V3 r = xyz(p[0], p[1]), g = xyz(p[2], p[3]), b = xyz(p[4], p[5]), w = xyz(p[6], p[7]);
    const M3 m{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
    const V3 k = mul(inv(m), w);
    return {m[0]*k[0], m[1]*k[1], m[2]*k[2], m[3]*k[0], m[4]*k[1], m[5]*k[2], m[6]*k[0], m[7]*k[1], m[8]*k[2]};
}
M3 bradford(V3 from, V3 to) {
    const M3 b{0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    const V3 s = mul(b, from), d = mul(b, to);
    return mul(inv(b), mul(M3{d[0]/s[0], 0, 0, 0, d[1]/s[1], 0, 0, 0, d[2]/s[2]}, b));
}
double decodeRomm(double v) { return v < 16.0/512 ? v/16 : std::pow(v, 1.8); }
double encodeFor(double v, int curve) {
    v = std::clamp(v, 0.0, 1.0);
    if(curve == 0) return v <= 0.0031308 ? 12.92*v : 1.055*std::pow(v, 1/2.4) - 0.055;
    if(curve == 2) return std::pow(v, 256.0/563);
    return v < 1.0/512 ? 16*v : std::pow(v, 1/1.8);
}
}

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", QByteArray("offscreen"));
    QGuiApplication app(argc, argv);
    QJsonObject report;
    try {
        const auto args = app.arguments();
        if(args.size() != 5) throw std::runtime_error("usage: spk_qt_export_workflow_test <resources> <RAW> <rejected-RAW> <new-output-directory>");
        const auto resources = native(args[1]);
        const QString dest = QFileInfo(args[4]).absoluteFilePath();
        check(QFileInfo(args[2]).isFile() && !QFileInfo::exists(dest) && QDir().mkpath(dest + "/fixtures"), "fixtures and a new output directory");
        const QString suffix = QFileInfo(args[2]).suffix();
        QStringList photos;
        for(const char* n : {"alpha", "beta", "gamma"}) {
            photos.append(dest + "/fixtures/" + n + "." + suffix);
            check(QFile::copy(args[2], photos.last()), "copy the RAW");
        }
        QElapsedTimer clock; clock.start();
        {
            // An sRGB session, asked for by name since the working space
            // became ProPhoto RGB: the one place the old export's bytes are
            // pinned (the recipe's sRGB TIFF of an sRGB frame is the legacy
            // writer's file, byte for byte).
            PreviewController c(resources, nullptr, {}, dest + "/edits", QStringLiteral("sRGB"));
            waitFor([&] { return c.ready(); }, "engine");
            c.openFiles({QUrl::fromLocalFile(photos[0]), QUrl::fromLocalFile(photos[1]), QUrl::fromLocalFile(photos[2])});
            waitFor([&] { return c.hasFrame(); }, "first photo"); idle(c, "open");
            check(c.libraryItems().size() == 3 && c.selectedCount() == 3, "three photos, all selected");

            // ---- recipes persist across stores, beside app-settings.json ----
            const QString store = recipes::storePath(dest + "/edits");
            check(store == dest + "/edits/export-recipes.json", "store path inside the edit store, beside app-settings.json");
            {
                ExportRecipeStore a(store);
                check(QFileInfo::exists(store) && a.recipes().size() == 4, "seeded with the Mac's four defaults");
                a.add(); a.rename("Workflow"); a.setFormat(2); a.setColorSpace(1); a.setSubfolder("prints");
                a.toggleToken("date"); a.moveToken("date", "originalName"); a.setExisting(2); a.setLongEdge(2000);
                a.setMetadata("lens", false); a.setOpenWith("explorer"); a.setEmbedsPreview(true);
                ExportRecipeStore b(store);
                check(b.all() == a.all() && b.all().last().name == "Workflow" && b.all().last().naming.order.first() == recipes::Token::date &&
                      b.all().last().existing == recipes::Existing::skip && b.all().last().longEdge == 2000 && !b.all().last().metadata.lens,
                      "a recipe survives a new store");
                b.select(4); b.remove();
                ExportRecipeStore c2(store);
                check(c2.recipes().size() == 4, "deletion persists");
                for(int i = 0; i < 3; ++i) c2.remove();
                check(c2.recipes().size() == 1, "the last recipe cannot be deleted");
            }

            // ---- sRGB TIFF: byte-identical to the old export of this frame ----
            const int active = c.activeIndex();
            c.selectAllPhotos(false); c.setItemSelected(active, true);
            const QString legacy = dest + "/legacy.tif";
            c.exportImage(QUrl::fromLocalFile(legacy), 0, 95, 0); idle(c, "legacy export");
            const auto srgb = run(c, recipe(recipes::Format::tiff, recipes::kSRGB, dest + "/identity", false));
            check(srgb.files.size() == 1 && sha(srgb.files[0]) == sha(legacy), "recipe sRGB TIFF == old export, byte for byte");
            report["srgb_tiff_sha256"] = QString::fromLatin1(sha(legacy));

            // ---- EXIF from the camera file ----
            const auto jpeg = run(c, recipe(recipes::Format::jpeg, recipes::kDisplayP3, dest + "/exif", true));
            check(jpeg.files.size() == 1, "P3 JPEG written");
            const QByteArray bytes = readAll(jpeg.files[0]);
            const auto make = QByteArray::fromStdString(c.frame()->metadata.make), model = QByteArray::fromStdString(c.frame()->metadata.model);
            QImageReader reader(jpeg.files[0]); const QImage decoded = reader.read();
            check(bytes.contains(QByteArray("Exif\0\0", 6)) && !make.isEmpty() && bytes.contains(make) && bytes.contains(model) &&
                  decoded.colorSpace().description() == "Display P3" && decoded.width() == int(c.frame()->width()),
                  "EXIF (make, model) and the Display P3 profile in the JPEG");

            // ---- existing-file policies through the whole export ----
            auto policy = recipe(recipes::Format::png, recipes::kSRGB, dest + "/policy", false);
            policy.longEdge = 600;
            const auto first = run(c, policy), second = run(c, policy);
            check(first.files.size() == 1 && second.files.size() == 1 && QFileInfo(second.files[0]).completeBaseName() ==
                  QFileInfo(first.files[0]).completeBaseName() + "-1", "Add a suffix");
            const QByteArray kept = readAll(first.files[0]);
            policy.existing = recipes::Existing::skip;
            const auto skipped = run(c, policy);
            check(skipped.files.isEmpty() && skipped.warning && skipped.summary.contains("skipped") && readAll(first.files[0]) == kept, "Skip");
            policy.existing = recipes::Existing::overwrite; policy.longEdge = 500;
            const auto over = run(c, policy);
            check(over.files.value(0) == first.files[0] && QImageReader(first.files[0]).size().width() <= 500 &&
                  QDir(dest + "/policy").entryList(QDir::Files).size() == 2, "Overwrite replaces in place");

            // ---- the Digital Intermediate ----
            const auto di = run(c, recipe(recipes::Format::di, recipes::kDisplayP3, dest + "/di", true));
            check(di.files.size() == 3 && di.files[0].endsWith("_DI.tif") && di.files[1].endsWith(".cube") && di.files[2].endsWith(".cube"),
                  "DI TIFF and its two view LUTs: " + di.summary);
            const auto t = readTiff(di.files[0]);
            check(t.bits == 16 && t.icc.isEmpty() && t.next != 0 && t.w == int(c.frame()->width()), "DI: 16-bit, untagged, with its view page");
            report["di_note"] = di.summary;

            // ---- Film Edge: the file is the strip, the frame whole ----
            // With a film edge the engine was handed the picture cut by the
            // crop and rendered the film around it; the recipe writes that
            // frame with no geometry over it (Session.printGeometry), not the
            // picture inside the gate. sRGB TIFF: the frame's own 16-bit codes.
            {
                c.selectAllPhotos(false); c.setItemSelected(c.activeIndex(), true);
                check(c.setFilmEdgeActive(true), "switch the film edge on");
                idle(c, "develop on the film");
                const auto strip = c.frame();
                check(strip->cut && strip->width() > strip->picture_width && strip->height() > strip->picture_height,
                      "the frame is the film around the picture");
                const auto out = run(c, recipe(recipes::Format::tiff, recipes::kSRGB, dest + "/film-edge", false));
                check(out.files.size() == 1, "film edge TIFF written: " + out.summary);
                const auto t = readTiff(out.files[0]);
                check(t.w == int(strip->width()) && t.h == int(strip->height()) && t.bits == 16,
                      QStringLiteral("the file is the strip: %1 x %2 for a %3 x %4 frame")
                          .arg(t.w).arg(t.h).arg(strip->width()).arg(strip->height()));
                const auto& px = strip->pixels();
                bool same = t.rgb.size() == std::size_t(t.w) * t.h * 3;
                for(std::uint32_t y = 0; same && y < px.height; y += 97)
                    for(std::uint32_t x = 0; same && x < px.width; x += 89)
                        for(int k = 0; k < 3; ++k)
                            same = same && t.rgb[(std::size_t(y) * px.width + x) * 3 + k] ==
                                           px.rgba16[(std::size_t(y) * px.row_stride_px + x) * 4 + k];
                check(same, "the strip's pixels are the frame's, with no crop over them");
                report["film_edge_file"] = QStringLiteral("%1 x %2 strip around a %3 x %4 picture")
                    .arg(t.w).arg(t.h).arg(strip->picture_width).arg(strip->picture_height);
                check(c.setFilmEdgeActive(false), "switch the film edge off");
                idle(c, "develop without the film edge");
                check(!c.frame()->cut, "the photograph again");
            }

            // ---- a batch: holds the open frame, stops when asked ----
            c.selectAllPhotos(true);
            const auto shown = c.frame(); const int shownIndex = c.activeIndex();
            auto batch = recipe(recipes::Format::png, recipes::kSRGB, dest + "/batch", false);
            const auto stopped = run(c, batch, [&] {
                c.selectImage((shownIndex + 1) % 3);
                c.openRaw(QUrl::fromLocalFile(args[3]));
                check(c.activeIndex() == shownIndex && c.frame() == shown && c.libraryItems().size() == 3, "the batch holds the open frame");
                waitFor([&] { return c.batchProgress() >= 1; }, "the first file");
                c.cancelExport();
            });
            check(stopped.summary.contains("Stopped") && stopped.files.size() >= 1 && stopped.files.size() < 3 && stopped.warning,
                  "Stop ends the batch between photos: " + stopped.summary);
            check(leftovers(dest) == 0, "no staging files are left anywhere");
            check(c.activeIndex() == shownIndex, "the open photo is the one the person was on");
            const auto full = run(c, batch);
            check(full.files.size() == 3 - stopped.files.size() || full.files.size() == 3, "the rerun writes the rest (suffixed or new)");
            report["batch_stopped_summary"] = stopped.summary;
        }
        report["srgb_session_ms"] = double(clock.elapsed());

        // ---- the default session, ProPhoto RGB: every export converts once, correctly ----
        {
            PreviewController c(resources, nullptr, {}, dest + "/edits-prophoto");
            waitFor([&] { return c.ready(); }, "engine (ProPhoto)");
            c.openFiles({QUrl::fromLocalFile(photos[0])});
            waitFor([&] { return c.hasFrame(); }, "ProPhoto photo"); idle(c, "open");
            const auto frame = c.frame();
            check(frame->encoding.color_space == "ProPhoto RGB" && frame->encoding.cctf_encoding,
                  "the default session renders the working space, encoded ProPhoto RGB");
            const auto& px = frame->pixels();

            // The legacy single export (Export… without a recipe) writes sRGB.icc:
            // it must convert the working space once, as the recipe does --
            // byte for byte the recipe's sRGB TIFF -- and never write the
            // frame's ProPhoto codes under an sRGB tag.
            {
                const QString legacy = dest + "/prophoto-legacy.tif";
                c.exportImage(QUrl::fromLocalFile(legacy), 0, 95, 0); idle(c, "legacy export (ProPhoto)");
                check(QFileInfo(legacy).size() > 0, "legacy export of a ProPhoto frame written: " + c.status());
                const auto viaRecipe = run(c, recipe(recipes::Format::tiff, recipes::kSRGB, dest + "/prophoto-legacy-recipe", false));
                check(viaRecipe.files.size() == 1 && sha(viaRecipe.files[0]) == sha(legacy),
                      "ProPhoto session: legacy TIFF == recipe sRGB TIFF, byte for byte");
                const auto t = readTiff(legacy);
                int same = 0, samples = 0;
                for(std::uint32_t y = 5; y < px.height; y += 61) for(std::uint32_t x = 9; x < px.width; x += 57) {
                    const std::uint16_t* s = px.rgba16 + (std::size_t(y)*px.row_stride_px + x)*4;
                    const std::uint16_t* f = t.rgb.data() + (std::size_t(y)*t.w + x)*3;
                    ++samples; same += s[0] == f[0] && s[1] == f[1] && s[2] == f[2];
                }
                check(QColorSpace::fromIccProfile(t.icc).description().contains("sRGB") && same < samples / 10,
                      QStringLiteral("the legacy sRGB file carries converted codes (%1 of %2 samples equal the ProPhoto frame's)").arg(same).arg(samples));
                report["prophoto_legacy_equal_codes"] = double(same) / samples;
            }
            // Post-Dev in the working space: the graded ProPhoto file (an
            // identity conversion) is Grade(params, ProPhoto's pivot 0.3857 --
            // the Mac's) applied to the frame's own codes, and not the grade at
            // sRGB's pivot.
            {
                check(c.setPostDev("exposure", 0.7) && c.setPostDev("contrast", 25), "grade the ProPhoto photo");
                idle(c, "grade");
                const auto out = run(c, recipe(recipes::Format::tiff, "kCGColorSpaceROMMRGB", dest + "/prophoto-graded", false));
                check(out.files.size() == 1, "graded ProPhoto TIFF written");
                const auto t = readTiff(out.files[0]);
                namespace postdev = spk::desktop::postdev;
                const auto params = c.postDevParams();
                const postdev::Grade atProPhoto(params, postdev::proPhotoMidGrey), atSrgb(params, postdev::srgbMidGrey);
                double worstPro = 0, worstSrgb = 0; int n = 0;
                for(std::uint32_t y = 13; y < px.height; y += 71) for(std::uint32_t x = 17; x < px.width; x += 67) {
                    const std::uint16_t* s = px.rgba16 + (std::size_t(y)*px.row_stride_px + x)*4;
                    const std::uint16_t* f = t.rgb.data() + (std::size_t(y)*t.w + x)*3;
                    const float u = (x + 0.5f) / px.width, v = (y + 0.5f) / px.height;
                    const auto a = atProPhoto.pixel({s[0]/65535.0f, s[1]/65535.0f, s[2]/65535.0f}, u, v);
                    const auto b = atSrgb.pixel({s[0]/65535.0f, s[1]/65535.0f, s[2]/65535.0f}, u, v);
                    for(int k = 0; k < 3; ++k) {
                        worstPro = std::max(worstPro, std::abs(f[k]/65535.0 - std::clamp(double(a[k]), 0.0, 1.0)));
                        worstSrgb = std::max(worstSrgb, std::abs(f[k]/65535.0 - std::clamp(double(b[k]), 0.0, 1.0)));
                    }
                    ++n;
                }
                report["postdev_prophoto_pivot_max_error"] = worstPro; report["postdev_srgb_pivot_max_error"] = worstSrgb;
                check(n > 100 && worstPro < 2.0 / 65535 + 1e-6 && worstSrgb > 0.01,
                      QStringLiteral("ProPhoto Post-Dev grades at ProPhoto's pivot: %1 against %2 at sRGB's").arg(worstPro).arg(worstSrgb));
                c.resetPostDev({}); idle(c, "ungrade");
            }
            const double romm[8] = {0.7347, 0.2653, 0.1596, 0.8404, 0.0366, 0.0001, 0.3457, 0.3585};
            struct Target { const char* key; const char* name; double p[8]; int curve; };
            const Target targets[] = {
                {"kCGColorSpaceSRGB", "sRGB", {0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290}, 0},
                {"kCGColorSpaceDisplayP3", "Display P3", {0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290}, 0},
                {"kCGColorSpaceAdobeRGB1998", "Adobe RGB (1998)", {0.64, 0.33, 0.21, 0.71, 0.15, 0.06, 0.3127, 0.3290}, 2},
                {"kCGColorSpaceROMMRGB", "ROMM RGB (ProPhoto)", {0.7347, 0.2653, 0.1596, 0.8404, 0.0366, 0.0001, 0.3457, 0.3585}, 1}};
            QJsonObject prophoto;
            for(const auto& target : targets) {
                const auto out = run(c, recipe(recipes::Format::tiff, target.key, dest + "/prophoto/" + QString(target.key).mid(12), false));
                check(out.files.size() == 1, QStringLiteral("ProPhoto session -> %1 written").arg(target.name));
                const auto t = readTiff(out.files[0]);
                check(t.w == int(px.width) && t.h == int(px.height), "full size");
                const QColorSpace tag = QColorSpace::fromIccProfile(t.icc);
                check(tag.isValid() && (QString(target.name) == "sRGB" ? tag.description().contains("sRGB") : tag.description() == target.name),
                      QStringLiteral("tagged %1").arg(target.name));
                const M3 m = mul(inv(toXyz(target.p)), mul(bradford(xyz(romm[6], romm[7]), xyz(target.p[6], target.p[7])), toXyz(romm)));
                double worst = 0, sum = 0; int n = 0, identical = 0, samples = 0;
                for(std::uint32_t y = 7; y < px.height; y += 53) for(std::uint32_t x = 11; x < px.width; x += 47) {
                    const std::uint16_t* s = px.rgba16 + (std::size_t(y)*px.row_stride_px + x)*4;
                    const std::uint16_t* f = t.rgb.data() + (std::size_t(y)*t.w + x)*3;
                    ++samples; identical += s[0] == f[0] && s[1] == f[1] && s[2] == f[2];
                    const V3 lin{decodeRomm(s[0]/65535.0), decodeRomm(s[1]/65535.0), decodeRomm(s[2]/65535.0)};
                    const V3 want = mul(m, lin);
                    // Near-neutral, inside the destination with margin: where the
                    // chroma knee has nothing to do.
                    const double hi = std::max({want[0], want[1], want[2]}), lo = std::min({want[0], want[1], want[2]});
                    if(lo < 0.01 || hi > 0.85 || hi - lo > 0.12 * hi) continue;
                    double e = 0;
                    for(int k = 0; k < 3; ++k) e = std::max(e, std::abs(f[k]/65535.0 - encodeFor(want[k], target.curve)));
                    worst = std::max(worst, e); sum += e; ++n;
                }
                if(QString(target.name).startsWith("ROMM"))
                    check(identical == samples, "ProPhoto to ProPhoto: the frame's own codes");
                check(n > 100 && worst < 0.006, QStringLiteral("ProPhoto session -> %1: %2 near-neutral samples, max error %3").arg(target.name).arg(n).arg(worst));
                prophoto[target.name] = QJsonObject{{"samples", n}, {"max_code_error", worst}, {"mean_code_error", n ? sum/n : 0},
                                                    {"identical_fraction", double(identical)/samples}};
            }
            report["prophoto_session"] = prophoto;
        }
        report["checks"] = checks; report["passed"] = true;
        QFile out(dest + "/report.json"); if(out.open(QIODevice::WriteOnly)) out.write(QJsonDocument(report).toJson());
        std::printf("%s\nspk_qt_export_workflow: %d checks passed\n", QJsonDocument(report).toJson().constData(), checks);
        return 0;
    } catch(const std::exception& e) {
        std::fprintf(stderr, "FAILED after %d checks: %s\n", checks, e.what());
        return 1;
    }
}
