// The library and the settings clipboard, as the macOS app has them, without
// a RAW fixture: the library's file side (Library.hpp) and the clipboard's
// groups (SettingsClipboard.hpp) alone, then the real controller on a folder
// of small PNGs written here -- they open through the engine like any photo
// (raw_white_balance.hpp decodes them at the door), so every behaviour below
// runs in CTest:
//
//   * a folder opens in Finder's order, without its subfolders or the files
//     that do not open; a dragged order is kept for the folder and laid over
//     the listing the next time, a new file after its own neighbour
//     (FrameOrder.swift, Session.moveFrame);
//   * a plain click picks one photo and opens it, Ctrl+click picks without
//     moving the open photo, which cannot leave the set; Left/Right step
//     (Session.click / togglePick / selectRelative);
//   * the strip shows each file's own preview at once, then the rendered
//     print, whole, under its crop mask (CropMaskedThumbnail.swift);
//   * Copy takes the ticked groups, Paste and Sync write exactly those --
//     never Film Edge, Date Back, the crop or Post-Dev; As Shot white balance
//     stays the target's; Scene Placement waits for the target's own Fit;
//     each recipient undoes on its own; nothing pastes during a batch export
//     (SettingsClipboard.swift, Session.pasteSettings / syncSettings);
//   * setParameters is ONE undo step, and refuses a bad value whole.
//
// Arguments: <engine resources> <scratch directory> (each run makes its own
// new directory inside it).
#include "PreviewController.hpp"
#include "Library.hpp"
#include "SettingsClipboard.hpp"
#include <QDateTime>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QSettings>
#include <QTimer>
#include <cmath>
#include <cstdio>
#include <functional>
#include <stdexcept>
#include <string>

