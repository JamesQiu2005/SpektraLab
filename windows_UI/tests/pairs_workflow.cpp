// A half-frame pair end to end through the real controller, engine and two
// RAWs (README "Film Edge, Date Back and half-frame pairs"; Session.swift's
// pair): New Half-Frame Pair on two selected photographs, one item in the
// filmstrip after its first frame; a click picks a hole and Input / Camera
// and the Enlarger act on that frame alone (the other frame's pixels do not
// move); each edit one undo step; the crop mode's drag and wheel; the pair's
// own record across a restart with the photographs' records untouched; the
// recipe export writing the pair as one picture, refused with an empty hole;
// Enter Half-Frame Pair from a half frame; Sync from a pair; deleting it.
//
// Arguments: <resources> <RAW> <second RAW> <new-output-directory>. The RAWs
// are copied into the output directory; nothing is written beside them.
#include "PreviewController.hpp"
#include "ExportRecipe.hpp"
#include "RecipeExport.hpp"
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
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <stdexcept>

namespace {
namespace recipes = spk::desktop::recipes;
int checks = 0;
void check(bool ok, const QString& what) {
    ++checks;
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", qPrintable(what));
    std::fflush(stdout);
    if (!ok) throw std::runtime_error(what.toUtf8().toStdString());
}
std::filesystem::path native(const QString& p) { return std::filesystem::path(p.toStdWString()); }
void waitFor(const std::function<bool()>& condition, const QString& what, int ms = 300000) {
    if (condition()) return;
    QEventLoop loop;
    QTimer poll, deadline;
    poll.setInterval(10);
    deadline.setSingleShot(true);
    QObject::connect(&poll, &QTimer::timeout, &loop, [&] { if (condition()) loop.quit(); });
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    poll.start();
    deadline.start(ms);
    loop.exec();
    if (!condition()) check(false, "timed out waiting for " + what);
}
void settle(int ms) {
    QEventLoop loop;
    QTimer::singleShot(ms, &loop, &QEventLoop::quit);
    loop.exec();
}
void idle(PreviewController& c, const QString& what) {
    waitFor([&] { return !c.busy() && !c.dirty() && !c.batchExporting(); }, what);
}
QByteArray sha(const QString& path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QCryptographicHash::hash(f.readAll(), QCryptographicHash::Sha256).toHex();
}
// Every photograph's record in the edit store, by file name, and its hash.
std::map<QString, QByteArray> records(const QString& edits) {
    std::map<QString, QByteArray> out;
    for (const auto& name : QDir(edits).entryList({"*.json"}, QDir::Files)) out[name] = sha(edits + "/" + name);
    return out;
}
QVariantMap pairOf(const PreviewController& c) { return c.pair(); }
QVariantMap hole(const PreviewController& c, int side) { return c.pair().value("holes").toList().value(side).toMap(); }
QVariantMap rectOf(const QVariantMap& h) { return h.value("rect").toMap(); }
// The mean of the print inside a hole, inset by a tenth: R, G, B, 0..65535.
std::array<double, 3> holeMean(const PreviewController& c, int side) {
    const auto f = c.frame();
    const auto r = rectOf(hole(c, side));
    const double W = f->width(), H = f->height();
    const int x0 = int((r["x"].toDouble() + 0.1 * r["width"].toDouble()) * W), x1 = int((r["x"].toDouble() + 0.9 * r["width"].toDouble()) * W);
    const int y0 = int((r["y"].toDouble() + 0.1 * r["height"].toDouble()) * H), y1 = int((r["y"].toDouble() + 0.9 * r["height"].toDouble()) * H);
    const auto& px = f->pixels();
    double sum[3] = {};
    long n = 0;
    for (int y = y0; y < y1; y += 4)
        for (int x = x0; x < x1; x += 4) {
            const auto* p = px.rgba16 + (std::size_t(y) * px.row_stride_px + x) * 4;
            for (int k = 0; k < 3; ++k) sum[k] += p[k];
            ++n;
        }
    return {sum[0] / n, sum[1] / n, sum[2] / n};
}
double luma(const std::array<double, 3>& m) { return 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; }
// The mean luma inside a hole (inset by a tenth) of an image the size of the
// frame: the canvas's picture, or an exported file.
double imageHoleLuma(const QImage& image, const QVariantMap& r) {
    const double W = image.width(), H = image.height();
    const int x0 = int((r["x"].toDouble() + 0.1 * r["width"].toDouble()) * W), x1 = int((r["x"].toDouble() + 0.9 * r["width"].toDouble()) * W);
    const int y0 = int((r["y"].toDouble() + 0.1 * r["height"].toDouble()) * H), y1 = int((r["y"].toDouble() + 0.9 * r["height"].toDouble()) * H);
    const int step = std::max(1, (x1 - x0) / 120);
    double sum = 0;
    long n = 0;
    for (int y = y0; y < y1; y += step)
        for (int x = x0; x < x1; x += step) {
            const QColor c = image.pixelColor(x, y);
            sum += 0.2126 * c.redF() + 0.7152 * c.greenF() + 0.0722 * c.blueF();
            ++n;
        }
    return n ? sum / n : 0;
}
double param(const PreviewController& c, const char* key) { return c.parameters().value(key).toDouble(); }
recipes::Recipe recipe(recipes::Format format, const QString& folder) {
    recipes::Recipe r;
    r.name = QStringLiteral("pairs");
    r.format = format;
    r.colorSpace = recipes::kSRGB;
    r.besideOriginal = false;
    r.folder = folder;
    r.subfolder.clear();
    r.naming.tokens = {recipes::Token::originalName};
    r.metadata.exif = true;
    return r;
}
struct Result { QString summary; bool warning = false; QStringList files; bool done = false; };
Result run(PreviewController& c, const recipes::Recipe& r) {
    Result result;
    auto connection = QObject::connect(&c, &PreviewController::exportFinished, [&](const QString& s, bool w, const QStringList& f) {
        result.summary = s; result.warning = w; result.files = f; result.done = true;
    });
    c.exportWithRecipe(r.toJson().toVariantMap());
    waitFor([&] { return result.done && !c.busy(); }, "the recipe export");
    QObject::disconnect(connection);
    return result;
}
int pairIndex(const PreviewController& c) {
    const auto items = c.libraryItems();
    for (int i = 0; i < items.size(); ++i) if (items[i].toMap().value("pair").toBool()) return i;
    return -1;
}
}  // namespace

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", QByteArray("offscreen"));
    QGuiApplication app(argc, argv);
    QJsonObject report;
    try {
        const auto args = app.arguments();
        if (args.size() != 5) throw std::runtime_error("usage: spk_qt_pairs_workflow_test <resources> <RAW> <second RAW> <new-output-directory>");
        const auto resources = native(args[1]);
        const QString dest = QFileInfo(args[4]).absoluteFilePath();
        check(QFileInfo(args[2]).isFile() && QFileInfo(args[3]).isFile() && !QFileInfo::exists(dest) && QDir().mkpath(dest + "/roll"),
              "two RAWs and a new output directory");
        const QString a = dest + "/roll/alpha." + QFileInfo(args[2]).suffix(), b = dest + "/roll/beta." + QFileInfo(args[3]).suffix();
        check(QFile::copy(args[2], a) && QFile::copy(args[3], b), "copy the RAWs");
        const QString edits = dest + "/edits";
        QElapsedTimer clock;
        clock.start();
        QString pairRecord;
        {
            PreviewController c(resources, nullptr, {}, edits);
            waitFor([&] { return c.ready(); }, "engine");
            c.openFiles({QUrl::fromLocalFile(a), QUrl::fromLocalFile(b)});
            waitFor([&] { return c.hasFrame(); }, "first photo");
            idle(c, "open");
            c.flushEdits();
            const auto before = records(edits);
            check(c.libraryItems().size() == 2 && !c.pair().value("active").toBool(), "two photographs, no pair yet");

            // ---- New Half-Frame Pair (Ctrl+J) on the two selected photographs ----
            c.selectAllPhotos(true);
            check(c.canMakePair(), "a pair can be made");
            check(c.newPair(), "New Half-Frame Pair");
            idle(c, "the pair's develop");
            const auto items = c.libraryItems();
            check(items.size() == 3 && items[1].toMap().value("pair").toBool() && c.activeIndex() == 1,
                  "one item in the filmstrip, after its first frame, on the canvas");
            check(items[1].toMap().value("name").toString() == "Half-Frame Pair 1", "named Half-Frame Pair 1");
            auto p = pairOf(c);
            check(p.value("active").toBool() && p.value("filled").toInt() == 2 && p.value("complete").toBool() &&
                      hole(c, 0).value("name").toString() == QFileInfo(a).fileName() && hole(c, 1).value("name").toString() == QFileInfo(b).fileName(),
                  "both holes filled in the strip's order");
            const auto f = c.frame();
            check(f && f->pair && f->pair_filled[0] && f->pair_filled[1], "the frame is the composed piece");
            const double longSide = std::max(f->width(), f->height()), shortSide = std::min(f->width(), f->height());
            check(std::abs(longSide / shortSide - 37.0 / 24.0) < 0.01, QString("the piece is 37 x 24 (%1 x %2)").arg(f->width()).arg(f->height()));
            const auto r0 = rectOf(hole(c, 0)), r1 = rectOf(hole(c, 1));
            check(r0["width"].toDouble() > 0.3 && r1["width"].toDouble() > 0.3 &&
                      (p.value("turned").toBool() ? r1["y"].toDouble() > r0["y"].toDouble() + r0["height"].toDouble()
                                                  : r1["x"].toDouble() > r0["x"].toDouble() + r0["width"].toDouble()),
                  "two holes, the gap between them");
            pairRecord = QDir(edits + "/Pairs").absoluteFilePath(QDir(edits + "/Pairs").entryList({"*.spkpair"}).value(0));
            check(QFileInfo(pairRecord).isFile(), "the pair's own record in <edits>/Pairs");
            report["piece"] = QString("%1x%2").arg(f->width()).arg(f->height());
            report["metered"] = QString("%1 / %2").arg(f->pair_metered[0]).arg(f->pair_metered[1]);
            check(std::abs(f->pair_metered[0]) > 1e-6 || std::abs(f->pair_metered[1]) > 1e-6, "each picture metered alone");

            // ---- a click picks a hole; Input / Camera acts on that frame alone ----
            const auto base0 = holeMean(c, 0), base1 = holeMean(c, 1);
            c.pairClicked(r1["x"].toDouble() + r1["width"].toDouble() / 2, r1["y"].toDouble() + r1["height"].toDouble() / 2);
            check(c.pair().value("layer").toString() == "second", "a click on the second hole picks it");
            const int undoBase = 0;
            (void)undoBase;
            check(c.setParameter("exposure_compensation_ev", 1.0), "Film Exposure on the second frame");
            idle(c, "the second frame's exposure");
            const auto exp0 = holeMean(c, 0), exp1 = holeMean(c, 1);
            report["exposure"] = QString("first %1 -> %2, second %3 -> %4").arg(luma(base0)).arg(luma(exp0)).arg(luma(base1)).arg(luma(exp1));
            check(luma(exp1) > luma(base1) * 1.08 && std::abs(luma(exp0) - luma(base0)) < 0.01 * luma(base0) + 30,
                  "the second picture brightens, the first does not move");
            c.setPairLayer("first");
            check(param(c, "exposure_compensation_ev") == 0, "the first frame keeps its own exposure");
            c.setPairLayer("second");
            check(param(c, "exposure_compensation_ev") == 1.0, "and the second its own");
            // The white balance is the frame's decode.
            c.setPairLayer("first");
            check(c.setTemperature(3000), "a white balance on the first frame");
            idle(c, "the first frame's white balance");
            const auto wb0 = holeMean(c, 0), wb1 = holeMean(c, 1);
            report["whiteBalance"] = QString("first B/R %1 -> %2").arg(exp0[2] / exp0[0]).arg(wb0[2] / wb0[0]);
            check(std::abs(wb0[2] / wb0[0] - exp0[2] / exp0[0]) > 0.03 && std::abs(luma(wb1) - luma(exp1)) < 0.01 * luma(exp1) + 30,
                  "the first picture's colour moves, the second does not");
            check(c.whiteBalance().value("mode").toString() == "custom", "the rails show the picked frame's white balance");
            c.setPairLayer("second");
            check(c.whiteBalance().value("mode").toString() == "as_shot", "the other frame is still As Shot");

            // ---- undo: each edit one step ----
            check(c.canUndo(), "undo is offered");
            c.undo();
            idle(c, "undo");
            c.setPairLayer("first");
            check(c.whiteBalance().value("mode").toString() == "as_shot", "undo takes the white balance back");
            c.setPairLayer("second");
            check(param(c, "exposure_compensation_ev") == 1.0, "and only the white balance");
            c.redo();
            idle(c, "redo");
            c.setPairLayer("first");
            check(c.whiteBalance().value("mode").toString() == "custom", "redo puts it back");

            // ---- the Enlarger on one frame, + Film by default ----
            c.setPairLayer("second");
            check(c.setParameter("y_filter_shift", 0.5), "a filter on the second frame's print");
            idle(c, "the second frame's print");
            check(c.frame()->pair_layered, "the frame's own print is cut into its hole");
            const auto y0 = holeMean(c, 0), y1 = holeMean(c, 1);
            check(std::abs(y1[2] / y1[0] - wb1[2] / wb1[0]) > 0.02 && std::abs(y0[2] / y0[0] - wb0[2] / wb0[0]) < 0.01,
                  "the second picture's colour moves, the first does not");
            c.setPairLayer("film");
            check(std::abs(param(c, "y_filter_shift") - 0.5) < 1e-9, "+ Film: the film around it moved with it");
            c.setPairLayer("first");
            check(std::abs(param(c, "y_filter_shift")) < 1e-9, "the first frame kept the film's old print");

            // ---- Post-Dev on one frame (Session.layerAdjustments, pairLayered) ----
            c.setPairLayer("first");
            const QImage ungraded = c.previewImage();
            check(c.setPostDev("exposure", 1.0), "a Post-Dev exposure on the first frame");
            waitFor([&] { return c.previewImage().cacheKey() != ungraded.cacheKey(); }, "the picture graded frame by frame");
            check(c.canvasPostDev().value("enabled").toBool() == false, "the canvas adds no grade of its own: the picture is graded");
            const QImage graded = c.previewImage();
            const double ug0 = imageHoleLuma(ungraded, rectOf(hole(c, 0))), ug1 = imageHoleLuma(ungraded, rectOf(hole(c, 1)));
            const double gr0 = imageHoleLuma(graded, rectOf(hole(c, 0))), gr1 = imageHoleLuma(graded, rectOf(hole(c, 1)));
            report["postDev"] = QString("first %1 -> %2, second %3 -> %4").arg(ug0).arg(gr0).arg(ug1).arg(gr1);
            check(gr0 > ug0 * 1.1 && std::abs(gr1 - ug1) < 0.002, "the first frame's grade brightens the first picture only");
            c.setPairLayer("second");
            check(c.postDev().value("exposure").toDouble() == 0, "the second frame's Post-Dev is still the film's");
            c.setPairLayer("film");
            check(c.postDev().value("exposure").toDouble() == 0, "and the film's own grade is untouched");
            c.setPairLayer("first");
            check(c.postDev().value("exposure").toDouble() == 1.0, "the rail shows the picked frame's own grade");
            c.undo();
            settle(200);
            check(c.postDev().value("exposure").toDouble() == 0 && c.canvasPostDev().value("enabled").toBool(),
                  "undo takes the frame's grade back: one grade again, on the canvas");
            c.redo();
            waitFor([&] { return !c.canvasPostDev().value("enabled").toBool(); }, "redo of the frame's grade");
            check(c.postDev().value("exposure").toDouble() == 1.0, "redo puts it back");

            // ---- the neutral picker on a pair: the hole under it picks the frame ----
            c.setPairLayer("film");
            {
                bool picked = false, ok = false;
                QString why;
                auto connection = QObject::connect(&c, &PreviewController::neutralPicked, [&](bool success, const QString& message) {
                    picked = true; ok = success; why = message;
                });
                const auto r = rectOf(hole(c, 1));
                check(c.pickNeutral(r["x"].toDouble() + 0.35 * r["width"].toDouble(), r["y"].toDouble() + 0.75 * r["height"].toDouble()),
                      "the neutral picker starts on the second hole");
                waitFor([&] { return picked && !c.busy(); }, "the neutral pick");
                QObject::disconnect(connection);
                check(ok, "the pick is answered: " + why);
                idle(c, "the picked white balance's develop");
                check(c.pair().value("layer").toString() == "second" && c.whiteBalance().value("mode").toString() == "custom",
                      "the pick picked the second frame and set its own white balance");
                c.setPairLayer("first");
                check(std::abs(c.whiteBalance().value("temperature").toDouble() - 3000) < 1, "the first frame's is untouched");
                c.undo();
                idle(c, "undo the pick");
                c.setPairLayer("second");
                check(c.whiteBalance().value("mode").toString() == "as_shot", "one undo takes the pick back");
            }

            // ---- the crop mode inside a hole: drag moves, wheel scales ----
            c.setPairLayer("first");
            c.setPairPlacing(true);
            check(c.pair().value("placing").toBool(), "the crop mode on the picked frame");
            const auto q0 = rectOf(hole(c, 0));
            const double cx = q0["x"].toDouble() + q0["width"].toDouble() / 2, cy = q0["y"].toDouble() + q0["height"].toDouble() / 2;
            check(c.zoomPairPlacement(1.5, cx, cy), "the wheel scales the picture about the pointer");
            check(c.pair().value("drag").toMap().value("active").toBool(), "the gesture shows before its develop");
            settle(400);
            idle(c, "the zoom's develop");
            check(std::abs(hole(c, 0).value("placement").toMap().value("scale").toDouble() - 1.5) < 1e-9, "written when the wheel rests");
            check(c.beginPairDrag(cx, cy), "a drag starts inside the hole");
            c.movePairDrag(cx + 0.03, cy);
            c.endPairDrag();
            idle(c, "the drag's develop");
            const double movedX = hole(c, 0).value("placement").toMap().value("x").toDouble();
            check(std::abs(movedX) > 0.01, "the drag moved the picture under its hole");
            c.undo();
            idle(c, "undo the drag");
            check(std::abs(hole(c, 0).value("placement").toMap().value("x").toDouble()) < 1e-9 &&
                      std::abs(hole(c, 0).value("placement").toMap().value("scale").toDouble() - 1.5) < 1e-9,
                  "one undo takes back the drag, not the zoom");
            c.setPairPlacing(false);
            c.turnPairPicture("first");
            idle(c, "turn the picture");
            check(hole(c, 0).value("placement").toMap().value("quarterTurns").toInt() == 1, "Turn Picture 90°");
            c.undo();
            idle(c, "undo the turn");

            // ---- the photographs' own records are untouched ----
            c.flushEdits();
            const auto after = records(edits);
            check(after == before, "the photographs' records are untouched by the pair");

            // ---- export: one picture; refused with an empty hole ----
            c.selectAllPhotos(false);
            c.setItemSelected(1, true);
            const auto jpeg = run(c, recipe(recipes::Format::jpeg, dest + "/export"));
            check(jpeg.files.size() == 1 && QFileInfo(jpeg.files[0]).fileName() == "Half-Frame Pair 1.jpg", "the pair exports as one picture: " + jpeg.summary);
            QImageReader reader(jpeg.files[0]);
            const QSize size = reader.size();
            check(size.width() == int(c.frame()->width()) && size.height() == int(c.frame()->height()), "the picture is the piece the canvas shows");
            {
                // Graded frame by frame as the canvas is: the two holes stand in
                // the file as they stand on the canvas.
                // The canvas holds the session's working space (ProPhoto RGB,
                // PreviewController::kWorkingSpace) and the file is sRGB: the
                // canvas's picture goes through the export's own conversion
                // (exporting::convert) so both are compared in one space -- the
                // file must be the canvas's graded picture, converted once.
                const QImage file = QImageReader(jpeg.files[0]).read();
                const auto encoding = c.frame()->encoding;
                QImage shown = c.previewImage();
                if (!encoding.is_encoded_srgb()) {
                    struct Engine { spk_engine* e; ~Engine() { if (e) spk_engine_destroy(e); } } engine{
                        spk_engine_create(args[1].toUtf8().constData(), nullptr)};
                    check(engine.e != nullptr, "a test engine for the export's conversion");
                    shown = spk::desktop::exporting::convert(shown.convertToFormat(QImage::Format_RGBA64), encoding, "sRGB",
                                                             engine.e).rgba64;
                }
                report["sessionSpace"] = QString::fromStdString(encoding.color_space);
                const double f0 = imageHoleLuma(file, rectOf(hole(c, 0))), f1 = imageHoleLuma(file, rectOf(hole(c, 1)));
                const double s0 = imageHoleLuma(shown, rectOf(hole(c, 0))), s1 = imageHoleLuma(shown, rectOf(hole(c, 1)));
                report["exportGrade"] = QString("file %1 / %2, canvas %3 / %4").arg(f0).arg(f1).arg(s0).arg(s1);
                check(std::abs(f0 - s0) < 0.02 && std::abs(f1 - s1) < 0.02, "the file carries each frame's own grade, as the canvas shows it");
            }
            const auto tiff = run(c, recipe(recipes::Format::tiff, dest + "/export"));
            check(tiff.files.size() == 1 && QFileInfo(tiff.files[0]).suffix() == "tif" && !tiff.warning, "and as a TIFF");
            report["export"] = QFileInfo(jpeg.files[0]).fileName() + " " + QString::number(size.width()) + "x" + QString::number(size.height());
            c.removePairFrame("second");
            idle(c, "an empty hole");
            check(c.pair().value("filled").toInt() == 1, "a frame removed from its hole");
            const auto refused = run(c, recipe(recipes::Format::jpeg, dest + "/export-empty"));
            check(refused.files.isEmpty() && refused.warning && refused.summary.contains("each hole"),
                  "a pair with an empty hole is not exported: " + refused.summary);
            c.undo();
            idle(c, "undo the removal");
            check(c.pair().value("filled").toInt() == 2, "undo puts the frame back");
            c.flushEdits();
        }

        // ---- the record across a restart ----
        {
            PreviewController c(resources, nullptr, {}, edits);
            waitFor([&] { return c.ready(); }, "engine again");
            c.openFiles({QUrl::fromLocalFile(a), QUrl::fromLocalFile(b)});
            waitFor([&] { return c.hasFrame(); }, "first photo again");
            idle(c, "open again");
            const int index = pairIndex(c);
            check(index == 1 && c.libraryItems().size() == 3, "the pair comes back with its folder, after its first frame");
            c.selectImage(index);
            waitFor([&] { return c.pair().value("active").toBool(); }, "the pair again");
            idle(c, "the pair's develop again");
            c.setPairLayer("second");
            check(param(c, "exposure_compensation_ev") == 1.0 && std::abs(param(c, "y_filter_shift") - 0.5) < 1e-9,
                  "each frame's own state survives a restart");
            c.setPairLayer("first");
            check(c.whiteBalance().value("mode").toString() == "custom" &&
                      std::abs(hole(c, 0).value("placement").toMap().value("scale").toDouble() - 1.5) < 1e-9,
                  "the first frame's white balance and crop too");
            check(c.postDev().value("exposure").toDouble() == 1.0 && !c.canvasPostDev().value("enabled").toBool(),
                  "and its own Post-Dev grade");

            // ---- Sync from the pair: the picked frame's look, not its film edge ----
            check(c.setParameter("grain_amount", 1.6), "a film setting on the pair");
            idle(c, "the pair's grain");
            c.selectAllPhotos(false);
            c.setItemSelected(2, true);
            c.syncSelectedSettings(false);
            c.selectImage(2);
            waitFor([&] { return c.activeIndex() == 2 && !c.busy(); }, "the synced photograph");
            idle(c, "the synced photograph's develop");
            check(std::abs(param(c, "grain_amount") - 1.6) < 1e-9 && c.parameters().value("overscan_format").toString() != "135_half",
                  "Sync takes the pair's look, the film edge stays the photograph's");

            // ---- Enter Half-Frame Pair from a half frame ----
            c.selectImage(0);
            waitFor([&] { return c.activeIndex() == 0 && !c.busy(); }, "the first photograph");
            idle(c, "the first photograph's develop");
            check(c.setParameter("overscan_format", QStringLiteral("135_half")), "a half frame");
            idle(c, "the half frame");
            check(c.canEnterPair(), "Enter Half-Frame Pair is offered on Half");
            check(c.enterPair(), "Enter Half-Frame Pair");
            idle(c, "the entered pair");
            check(c.pair().value("active").toBool() && c.pair().value("filled").toInt() == 1 && c.pair().value("layer").toString() == "second" &&
                      c.libraryItems().value(1).toMap().value("name").toString() == "Half-Frame Pair 2",
                  "the photograph is the first frame; the empty second hole is picked");

            // ---- deleting a pair: its record only ----
            const int count = c.libraryItems().size();
            const QString second = QDir(edits + "/Pairs").absoluteFilePath(
                QDir(edits + "/Pairs").entryList({"Half-Frame Pair 2 *.spkpair"}, QDir::Files).value(0));
            check(QFileInfo(second).isFile(), "the entered pair has its own record");
            check(c.deletePair(1), "Delete Pair");
            waitFor([&] { return !c.busy(); }, "the next photograph");
            check(c.libraryItems().size() == count - 1 && !QFileInfo::exists(second) && QFileInfo(a).isFile() && QFileInfo(b).isFile(),
                  "the record goes, the photographs stay");
            idle(c, "after the deletion");
        }
        report["checks"] = checks;
        report["seconds"] = clock.elapsed() / 1000.0;
        report["passed"] = true;
        std::printf("OK: %d checks in %.1f s\n", checks, clock.elapsed() / 1000.0);
    } catch (const std::exception& e) {
        report["passed"] = false;
        report["error"] = QString::fromUtf8(e.what());
        std::printf("FAILED after %d checks: %s\n", checks, e.what());
    }
    const auto args = app.arguments();
    if (args.size() == 5) {
        QFile out(QFileInfo(args[4]).absoluteFilePath() + "/report.json");
        if (out.open(QIODevice::WriteOnly)) out.write(QJsonDocument(report).toJson());
    }
    return report.value("passed").toBool() ? 0 : 1;
}
