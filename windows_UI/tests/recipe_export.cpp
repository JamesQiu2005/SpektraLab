// The export page's model and writer without a RAW: recipes (the Mac's JSON,
// naming tokens, destinations, persistence), the existing-file policies
// against real files, sRGB byte-identity with the old writer (pinned by
// SHA-256), and every export colour space against an independent conversion
// (CIE primaries and transfer functions written out here, not the engine's
// or Qt's), read back through the file's own embedded ICC profile -- from an
// sRGB session (today) and from a ProPhoto RGB one (Milestone B), including
// colours outside the destination's gamut.
//
// Arguments: <resources> <new scratch directory> [RAW] -- with a RAW (a copy;
// the test never writes beside it) the EXIF block is checked against LibRaw.
#include "ExportRecipe.hpp"
#include "FrameImage.hpp"
#include "FrameOutput.hpp"
#include "RecipeExport.hpp"
#include "output.hpp"
#include "image_io.hpp"
#include "spektrafilm/spk_engine.h"
#include <QBuffer>
#include <QColorSpace>
#include <QColorTransform>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QtGui/qrgbafloat.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <stdexcept>

namespace {
namespace fs = std::filesystem;
namespace recipes = spk::desktop::recipes;
namespace exporting = spk::desktop::exporting;
namespace output = spk::desktop::output;
using recipes::Format;

int checks = 0;
void check(bool ok, const QString& what) {
    ++checks;
    if(!ok) throw std::runtime_error(what.toUtf8().toStdString());
}
fs::path native(const QString& p) { return fs::path(p.toStdWString()); }
QByteArray readAll(const QString& path) {
    QFile f(path);
    check(f.open(QIODevice::ReadOnly), "cannot read " + path);
    return f.readAll();
}
QString sha256(const QString& path) { return QCryptographicHash::hash(readAll(path), QCryptographicHash::Sha256).toHex(); }

// --- independent colour science ---------------------------------------------
struct Space { const char* engine; double r[2], g[2], b[2], w[2]; int curve; };
// curve: 0 sRGB, 1 ProPhoto (ROMM, 1/512 toe), 2 Adobe 563/256, 3 BT.2020/709
const Space kSpaces[] = {
    {"sRGB", {0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, {0.3127, 0.3290}, 0},
    {"Display P3", {0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}, {0.3127, 0.3290}, 0},
    {"Adobe RGB (1998)", {0.64, 0.33}, {0.21, 0.71}, {0.15, 0.06}, {0.3127, 0.3290}, 2},
    {"ProPhoto RGB", {0.7347, 0.2653}, {0.1596, 0.8404}, {0.0366, 0.0001}, {0.3457, 0.3585}, 1},
    {"ITU-R BT.2020", {0.708, 0.292}, {0.170, 0.797}, {0.131, 0.046}, {0.3127, 0.3290}, 3},
};
const Space& spaceOf(const std::string& name) {
    for(const auto& s : kSpaces) if(name == s.engine) return s;
    throw std::runtime_error("no reference for " + name);
}
using M3 = std::array<double, 9>;
using V3 = std::array<double, 3>;
V3 mul(const M3& m, const V3& v) {
    return {m[0]*v[0]+m[1]*v[1]+m[2]*v[2], m[3]*v[0]+m[4]*v[1]+m[5]*v[2], m[6]*v[0]+m[7]*v[1]+m[8]*v[2]};
}
M3 mul(const M3& a, const M3& b) {
    M3 c{};
    for(int i = 0; i < 3; ++i) for(int j = 0; j < 3; ++j) for(int k = 0; k < 3; ++k) c[i*3+j] += a[i*3+k]*b[k*3+j];
    return c;
}
M3 inverse(const M3& m) {
    const double d = m[0]*(m[4]*m[8]-m[5]*m[7]) - m[1]*(m[3]*m[8]-m[5]*m[6]) + m[2]*(m[3]*m[7]-m[4]*m[6]);
    return {(m[4]*m[8]-m[5]*m[7])/d, (m[2]*m[7]-m[1]*m[8])/d, (m[1]*m[5]-m[2]*m[4])/d,
            (m[5]*m[6]-m[3]*m[8])/d, (m[0]*m[8]-m[2]*m[6])/d, (m[2]*m[3]-m[0]*m[5])/d,
            (m[3]*m[7]-m[4]*m[6])/d, (m[1]*m[6]-m[0]*m[7])/d, (m[0]*m[4]-m[1]*m[3])/d};
}
V3 xyzOf(const double xy[2]) { return {xy[0]/xy[1], 1.0, (1-xy[0]-xy[1])/xy[1]}; }
M3 toXyz(const Space& s) {   // linear RGB -> XYZ at the space's own white
    const V3 r = xyzOf(s.r), g = xyzOf(s.g), b = xyzOf(s.b), w = xyzOf(s.w);
    const M3 p{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
    const V3 k = mul(inverse(p), w);
    return {p[0]*k[0], p[1]*k[1], p[2]*k[2], p[3]*k[0], p[4]*k[1], p[5]*k[2], p[6]*k[0], p[7]*k[1], p[8]*k[2]};
}
M3 bradford(const double from[2], const double to[2]) {
    const M3 b{0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    const V3 s = mul(b, xyzOf(from)), d = mul(b, xyzOf(to));
    const M3 scale{d[0]/s[0], 0, 0, 0, d[1]/s[1], 0, 0, 0, d[2]/s[2]};
    return mul(inverse(b), mul(scale, b));
}
M3 rgbToRgb(const Space& from, const Space& to) {
    return mul(inverse(toXyz(to)), mul(bradford(from.w, to.w), toXyz(from)));
}
double decode(double v, int curve) {
    switch(curve) {
    case 0: return v <= 0.04045 ? v/12.92 : std::pow((v+0.055)/1.055, 2.4);
    case 1: return v < 16.0/512 ? v/16 : std::pow(v, 1.8);
    case 2: return std::pow(v, 563.0/256);
    default: return v < 0.081 ? v/4.5 : std::pow((v+0.099)/1.099, 1/0.45);
    }
}
double encode(double v, int curve) {
    v = std::clamp(v, 0.0, 1.0);
    switch(curve) {
    case 0: return v <= 0.0031308 ? 12.92*v : 1.055*std::pow(v, 1/2.4)-0.055;
    case 1: return v < 1.0/512 ? 16*v : std::pow(v, 1/1.8);
    case 2: return std::pow(v, 256.0/563);
    default: return v < 0.018 ? 4.5*v : 1.099*std::pow(v, 0.45)-0.099;
    }
}
// CIE L*a*b* (D50) for hue checks.
V3 lab(const V3& xyzD50) {
    const double w[3] = {0.9642, 1.0, 0.8249};
    auto f = [](double t) { return t > 216.0/24389 ? std::cbrt(t) : (24389.0/27*t+16)/116; };
    const double fx = f(xyzD50[0]/w[0]), fy = f(xyzD50[1]/w[1]), fz = f(xyzD50[2]/w[2]);
    return {116*fy-16, 500*(fx-fy), 200*(fy-fz)};
}
V3 toD50(const Space& s, const V3& linear) {
    const double d50[2] = {0.3457, 0.3585};
    return mul(mul(bradford(s.w, d50), toXyz(s)), linear);
}
double deltaE(const V3& a, const V3& b) { return std::sqrt((a[0]-b[0])*(a[0]-b[0])+(a[1]-b[1])*(a[1]-b[1])+(a[2]-b[2])*(a[2]-b[2])); }

// --- a reader for the TIFF-structured blocks the writers produce -----------
struct Tiff {
    QByteArray data;
    std::map<int, std::pair<qsizetype, qsizetype>> tags;   // tag -> (value offset, byte count)
    std::map<int, std::vector<std::uint32_t>> values;
    std::uint32_t next = 0;
    std::uint32_t u16(qsizetype at) const { return std::uint8_t(data[at]) | (std::uint8_t(data[at+1]) << 8); }
    std::uint32_t u32(qsizetype at) const { return u16(at) | (u16(at+2) << 16); }
    void parse(std::uint32_t at) {
        check(data.size() >= 8 && data.left(2) == "II", "not a little-endian TIFF block");
        const auto n = u16(at);
        for(std::uint32_t i = 0; i < n; ++i) {
            const qsizetype e = at + 2 + i*12;
            const int tag = int(u16(e)), type = int(u16(e+2));
            const std::uint32_t count = u32(e+4);
            const int size = type == 3 ? 2 : type == 4 ? 4 : type == 5 ? 8 : 1;
            const qsizetype bytes = qsizetype(count) * size;
            const qsizetype where = bytes <= 4 ? e+8 : qsizetype(u32(e+8));
            tags[tag] = {where, bytes};
            std::vector<std::uint32_t> v;
            if(type == 3) for(std::uint32_t k = 0; k < count; ++k) v.push_back(u16(where + 2*k));
            if(type == 4) for(std::uint32_t k = 0; k < count; ++k) v.push_back(u32(where + 4*k));
            if(type == 5) for(std::uint32_t k = 0; k < count*2; ++k) v.push_back(u32(where + 4*k));
            values[tag] = v;
        }
        next = u32(at + 2 + n*12);
    }
    QByteArray raw(int tag) const {
        const auto it = tags.find(tag);
        return it == tags.end() ? QByteArray() : data.mid(it->second.first, it->second.second);
    }
    QString ascii(int tag) const { auto r = raw(tag); if(r.endsWith('\0')) r.chop(1); return QString::fromLatin1(r); }
};
Tiff tiffAt(const QByteArray& data, std::uint32_t at) { Tiff t; t.data = data; t.parse(at); return t; }
Tiff tiffFile(const QString& path) { const auto d = readAll(path); Tiff t; t.data = d; t.parse(t.u32(4)); return t; }
// Pixels of a 16-bit RGB TIFF page as linear-free code values 0..1.
std::vector<double> tiffPixels(const Tiff& t, int& w, int& h) {
    w = int(t.values.at(256)[0]); h = int(t.values.at(257)[0]);
    const int bits = int(t.values.at(258)[0]);
    std::vector<double> out(std::size_t(w)*h*3);
    const auto& offsets = t.values.at(273);
    const auto& counts = t.values.at(279);
    QByteArray all;
    for(std::size_t s = 0; s < offsets.size(); ++s) all += t.data.mid(offsets[s], counts[s]);
    for(std::size_t i = 0; i < out.size(); ++i)
        out[i] = bits == 16 ? (std::uint8_t(all[2*i]) | (std::uint8_t(all[2*i+1]) << 8))/65535.0 : std::uint8_t(all[i])/255.0;
    return out;
}
// The EXIF block of a JPEG (APP1) or PNG (eXIf); empty when there is none.
QByteArray exifBlockOf(const QByteArray& file) {
    if(file.startsWith("\xFF\xD8")) {
        qsizetype at = 2;
        while(at + 4 < file.size() && std::uint8_t(file[at]) == 0xFF) {
            const int marker = std::uint8_t(file[at+1]);
            const int len = (std::uint8_t(file[at+2]) << 8) | std::uint8_t(file[at+3]);
            if(marker == 0xE1 && file.mid(at+4, 6) == QByteArray("Exif\0\0", 6)) return file.mid(at+10, len-8);
            if(marker == 0xDA) break;
            at += 2 + len;
        }
    } else if(file.startsWith("\x89PNG")) {
        qsizetype at = 8;
        while(at + 8 <= file.size()) {
            const std::uint32_t len = (std::uint32_t(std::uint8_t(file[at])) << 24) | (std::uint8_t(file[at+1]) << 16) |
                                      (std::uint8_t(file[at+2]) << 8) | std::uint8_t(file[at+3]);
            if(file.mid(at+4, 4) == "eXIf") return file.mid(at+8, len);
            at += 12 + len;
        }
    }
    return {};
}

// --- the synthetic frame ------------------------------------------------------
// Patches 32 x 32, in linear light of `space`; returned encoded in it, RGBA64.
QImage patchFrame(const std::vector<V3>& linear, const Space& space) {
    QImage img(int(linear.size())*32, 32, QImage::Format_RGBA64);
    for(int y = 0; y < 32; ++y) {
        auto* row = reinterpret_cast<std::uint16_t*>(img.scanLine(y));
        for(int x = 0; x < img.width(); ++x) {
            const auto& c = linear[std::size_t(x/32)];
            for(int k = 0; k < 3; ++k) row[4*x+k] = std::uint16_t(std::lround(encode(c[k], space.curve)*65535));
            row[4*x+3] = 65535;
        }
    }
    return img;
}
// A busy deterministic frame for byte-identity: gradients and a ripple.
QImage busyFrame(int w, int h) {
    QImage img(w, h, QImage::Format_RGBA64);
    for(int y = 0; y < h; ++y) {
        auto* row = reinterpret_cast<std::uint16_t*>(img.scanLine(y));
        for(int x = 0; x < w; ++x) {
            row[4*x] = std::uint16_t((x*65535)/(w-1));
            row[4*x+1] = std::uint16_t((y*65535)/(h-1));
            row[4*x+2] = std::uint16_t(32767.5 + 32767.5*std::sin(x*0.13)*std::cos(y*0.07));
            row[4*x+3] = 65535;
        }
    }
    return img;
}

// Back through the file's embedded profile to linear light of `reference`:
// the round trip that proves pixels and tag agree.
V3 throughProfile(const QColorSpace& embedded, const QColorSpace& linearReference, const double rgb[3]) {
    const QColorTransform t = embedded.transformationToColorSpace(linearReference);
    QRgbaFloat32 in{float(rgb[0]), float(rgb[1]), float(rgb[2]), 1.0f};
    const QRgbaFloat32 out = t.map(in);
    return {out.r, out.g, out.b};
}

QJsonObject report;
}

int main(int argc, char** argv) {
    QGuiApplication app(argc, argv);
    try {
        const auto args = app.arguments();
        if(args.size() < 3) throw std::runtime_error("usage: spk_qt_recipe_export_test <resources> <new-scratch-dir> [RAW]");
        const QString resourcesText = args[1];
        const fs::path resources = native(resourcesText);
        const QString scratch = QFileInfo(args[2]).absoluteFilePath();
        QDir(scratch).removeRecursively();
        check(QDir().mkpath(scratch), "cannot create the scratch directory");

        // ---------------- naming ----------------
        {
            recipes::Naming n;
            recipes::NameContext c{QStringLiteral("_DSC4037"), QStringLiteral("kodak_portra_400"),
                                   QStringLiteral("kodak_portra_endura"), QDate(2026, 10, 16)};
            check(n.stem(c) == "_DSC4037_kodak_portra_400_kodak_portra_endura", "default stem: " + n.stem(c));
            n.toggle(recipes::Token::date);
            check(n.stem(c) == "_DSC4037_kodak_portra_400_kodak_portra_endura_20261016", "date token: " + n.stem(c));
            n.move(recipes::Token::date, recipes::Token::originalName);
            check(n.stem(c) == "20261016__DSC4037_kodak_portra_400_kodak_portra_endura", "dragged order: " + n.stem(c));
            check(n.order.first() == recipes::Token::date, "order follows the drag");
            for(auto t : recipes::kAllTokens) n.toggle(t);   // all off but the last refuses
            check(n.tokens.size() == 1, "the last token cannot be switched off");
            n = recipes::Naming(); n.tokens = {recipes::Token::filmStock, recipes::Token::printStock};
            recipes::NameContext empty{QStringLiteral("frame"), {}, {}, QDate(2026, 1, 2)};
            check(n.stem(empty) == "frame", "an empty rule falls back to the original name");
            recipes::NameContext bad{QStringLiteral("a"), QStringLiteral("x/y:z*?"), QStringLiteral("p<q>|\""), {}};
            check(n.stem(bad) == "x-y-z--_p-q---", "path characters are replaced: " + n.stem(bad));
            n.separator = QStringLiteral(" - ");
            check(n.stem(c) == "kodak_portra_400 - kodak_portra_endura", "separator");
        }

        // ---------------- the Mac's JSON ----------------
        {
            const QByteArray mac = R"([{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"DI package","format":"DI package",
                "colorSpace":{"builtIn":{"_0":"kCGColorSpaceROMMRGB"}},"folder":{"fixed":{"path":"D:/Exports"}},
                "subfolder":"  ","naming":{"order":["date","counter","printStock"],"tokens":["counter","date"],"separator":"-"},
                "existing":"skip","quality":0.8,"outputSize":{"custom":{"width":1200,"height":3000}},
                "openWith":{"path":"C:/Apps/viewer.exe"},"embedsPreview":true},
                {"name":"bare"}])";
            const QString file = scratch + "/mac-recipes.json";
            QFile f(file); check(f.open(QIODevice::WriteOnly) && f.write(mac) == mac.size(), "write mac json"); f.close();
            const auto loaded = recipes::load(file);
            check(loaded.problem.isEmpty() && loaded.recipes.size() == 2, "the Mac's file reads: " + loaded.problem);
            const auto& a = loaded.recipes[0];
            check(a.id == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F" && a.name == recipes::kDigitalIntermediateName &&
                  a.format == Format::di && a.colorSpace == "kCGColorSpaceROMMRGB" && !a.besideOriginal &&
                  a.folder == "D:/Exports" && a.existing == recipes::Existing::skip && std::abs(a.quality-0.8) < 1e-12 &&
                  a.longEdge == 3000 && a.openWith == "C:/Apps/viewer.exe" && a.embedsPreview, "Mac fields");
            check(a.naming.order == QList<recipes::Token>({recipes::Token::date, recipes::Token::printStock,
                  recipes::Token::originalName, recipes::Token::filmStock}) && a.naming.tokens == QList<recipes::Token>{recipes::Token::date},
                  "unknown tokens drop, missing ones keep their place");
            check(a.directory("C:/photos/x.nef") == "D:/Exports", "a blank subfolder is none");
            check(a.destinationPath("C:/photos/x.nef", "x") == "D:/Exports/x_DI.tif", "a DI is <stem>_DI.tif");
            const auto& b = loaded.recipes[1];
            check(b.name == "bare" && b.format == Format::jpeg && b.colorSpace == recipes::kDisplayP3 && b.besideOriginal &&
                  b.subfolder == "_prints" && b.longEdge == 0 && b.openWith.isEmpty() && b.metadata.exif, "lenient defaults");
            // A round trip is exact, and writes the Mac's shapes.
            const QString again = scratch + "/again.json";
            check(recipes::save(again, loaded.recipes).isEmpty(), "save");
            const auto back = recipes::load(again);
            check(back.recipes == loaded.recipes, "round trip");
            const auto doc = QJsonDocument::fromJson(readAll(again)).array();
            check(doc[0].toObject()["colorSpace"].toObject()["builtIn"].toObject()["_0"].toString() == "kCGColorSpaceROMMRGB" &&
                  doc[0].toObject()["outputSize"].toObject()["longEdge"].toInt() == 3000 &&
                  doc[1].toObject()["folder"].toObject().contains("besideOriginal") &&
                  doc[1].toObject()["outputSize"].toObject()["original"].toBool(), "the Mac's JSON shapes");
            // Unreadable: defaults, a problem, and the file untouched.
            const QString broken = scratch + "/broken.json";
            QFile g(broken); check(g.open(QIODevice::WriteOnly) && g.write("[{not json") > 0, "write broken"); g.close();
            const auto before = readAll(broken);
            const auto bad = recipes::load(broken);
            check(!bad.problem.isEmpty() && bad.recipes.size() == recipes::defaults().size() && readAll(broken) == before,
                  "an unreadable file falls back and is left alone");
            check(recipes::defaults()[1].colorSpace == "kCGColorSpaceROMMRGB" && recipes::defaults()[3].format == Format::di,
                  "the Mac's four default recipes");
            check(recipes::storePath(scratch + "/edits") == scratch + "/export-recipes.json", "store beside the edit store");
        }

        // ---------------- existing-file policies, against real files ----------------
        {
            const QString dir = scratch + "/policy";
            recipes::Recipe r; r.format = Format::png; r.colorSpace = recipes::kSRGB; r.besideOriginal = false;
            r.folder = dir; r.subfolder = QStringLiteral("_prints"); r.naming.tokens = {recipes::Token::originalName};
            r.metadata.exif = false;
            const QString source = scratch + "/photo.nef";
            recipes::NameContext c{QStringLiteral("photo"), {}, {}, QDate(2026, 1, 1)};
            check(QDir().mkpath(r.directory(source)), "mkpath");
            const QImage pixels = busyFrame(64, 40);
            auto write = [&](const recipes::Recipe& recipe) -> std::optional<QString> {
                auto dest = recipes::resolveDestination(recipe, source, c, [](const QString& p) { return QFileInfo::exists(p); });
                if(!dest) return std::nullopt;
                exporting::WriteOptions o; o.format = recipe.format; o.overwrite = recipe.existing == recipes::Existing::overwrite;
                const auto result = exporting::writeImage(pixels, "sRGB", native(*dest), o, resources);
                check(result == exporting::Published::written, "write under " + recipes::existingRaw(recipe.existing));
                return dest;
            };
            const auto first = write(r);
            check(first && QFileInfo(*first).fileName() == "photo.png", "first name");
            const auto second = write(r), third = write(r);
            check(second && QFileInfo(*second).fileName() == "photo-1.png" && third && QFileInfo(*third).fileName() == "photo-2.png",
                  "Add a suffix: -1, -2");
            // Skip: nothing written, the file untouched.
            const QByteArray kept = readAll(*first);
            recipes::Recipe skip = r; skip.existing = recipes::Existing::skip;
            check(!write(skip) && readAll(*first) == kept, "Skip leaves the file alone");
            // Never clobber unless overwriting: the writer itself refuses.
            exporting::WriteOptions o; o.format = Format::png;
            check(exporting::writeImage(busyFrame(8, 8), "sRGB", native(*first), o, resources) == exporting::Published::exists &&
                  readAll(*first) == kept, "the writer never replaces without Overwrite");
            // Overwrite: replaced, in one move.
            recipes::Recipe over = r; over.existing = recipes::Existing::overwrite;
            o.overwrite = true;
            check(exporting::writeImage(busyFrame(8, 8), "sRGB", native(*first), o, resources) == exporting::Published::written &&
                  readAll(*first) != kept && QImageReader(*first).size() == QSize(8, 8), "Overwrite replaces");
            // No staging directory or partial file is left behind.
            int leftovers = 0;
            for(QDirIterator it(r.directory(source), QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot); it.hasNext(); it.next()) ++leftovers;
            check(leftovers == 3, "only the three files remain");
        }

        // ---------------- sRGB byte-identity with the old writer ----------------
        QJsonObject hashes;
        {
            const QImage frame = busyFrame(301, 203);
            const output::Geometry geometry{QRectF(0.1, 0.05, 0.8, 0.9), 1, true, false, 0};
            struct Case { output::Format legacy; Format recipe; const char* ext; int edge; };
            for(const Case k : {Case{output::Format::TIFF16, Format::tiff, "tif", 0}, Case{output::Format::PNG8, Format::png, "png", 0},
                                Case{output::Format::JPEG8, Format::jpeg, "jpg", 0}, Case{output::Format::TIFF16, Format::tiff, "tif", 120},
                                Case{output::Format::JPEG8, Format::jpeg, "jpg", 150}}) {
                const QString tag = QStringLiteral("%1-%2").arg(k.ext).arg(k.edge);
                const QString old = scratch + "/identity-old-" + tag + "." + k.ext;
                output::exportImageFile(frame, native(old), geometry, {k.legacy, 95, k.edge}, resources);
                // The recipe path: frame, size, (identity) convert, write.
                output::ExportOptions o; o.format = output::Format::TIFF16; o.maxLongEdge = k.edge;
                const QImage framed = output::exportImage(frame, geometry, o);
                const auto converted = exporting::convert(framed, {"sRGB", true}, "sRGB", nullptr);
                check(converted.identity, "same space is no conversion");
                exporting::WriteOptions w; w.format = k.recipe; w.jpegQuality = 95;
                const QString now = scratch + "/identity-new-" + tag + "." + k.ext;
                check(exporting::writeImage(converted.rgba64, "sRGB", native(now), w, resources) == exporting::Published::written, "write");
                check(readAll(old) == readAll(now), "sRGB export is byte-identical to the old writer: " + tag);
                hashes[tag] = sha256(now);
            }
            // Pinned: today's bytes, captured from the unchanged old writer.
            const QJsonObject pinned{
                {"tif-0", "6a0d8090baf39c0985b7f3e8a3ac43b8dcdf9127b49bbefd2133b95c33a5af72"},
                {"png-0", "4b8261bafbe1ebe8b3b90a1811cf445544958e6d5068516c829152ee89fbe82e"},
                {"jpg-0", "748cf69117f7065bb7813b1fd78ceede76e3c2032418c43c347121eaba451830"},
                {"tif-120", "f782ce313ad776b6c5d173ef267a9e63dadbfc7df8616a528687ea79519cd869"},
                {"jpg-150", "33c8596d2515b2737f04ba6d09aaa411a4b21270bd6650f6dabe3b742b8a4aeb"}};
            for(auto it = pinned.begin(); it != pinned.end(); ++it)
                    check(hashes[it.key()].toString() == it.value().toString(), "pinned SHA-256 for " + it.key());
            report["srgb_identity_sha256"] = hashes;
        }

        // ---------------- colour spaces ----------------
        spk_engine* engine = spk_engine_create(resourcesText.toUtf8().constData(), nullptr);
        check(engine != nullptr, QStringLiteral("engine: ") + spk_last_error(nullptr));
        QJsonObject accuracy;
        {
            // In every destination's gamut (they all contain sRGB's), moderate
            // chroma, so the gamut map's knee leaves them alone.
            const std::vector<V3> inGamut{{0.02, 0.02, 0.02}, {0.18, 0.18, 0.18}, {0.5, 0.5, 0.5}, {0.9, 0.9, 0.9},
                                          {0.45, 0.30, 0.22}, {0.20, 0.32, 0.55}, {0.15, 0.25, 0.08}, {0.5, 0.25, 0.22}};
            // Saturated sRGB colours: inside every destination, near sRGB's edge.
            const std::vector<V3> saturated{{0.6, 0.02, 0.02}, {0.02, 0.5, 0.02}, {0.03, 0.03, 0.6}};
            struct Session { const char* name; const Space* space; };
            const Space& srgb = spaceOf("sRGB");
            const Space& romm = spaceOf("ProPhoto RGB");
            const QColorSpace linearSrgb(QColorSpace::Primaries::SRgb, QColorSpace::TransferFunction::Linear);
            for(const Session session : {Session{"sRGB", &srgb}, Session{"ProPhoto RGB", &romm}}) {
                // The session's frame holds the same colours, encoded in its space.
                std::vector<V3> all = inGamut; all.insert(all.end(), saturated.begin(), saturated.end());
                std::vector<V3> sessionLinear;
                for(const auto& c : all) sessionLinear.push_back(mul(rgbToRgb(srgb, *session.space), c));
                // A ProPhoto session can also hold colours no smaller space has.
                const V3 outside = {0.05, 0.6, 0.05};   // ProPhoto green, far outside sRGB
                if(session.space == &romm) sessionLinear.push_back(outside);
                const QImage frame = patchFrame(sessionLinear, *session.space);
                for(const auto& entry : recipes::colorSpaces()) {
                    const Space& target = spaceOf(entry.engine);
                    const auto converted = exporting::convert(frame, {session.name, true}, entry.engine, engine);
                    for(Format format : {Format::tiff, Format::png, Format::jpeg}) {
                        const QString path = QStringLiteral("%1/cs-%2-%3.%4").arg(scratch, QString::fromLatin1(session.name).remove(' '),
                                             QString::fromStdString(entry.engine).remove(' ').remove('(').remove(')').remove('.').remove('-'),
                                             recipes::formatExtension(format));
                        exporting::WriteOptions w; w.format = format; w.jpegQuality = 100;
                        check(exporting::writeImage(converted.rgba64, entry.engine, native(path), w, resources) == exporting::Published::written, "write " + path);
                        // The embedded profile, and the pixels, from the file.
                        QColorSpace embedded; std::vector<double> px; int w0 = 0, h0 = 0;
                        if(format == Format::tiff) {
                            const Tiff t = tiffFile(path);
                            embedded = QColorSpace::fromIccProfile(t.raw(34675));
                            px = tiffPixels(t, w0, h0);
                        } else {
                            QImageReader reader(path); QImage img = reader.read();
                            check(!img.isNull(), "decode " + path);
                            embedded = img.colorSpace();
                            img = img.convertToFormat(QImage::Format_RGB888);
                            w0 = img.width(); h0 = img.height(); px.resize(std::size_t(w0)*h0*3);
                            for(int y = 0; y < h0; ++y) for(int x = 0; x < w0*3; ++x) px[std::size_t(y)*w0*3+x] = img.constScanLine(y)[x]/255.0;
                        }
                        check(embedded.isValid(), "the file embeds a valid profile: " + path);
                        // The profile is the intended space: its primaries, as
                        // where it puts the pure primaries in XYZ, against
                        // the independent CIE values (ICC colorants are D50-
                        // adapted, so compared after the same adaptation).
                        {
                            const QColorSpace xyzD50(QColorSpace::Primaries::ProPhotoRgb, QColorSpace::TransferFunction::Linear);
                            const Space& romm = spaceOf("ProPhoto RGB");
                            double worst = 0;
                            for(int k = 0; k < 3; ++k) {
                                double unit[3] = {0, 0, 0}; unit[k] = 1;
                                const V3 got = throughProfile(embedded, xyzD50, unit);   // linear ProPhoto
                                const V3 want = mul(rgbToRgb(target, romm), V3{double(k == 0), double(k == 1), double(k == 2)});
                                for(int c = 0; c < 3; ++c) worst = std::max(worst, std::abs(got[c] - want[c]));
                            }
                            check(worst < 4e-3, QStringLiteral("embedded profile is %1 (primary error %2): %3")
                                  .arg(QString::fromStdString(entry.engine)).arg(worst).arg(path));
                        }
                        if(entry.engine == std::string("sRGB")) check(embedded.description().contains("sRGB", Qt::CaseInsensitive), "sRGB description");
                        else check(embedded.description() == entry.name, "profile named " + entry.name + ": " + embedded.description());
                        double fileErr = 0, profileErr = 0, satErr = 0, neutralErr = 0, satHue = 0, satLightness = 0, satChroma = 1, satChromaMax = 0;
                        for(std::size_t i = 0; i < all.size(); ++i) {
                            const std::size_t at = (std::size_t(16)*w0 + i*32 + 16)*3;
                            // Independent: source linear sRGB -> target linear -> encoded.
                            const V3 lin = mul(rgbToRgb(srgb, target), all[i]);
                            double e = 0;
                            for(int k = 0; k < 3; ++k) e = std::max(e, std::abs(px[at+k] - encode(lin[k], target.curve)));
                            // Through the file's own profile back to linear sRGB.
                            const V3 back = throughProfile(embedded, linearSrgb, &px[at]);
                            double p = 0;
                            for(int k = 0; k < 3; ++k) p = std::max(p, std::abs(back[k] - all[i][k]));
                            if(std::getenv("SPK_RECIPE_DEBUG")) std::printf("%s -> %s patch %zu: file %.4f %.4f %.4f want %.4f %.4f %.4f back %.4f %.4f %.4f\n", session.name, entry.engine.c_str(), i, px[at], px[at+1], px[at+2], encode(lin[0], target.curve), encode(lin[1], target.curve), encode(lin[2], target.curve), back[0], back[1], back[2]);
                            if(i < 4) { neutralErr = std::max(neutralErr, std::max(e, p)); }
                            if(i < inGamut.size()) { fileErr = std::max(fileErr, e); profileErr = std::max(profileErr, p); }
                            else {
                                const V3 a = lab(toD50(srgb, all[i])), b = lab(toD50(srgb, back));
                                satErr = std::max(satErr, deltaE(a, b));
                                double dh = std::abs(std::atan2(a[2], a[1]) - std::atan2(b[2], b[1])) * 180 / 3.14159265358979;
                                if(dh > 180) dh = 360 - dh;
                                const double ca = std::hypot(a[1], a[2]), cb = std::hypot(b[1], b[2]);
                                satHue = std::max(satHue, dh); satLightness = std::max(satLightness, std::abs(a[0] - b[0]));
                                satChroma = std::min(satChroma, cb / ca); satChromaMax = std::max(satChromaMax, cb / ca);
                            }
                        }
                        // 8 bits in a wide space are coarse: one code near white in ProPhoto is
                        // ~0.007 of linear light, so the 8-bit bars are a code and a half.
                        const double quant = format == Format::tiff ? 0.0 : format == Format::png ? 0.007 : 0.012;
                        // Neutrals go through every conversion untouched. Colour out of
                        // the sRGB session is a plain conversion (the destination holds
                        // sRGB); out of the ProPhoto session the chroma knee may move
                        // moderately saturated colours a little toward grey.
                        const double tol = (session.space == &srgb ? 0.004 : 0.012) + quant;
                        check(neutralErr < 0.002 + quant, QStringLiteral("%1 -> %2 %3: neutral error %4").arg(session.name, entry.name, recipes::formatLabel(format)).arg(neutralErr));
                        check(fileErr < tol, QStringLiteral("%1 -> %2 %3: code error %4").arg(session.name, entry.name, recipes::formatLabel(format)).arg(fileErr));
                        check(profileErr < tol, QStringLiteral("%1 -> %2 %3: round trip through the embedded ICC %4").arg(session.name, entry.name, recipes::formatLabel(format)).arg(profileErr));
                        // Saturated colours: a plain conversion out of sRGB keeps them;
                        // out of ProPhoto the knee rolls chroma toward grey at constant
                        // hue and lightness -- never a clip, never more chroma.
                        // ProPhoto is D50: the engine adapts from D65 with CAT02, the ICC
                        // world (this read-back included) with Bradford, which differ by
                        // up to ~2.5 dE76 on saturated colours. Same white: under 1 dE.
                        const double adaptation = target.w[0] != srgb.w[0] ? 3.0 : 1.0;
                        if(session.space == &srgb)
                            check(satErr < adaptation + quant * 300, QStringLiteral("%1 -> %2: saturated colours moved %3 dE").arg(session.name, entry.name).arg(satErr));
                        else
                            check(satHue < 6 && satLightness < 4 && satChroma > 0.5 && satChromaMax < 1.03,
                                  QStringLiteral("%1 -> %2: saturated colours hue %3 deg, L %4, chroma x%5..x%6").arg(session.name, entry.name)
                                  .arg(satHue).arg(satLightness).arg(satChroma).arg(satChromaMax));
                        QJsonObject row{{"max_code_error", fileErr}, {"neutral_max_error", neutralErr}, {"max_linear_roundtrip_error", profileErr}, {"saturated_max_dE76", satErr}, {"saturated_max_hue_shift_deg", satHue}, {"saturated_min_chroma_ratio", satChroma},
                                        {"identity", converted.identity}, {"clipped_fraction", converted.clippedFraction}};
                        // The out-of-gamut green from ProPhoto: inside [0, 1],
                        // still green, its hue kept (CAM16-UCS compression,
                        // not a per-channel clip).
                        if(session.space == &romm && format == Format::tiff) {
                            const std::size_t at = (std::size_t(16)*w0 + all.size()*32 + 16)*3;
                            V3 encoded{px[at], px[at+1], px[at+2]};
                            V3 lin{decode(encoded[0], target.curve), decode(encoded[1], target.curve), decode(encoded[2], target.curve)};
                            const V3 a = lab(toD50(romm, outside)), b = lab(toD50(target, lin));
                            const double hueA = std::atan2(a[2], a[1]), hueB = std::atan2(b[2], b[1]);
                            double dh = std::abs(hueA-hueB) * 180 / 3.14159265358979; if(dh > 180) dh = 360-dh;
                            check(encoded[1] > encoded[0] && encoded[1] > encoded[2] && dh < 12,
                                  QStringLiteral("ProPhoto green into %1 keeps its hue (%2 deg)").arg(entry.name).arg(dh));
                            row["outside_gamut_hue_shift_deg"] = dh;
                        }
                        accuracy[QStringLiteral("%1 -> %2 %3").arg(session.name, entry.name, recipes::formatLabel(format))] = row;
                    }
                    if(session.space == &romm && entry.engine == std::string("ProPhoto RGB"))
                        check(converted.identity && converted.rgba64 == frame, "ProPhoto session to ProPhoto: untouched");
                    if(session.space == &srgb && entry.engine == std::string("sRGB"))
                        check(converted.identity, "sRGB session to sRGB: untouched");
                }
            }
            report["colour_accuracy"] = accuracy;
        }

        // ---------------- EXIF, preview page, the DI's view LUTs ----------------
        {
            spkhost::Exif e; e.make = "TESTMAKE"; e.model = "Model 1"; e.lens = "50mm F1.4"; e.iso = 400; e.shutter_s = 1.0/250;
            e.aperture = 2.8; e.focal_mm = 50; e.datetime_original = "2026:10:16 12:34:56"; e.color_space = 0xFFFF;
            const QImage frame = busyFrame(97, 61);
            for(Format format : {Format::tiff, Format::png, Format::jpeg}) {
                const QString path = scratch + "/exif." + recipes::formatExtension(format);
                exporting::WriteOptions w; w.format = format; w.exif = &e;
                w.preview = format == Format::tiff;
                check(exporting::writeImage(frame, "Display P3", native(path), w, resources) == exporting::Published::written, "exif write");
                const QByteArray file = readAll(path);
                Tiff ifd0;
                if(format == Format::tiff) {
                    ifd0 = tiffFile(path);
                    check(ifd0.next != 0, "TIFF preview page: IFD1 present");
                    const Tiff page = tiffAt(file, ifd0.next);
                    check(page.values.at(254)[0] == 1 && page.values.at(258)[0] == 8 && page.values.at(256)[0] == 97 &&
                          QColorSpace::fromIccProfile(page.raw(34675)).isValid(), "preview page is an 8-bit tagged picture");
                } else {
                    const QByteArray block = exifBlockOf(file);
                    check(!block.isEmpty(), "EXIF block in " + path);
                    ifd0 = tiffAt(block, 8);
                    check(!QImageReader(path).read().isNull() && QImageReader(path).read().colorSpace().isValid(), "still decodes, tagged");
                }
                check(ifd0.ascii(271) == "TESTMAKE" && ifd0.ascii(272) == "Model 1" && ifd0.values.at(274)[0] == 1,
                      "make/model/orientation in " + path);
                const Tiff ex = tiffAt(ifd0.data, ifd0.values.at(34665)[0]);
                check(ex.values.at(0x8827)[0] == 400 && ex.values.at(0x829A)[0] == 1 && ex.values.at(0x829A)[1] == 250 &&
                      ex.values.at(0x829D)[0] == 280 && ex.ascii(0x9003) == "2026:10:16 12:34:56" && ex.ascii(0xA434) == "50mm F1.4" &&
                      ex.values.at(0xA001)[0] == 0xFFFF && ex.values.at(0xA002)[0] == 97 && ex.values.at(0xA003)[0] == 61,
                      "EXIF fields in " + path);
            }
            // The DI: untagged 16-bit, preview page, LUTs copied once.
            const QString diDir = scratch + "/di";
            QDir().mkpath(diDir);
            const auto luts = exporting::copyDiViewLuts(diDir, resources);
            check(luts.size() == 2 && exporting::copyDiViewLuts(diDir, resources).isEmpty(), "the two view LUTs, copied once");
            const QImage view = exporting::diViewPreview(frame, resources);
            check(!view.isNull() && view.colorSpace() == QColorSpace(QColorSpace::ProPhotoRgb) && view.size() == frame.size(),
                  "DI view preview through the shipped LUT");
            exporting::WriteOptions w; w.format = Format::di; w.untagged = true; w.preview = true; w.previewImage = view; w.exif = &e;
            const QString di = diDir + "/x_DI.tif";
            check(exporting::writeImage(frame, "", native(di), w, resources) == exporting::Published::written, "DI write");
            const Tiff t = tiffFile(di);
            check(t.raw(34675).isEmpty() && t.values.at(258)[0] == 16 && t.next != 0, "DI: untagged 16-bit, with its view page");
        }

        // ---------------- a RAW's EXIF (optional fixture copy) ----------------
        if(args.size() >= 4) {
            const QString copy = scratch + "/fixture." + QFileInfo(args[3]).suffix();
            check(QFile::copy(args[3], copy), "copy the RAW fixture");
            recipes::Metadata all;
            const auto exif = exporting::exifFor(native(copy), all, "sRGB", false);
            check(exif && !exif->make.empty() && !exif->model.empty() && exif->iso > 0 && exif->shutter_s > 0 &&
                  !exif->datetime_original.empty() && exif->color_space == 1, "LibRaw's EXIF for the RAW");
            spkhost::Probe probe; std::string error;
            check(spkhost::probe_file(native(copy), probe, error), "probe");
            recipes::Metadata none; none.camera = none.lens = none.exposure = none.date = false;
            const auto bare = exporting::exifFor(native(copy), none, "Display P3", false);
            check(bare && bare->make.empty() && bare->iso == 0 && bare->color_space == 0xFFFF, "fields switched off are not copied");
            recipes::Metadata off; off.exif = false;
            check(!exporting::exifFor(native(copy), off, "sRGB", false), "EXIF off copies nothing");
            const QString jpg = scratch + "/raw-exif.jpg";
            exporting::WriteOptions w; w.format = Format::jpeg; w.exif = &*exif;
            check(exporting::writeImage(busyFrame(40, 30), "sRGB", native(jpg), w, resources) == exporting::Published::written, "write");
            const Tiff ifd0 = tiffAt(exifBlockOf(readAll(jpg)), 8);
            const Tiff ex = tiffAt(ifd0.data, ifd0.values.at(34665)[0]);
            check(ifd0.ascii(271) == QString::fromStdString(probe.metadata.make) && ifd0.ascii(272) == QString::fromStdString(probe.metadata.model) &&
                  ex.values.at(0x8827)[0] == std::uint32_t(std::lround(*probe.metadata.iso)) &&
                  ex.ascii(0x9003) == QString::fromStdString(probe.metadata.datetime_original), "the RAW's EXIF reaches the JPEG");
            report["raw_exif"] = QJsonObject{{"make", QString::fromStdString(exif->make)}, {"model", QString::fromStdString(exif->model)},
                                             {"iso", exif->iso}, {"shutter_s", exif->shutter_s}, {"lens", QString::fromStdString(exif->lens)},
                                             {"datetime", QString::fromStdString(exif->datetime_original)}};
        } else {
            std::printf("RAW EXIF checks not run: pass a RAW as the third argument\n");
        }
        spk_engine_destroy(engine);
        report["checks"] = checks;
        report["passed"] = true;
        QFile out(scratch + "/report.json");
        if(out.open(QIODevice::WriteOnly)) out.write(QJsonDocument(report).toJson());
        std::printf("%s\n", QJsonDocument(report).toJson().constData());
        std::printf("spk_qt_recipe_export: %d checks passed\n", checks);
        return 0;
    } catch(const std::exception& e) {
        std::fprintf(stderr, "FAILED after %d checks: %s\n", checks, e.what());
        return 1;
    }
}