namespace {
namespace desktop = spk::desktop;
namespace library = desktop::library;
namespace clipboard = desktop::clipboard;
namespace output = desktop::output;

int checks = 0;
void check(bool ok, const QString& what) {
    ++checks;
    if (!ok) throw std::runtime_error(what.toStdString());
}
void waitFor(const std::function<bool()>& condition, const QString& what, int ms = 120000) {
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
    check(condition(), "timed out waiting for " + what);
}
void idle(PreviewController& c, const QString& what) {
    waitFor([&] { return !c.busy() && !c.dirty() && !c.batchExporting() && c.pictureSettled(); }, what);
    check(!c.failed(), what + ": " + c.status());
}
void touch(const QString& path) {
    QFile f(path);
    check(f.open(QIODevice::WriteOnly), "cannot write " + path);
}
// A small photo: a soft gradient with a coloured block, `hue` telling them apart.
void photo(const QString& path, int hue) {
    QImage image(300, 200, QImage::Format_RGB32);
    for (int y = 0; y < image.height(); ++y)
        for (int x = 0; x < image.width(); ++x)
            image.setPixelColor(x, y, QColor::fromHsv(hue, 60 + y / 4, 60 + x * 180 / 300));
    QPainter(&image).fillRect(110, 60, 80, 80, QColor::fromHsv((hue + 120) % 360, 200, 220));
    check(image.save(path, "PNG"), "cannot write " + path);
}
QStringList names(const PreviewController& c) {
    QStringList out;
    for (const auto& item : c.libraryItems()) out.push_back(item.toMap().value("name").toString());
    return out;
}
QList<int> picked(const PreviewController& c) {
    QList<int> out;
    const auto items = c.libraryItems();
    for (int i = 0; i < items.size(); ++i)
        if (items[i].toMap().value("selected").toBool()) out.push_back(i);
    return out;
}
QStringList base(const QStringList& paths) {
    QStringList out;
    for (const auto& p : paths) out.push_back(QFileInfo(p).fileName());
    return out;
}
double luma(const QImage& image, double fx, double fy) {
    const QColor c = image.pixelColor(int(fx * (image.width() - 1)), int(fy * (image.height() - 1)));
    return 0.2126 * c.redF() + 0.7152 * c.greenF() + 0.0722 * c.blueF();
}
double param(const PreviewController& c, const char* key) { return c.parameter(key).toDouble(); }

// --- the file side and the groups, no controller -------------------------------

void fileSide(const QString& scratch) {
    // Finder's order: numbers as numbers, case ignored; no subfolders, no
    // hidden or unopenable files.
    const QString roll = scratch + "/listing";
    check(QDir().mkpath(roll + "/sub"), "cannot create the listing folder");
    for (const char* name : {"IMG_2.NEF", "img_10.nef", "IMG_1.tif", "notes.txt", "Shot.PNG", "a.jpeg"})
        touch(roll + "/" + name);
    touch(roll + "/sub/inside.nef");
    check(base(library::folderFiles(roll)) == QStringList{"a.jpeg", "IMG_1.tif", "IMG_2.NEF", "img_10.nef", "Shot.PNG"},
          "a folder lists its photos in Finder's order: " + base(library::folderFiles(roll)).join(", "));
    check(library::openable("x.CR3") && library::openable("y.tiff") && !library::openable("z.heic") &&
              library::rawFile("q.ARW") && !library::rawFile("q.png"),
          "what opens, and what is a RAW");
    const auto expanded = library::expand({QUrl::fromLocalFile(roll), QUrl::fromLocalFile(roll + "/IMG_1.TIF"),
                                           QUrl::fromLocalFile(roll + "/notes.txt")});
    check(expanded.size() == 5, "a folder and one of its files again is each file once, and text is no photo");

    // FrameOrder.ordered: the named in the order named; each other after the
    // frame it follows in the listing, or first.
    const QStringList listed{"/f/a.nef", "/f/b.nef", "/f/c.nef", "/f/d.nef"};
    check(base(library::FrameOrder::ordered(listed, {"c.nef", "a.nef"})) == QStringList{"c.nef", "d.nef", "a.nef", "b.nef"},
          "unnamed frames follow their listing neighbour: " +
              base(library::FrameOrder::ordered(listed, {"c.nef", "a.nef"})).join(","));
    check(base(library::FrameOrder::ordered(listed, {})) == base(listed), "no order is the listing");
    check(library::FrameOrder::folderOf({roll + "/IMG_1.tif", roll + "/IMG_2.NEF"}) == QDir::cleanPath(roll) &&
              library::FrameOrder::folderOf({roll + "/IMG_1.tif", scratch + "/x.nef"}).isEmpty(),
          "an order is one folder's");
    const library::FrameOrder order(scratch + "/order-store");
    const QStringList dragged{roll + "/img_10.nef", roll + "/IMG_1.tif", roll + "/a.jpeg"};
    check(order.save(dragged), "a folder's order is kept");
    check(QFileInfo(order.fileFor(roll)).fileName().startsWith("listing-") &&
              QFileInfo(order.fileFor(roll)).fileName().endsWith(".order.json") &&
              order.fileFor(roll) == order.fileFor(roll.toUpper()),
          "one order file per folder, whatever the path's case");
    // IMG_2 follows IMG_1 (its listing neighbour), Shot follows img_10.
    check(base(order.applied(library::folderFiles(roll))) ==
              QStringList{"img_10.nef", "Shot.PNG", "IMG_1.tif", "IMG_2.NEF", "a.jpeg"},
          "the kept order over the listing: " + base(order.applied(library::folderFiles(roll))).join(", "));
    check(!order.save({roll + "/a.jpeg", scratch + "/elsewhere.nef"}), "frames from two folders keep no order");

    // The crop mask: outside the crop under 0.82 black, then the turns.
    QImage white(60, 40, QImage::Format_RGB32);
    white.fill(Qt::white);
    output::Geometry g;
    check(library::cropMasked(white, g).cacheKey() == white.cacheKey(), "no geometry, no new picture");
    g.crop = QRectF(0.25, 0.25, 0.5, 0.5);
    auto masked = library::cropMasked(white, g);
    check(masked.size() == white.size() && luma(masked, 0.5, 0.5) > 0.99 && std::abs(luma(masked, 0.05, 0.05) - 0.18) < 0.03,
          "the crop shows, the rest is masked (" + QString::number(luma(masked, 0.05, 0.05)) + ")");
    g.quarterTurns = 1;
    masked = library::cropMasked(white, g);
    check(masked.size() == QSize(40, 60), "turned as the canvas turns");
    g = {};
    g.straightenDegrees = 10;
    g.crop = QRectF(0.1, 0.1, 0.8, 0.8);
    for (const auto& p : library::cropCorners(QSizeF(600, 400), g))
        check(p.x() > 0.1 - 1e-9 && p.x() < 0.9 + 1e-9 && p.y() > 0.1 - 1e-9 && p.y() < 0.9 + 1e-9,
              "a straightened crop's corners lie inside the crop it zooms into");
}

void groups() {
    // SettingsClipboardTests: every settings row has exactly one owner or a
    // notCopied reason; a new row fails here until someone decides which.
    for (const auto& field : desktop::setting_fields())
        check(!clipboard::ownerOf(field.key).isEmpty(),
              QString::fromStdString("settings row " + field.key + " has no single clipboard owner"));
    check(clipboard::groups().size() == 7 && clipboard::offered().size() == 7, "the Mac's seven groups, all offered");
    check(clipboard::ownerOf("overscan_active") == "notCopied" && clipboard::ownerOf("date_imprint_style") == "notCopied" &&
              clipboard::ownerOf("print_exposure") == "exposure" && clipboard::ownerOf("contrast_mask_core") == "masks",
          "Film Edge and Date Back stay with the photo; the enlarger's brightness is exposure");

    desktop::RenderSettings source, target;
    source.set("exposure_compensation_ev", 1.5);
    source.set("grain_active", false);
    source.set("overscan_active", true);
    source.set("date_imprint_active", true);
    source.set("white_balance", std::string("as_shot"));
    source.set("white_balance_temperature", 3000.0);
    source.set("scene_latitude_active", true);
    source.set("scene_latitude_highlight_knee", 5.0);
    source.set("scene_latitude_highlight_pull_back", 2.0);
    target.set("white_balance", std::string("custom"));
    target.set("white_balance_temperature", 7000.0);
    // Each group alone touches its own rows and nothing else.
    for (const auto& g : clipboard::groups()) {
        const clipboard::Clip clip{{g.group}, source, "src.nef"};
        const auto out = clip.applied(target);
        for (const auto& field : desktop::setting_fields())
            if (out.get(field.key) != target.get(field.key))
                check(clipboard::ownerOf(field.key) == QLatin1String(g.id),
                      QString::fromStdString("group " + std::string(g.id) + " wrote " + field.key));
    }
    const clipboard::Clip all{clipboard::allGroups(), source, "src.nef"};
    const auto out = all.applied(target);
    check(std::get<double>(out.get("exposure_compensation_ev")) == 1.5 && !std::get<bool>(out.get("grain_active")),
          "the groups' settings are written");
    check(!std::get<bool>(out.get("overscan_active")) && !std::get<bool>(out.get("date_imprint_active")),
          "Film Edge and Date Back are never pasted");
    check(std::get<std::string>(out.get("white_balance")) == "as_shot" &&
              std::get<double>(out.get("white_balance_temperature")) == 7000.0,
          "As Shot is the target's camera: the source's Kelvin does not come with the word");
    check(!std::get<bool>(out.get("scene_latitude_active")) &&
              std::get<double>(out.get("scene_latitude_highlight_knee")) == 2.0 &&
              std::get<double>(out.get("scene_latitude_highlight_pull_back")) == 2.0 &&
              std::get<bool>(out.get("scene_latitude_needs_fit")),
          "Scene Placement carries its intent and waits for the target's own Fit");
    desktop::RenderSettings custom = source;
    custom.set("white_balance", std::string("custom"));
    check(std::get<double>(clipboard::Clip{{clipboard::Group::whiteBalance}, custom, "s"}.applied(target)
                               .get("white_balance_temperature")) == 3000.0,
          "a custom white balance comes with its numbers");
}

// --- the controller on a folder of PNGs ----------------------------------------

void controller(const std::filesystem::path& resources, const QString& scratch) {
    const QString roll = scratch + "/roll", edits = scratch + "/edits";
    check(QDir().mkpath(roll + "/sub"), "cannot create the roll");
    photo(roll + "/frame_1.png", 20);
    photo(roll + "/frame_2.png", 140);
    photo(roll + "/frame_10.png", 260);
    photo(roll + "/sub/hidden_away.png", 300);
    touch(roll + "/notes.txt");
    {
        PreviewController c(resources, nullptr, {}, edits);
        waitFor([&] { return c.ready() || c.failed(); }, "engine initialization");
        check(c.ready(), "engine: " + c.status());
        c.openFolder(QUrl::fromLocalFile(roll));
        idle(c, "open the roll");
        check(names(c) == QStringList{"frame_1.png", "frame_2.png", "frame_10.png"}, "Finder's order: " + names(c).join(", "));
        check(c.activeIndex() == 0 && c.metadata().value("raw") == false &&
                  c.metadata().value("input").toString() == "PNG, sRGB (assumed)",
              "a PNG opens, decoded at the door: " + c.metadata().value("input").toString());
        check(c.whiteBalance().value("raw") == false, "a flat file has no camera white balance to move");
        // The strip: the file's own picture at once, the render once there.
        waitFor([&] { return c.previewsPending() == 0; }, "the previews");
        for (const auto& item : c.libraryItems())
            check(!item.toMap().value("strip").value<QImage>().isNull(), "every photo has its picture in the strip");
        check(c.libraryItems()[0].toMap().value("rendered").toBool() && !c.libraryItems()[1].toMap().value("rendered").toBool(),
              "the open photo shows its print, the others their file");

        // The crop mask on the open photo's whole print.
        c.setCropRect(QRectF(0.25, 0.25, 0.5, 0.5));
        waitFor([&] { return c.pictureSettled(); }, "the cropped picture");  // made off the GUI thread
        const auto strip = c.libraryItems()[0].toMap().value("strip").value<QImage>();
        const auto thumb = c.libraryItems()[0].toMap().value("thumbnail").value<QImage>();
        check(std::abs(double(strip.width()) / strip.height() - 1.5) < 0.05 &&
                  std::abs(double(thumb.width()) / thumb.height() - 1.5) < 0.05 && strip.width() > thumb.width(),
              "the strip is the whole photo, the canvas's thumbnail the crop");
        check(luma(strip, 0.05, 0.05) < 0.4 * luma(strip, 0.45, 0.5), "outside the crop is masked in the strip");
        c.resetCrop();

        // Dragged along the strip: frame_10 to the front, the open photo with it.
        check(c.moveItem(2, 0), "a thumbnail moves");
        check(names(c) == QStringList{"frame_10.png", "frame_1.png", "frame_2.png"} && c.activeIndex() == 1,
              "the open photo keeps its place in the moved strip");
        c.itemOrderChanged();
        check(!QDir(edits + "/Order").entryList(QDir::Files).isEmpty(), "the order is kept beside the edits");

        // Selection (Session.click): one photo, then Ctrl+click without moving.
        c.clickPhoto(2, false);
        idle(c, "click the third photo");
        check(c.activeIndex() == 2 && picked(c) == QList<int>{2}, "a plain click picks one photo and opens it");
        c.clickPhoto(0, true);
        check(c.activeIndex() == 2 && picked(c) == (QList<int>{0, 2}), "Ctrl+click picks without moving the open photo");
        c.clickPhoto(2, true);
        check(picked(c) == (QList<int>{0, 2}), "the open photo cannot leave the set");
        c.clickPhoto(0, true);
        check(picked(c) == QList<int>{2}, "Ctrl+click takes a photo out again");
        c.stepPhoto(-1);
        idle(c, "step left");
        check(c.activeIndex() == 1 && picked(c) == QList<int>{1}, "Left steps as a plain click on the neighbour");
        c.stepPhoto(-5);
        idle(c, "step past the start");
        check(c.activeIndex() == 0, "stepping stops at the ends");

        // setParameters: ONE undo step for several rows; a bad value refuses
        // the whole edit.
        check(!c.canUndo(), "a photo opened afresh has no history");
        check(c.setParameters({{"grain_active", false}, {"halation_active", false}, {"glare_active", false}}),
              "all effects off as one edit");
        check(!c.parameter("grain_active").toBool() && !c.parameter("halation_active").toBool() &&
                  !c.parameter("glare_active").toBool() && c.canUndo(),
              "the three rows changed");
        c.undo();
        check(c.parameter("grain_active").toBool() && c.parameter("halation_active").toBool() &&
                  c.parameter("glare_active").toBool() && !c.canUndo(),
              "one undo takes all three back, and was the only step");
        check(!c.setParameters({{"grain_active", false}, {"grain_amount", 99.0}}) && c.parameter("grain_active").toBool(),
              "an out-of-range value refuses the whole edit");
        check(!c.setParameters({{"grain_active", 1}}) && !c.setParameters({{"no_such_row", true}}),
              "a wrong type or an unknown row is refused");
        c.setAdjustment("filmExposureEv", 1.25);
        check(c.setParameters({{"auto_exposure", false}, {"exposure_compensation_ev", 0}}) && c.aeMethod() == "custom" &&
                  param(c, "exposure_compensation_ev") == 0,
              "Film Exposure As Shot: the meter off and the exposure at zero");
        c.undo();
        check(c.aeMethod() != "custom" && param(c, "exposure_compensation_ev") == 1.25, "As Shot undoes as one step");
        idle(c, "the edits develop");
    }
    // The kept order over the listing; a new file after its neighbour.
    photo(roll + "/frame_5.png", 80);
    {
        PreviewController c(resources, nullptr, {}, edits);
        waitFor([&] { return c.ready() || c.failed(); }, "engine initialization (again)");
        c.openFolder(QUrl::fromLocalFile(roll));
        idle(c, "open the roll again");
        check(names(c) == QStringList{"frame_10.png", "frame_1.png", "frame_2.png", "frame_5.png"},
              "the folder's kept order, the new frame after its own neighbour: " + names(c).join(", "));
        check(c.activeIndex() == 0, "the first in the strip's order opens");
        waitFor([&] { return c.previewsPending() == 0; }, "the previews (again)");

        // The clipboard: exposure only, from frame_10 onto frame_1 and frame_2.
        for (const auto& g : clipboard::groups()) c.setClipboardGroup(QLatin1String(g.id), g.group == clipboard::Group::exposure);
        check(QSettings(edits + "/preferences.ini", QSettings::IniFormat).value("clipboard/groups").toStringList() ==
                  QStringList{"exposure"},
              "the boxes are kept");
        check(c.setParameters({{"exposure_compensation_ev", 1.5}, {"grain_active", false}, {"overscan_active", true}}),
              "the source's edit");
        c.setCropRect(QRectF(0.1, 0.1, 0.5, 0.5));
        idle(c, "the source develops");
        check(c.copySettings() && c.clipboardState().value("holds").toBool() &&
                  c.clipboardState().value("groups").toStringList() == QStringList{"exposure"},
              "Copy takes the ticked group");
        c.setClipboardGroup("filmEffects", true);
        check(c.heldClip()->groups == QSet<clipboard::Group>{clipboard::Group::exposure},
              "a box ticked after copying does not change what is held");
        // A plain click on the open photo picks it alone (an import picks all).
        c.clickPhoto(0, false);
        check(picked(c) == QList<int>{0}, "a click on the open photo collapses the set to it");
        c.clickPhoto(1, true);
        c.clickPhoto(2, true);
        check(c.clipboardState().value("pasteTargets").toInt() == 3 && c.clipboardState().value("syncTargets").toInt() == 2,
              "Paste goes to every picked photo, Sync to the others");
        check(c.pasteSettings() == 2, "Paste wrote the two photos that differed (the source already has it)");
        c.clickPhoto(1, false);
        idle(c, "open a pasted photo");
        check(param(c, "exposure_compensation_ev") == 1.5 && c.parameter("grain_active").toBool() &&
                  !c.parameter("overscan_active").toBool() && c.cropRect() == QRectF(0, 0, 1, 1),
              "only the held group arrived: not Film Effects, Film Edge or the crop");
        check(c.canUndo(), "the recipient has its own undo step");
        c.undo();
        check(param(c, "exposure_compensation_ev") == 0, "and undoes it alone");
        idle(c, "undo the paste");

        // Sync: a fresh copy of the open photo's ticked groups (now exposure
        // and film effects) onto the other picked photos.
        c.clickPhoto(0, false);
        idle(c, "back to the source");
        c.clickPhoto(3, true);
        c.syncSelectedSettings(false);
        c.clickPhoto(3, false);
        idle(c, "open the synced photo");
        check(param(c, "exposure_compensation_ev") == 1.5 && !c.parameter("grain_active").toBool() &&
                  !c.parameter("overscan_active").toBool() && c.cropRect() == QRectF(0, 0, 1, 1),
              "Sync wrote the ticked groups and kept Film Edge and the crop the photo's own");
        check(c.heldClip()->groups == QSet<clipboard::Group>{clipboard::Group::exposure}, "Sync leaves the clipboard alone");
        // The live paste is one undo step on the open photo.
        c.setParameters({{"exposure_compensation_ev", -1.0}});
        c.clickPhoto(3, false);
        while (c.canUndo()) c.undo();
        c.selectAllPhotos(false);
        check(c.clipboardState().value("pasteTargets").toInt() == 1, "with none picked, Paste goes to the open photo");
        check(c.pasteSettings() == 1 && param(c, "exposure_compensation_ev") == 1.5 && c.canUndo(),
              "the open photo takes the paste live");
        c.undo();
        check(param(c, "exposure_compensation_ev") == 0 && !c.canUndo(), "as one undo step");
        idle(c, "the live paste develops");

        // Nothing changes the photos during a batch export (trap 34).
        const QString out = scratch + "/batch";
        check(QDir().mkpath(out), "cannot create the batch folder");
        c.selectAllPhotos(true);
        c.exportBatch(QUrl::fromLocalFile(out), 1, 90, 64);
        check(c.batchExporting(), "a batch export runs");
        check(!c.clipboardState().value("canPaste").toBool() && !c.clipboardState().value("canSync").toBool() &&
                  c.pasteSettings() == 0 && !c.moveItem(0, 1),
              "Paste, Sync and reordering wait for the batch");
        const int open = c.activeIndex();
        c.clickPhoto(3, false);
        c.stepPhoto(1);
        check(c.activeIndex() == open, "clicks and arrows wait for the batch");
        idle(c, "the batch");
    }
    {
        PreviewController c(resources, nullptr, {}, edits);
        waitFor([&] { return c.ready() || c.failed(); }, "engine initialization (third)");
        const auto boxes = c.clipboardGroups();
        int ticked = 0;
        for (const auto& b : boxes) ticked += b.toMap().value("ticked").toBool();
        check(ticked == 2, "the boxes come back as they were left");
    }
}

}  // namespace

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", QByteArray("offscreen"));
    QGuiApplication application(argc, argv);
    try {
        const auto args = application.arguments();
        check(args.size() == 3, "usage: spk_qt_library_test <resources> <scratch directory>");
        // A new run directory inside it each time: the edits, the kept order
        // and the boxes are part of what is tested, so no run may inherit them.
        const QString scratch = QDir(QFileInfo(args[2]).absoluteFilePath())
                                    .filePath("run-" + QString::number(QDateTime::currentMSecsSinceEpoch()));
        check(!QFileInfo::exists(scratch) && QDir().mkpath(scratch), "cannot create a new run directory");
        fileSide(scratch);
        groups();
        controller(std::filesystem::path(args[1].toStdWString()), scratch);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "FAIL after %d checks: %s\n", checks, e.what());
        return 1;
    }
    std::printf("spk_qt_library: %d checks passed\n", checks);
    return 0;
}
