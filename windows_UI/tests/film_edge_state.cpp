// Film Edge and Date Back in the controller and the edit store, without a
// RAW: the rows and their product rows as QML sees them, the macOS rules the
// sections lean on (a Date Back switched on takes a face it can print, the
// crop held by the gate, the user's body), what a record keeps across a save
// and a load -- the rows, the typed text and the held crop -- and that Sync
// copies neither section. The real engine supplies the catalogue; the
// scratch directory holds the edit store and one dummy source file.
#include "PreviewController.hpp"
#include "EditStore.hpp"
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QTimer>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace desktop = spk::desktop;
namespace editing = spk::desktop::editing;
namespace output = spk::desktop::output;
namespace {
int checks = 0;
void check(bool value, const std::string& message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
QVariantMap row(const PreviewController& c, const QString& key) {
    for (const auto& entry : c.parameterFields())
        if (entry.toMap().value("key") == key) return entry.toMap();
    throw std::runtime_error("parameterFields lacks " + key.toStdString());
}
}  // namespace

int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    try {
        const auto args = application.arguments();
        check(args.size() == 3, "usage: spk_qt_film_edge_state_test <resources> <scratch-root>");
        // A new directory per run under the root, so a rerun never meets the
        // last run's records.
        const auto run = QDir(args[2]).absoluteFilePath(QStringLiteral("run-%1-%2")
            .arg(QDateTime::currentMSecsSinceEpoch()).arg(QCoreApplication::applicationPid()));
        check(!QFileInfo::exists(run) && QDir().mkpath(run), "the scratch directory must be new");
        const QDir scratch(run);
        const auto edits = scratch.absoluteFilePath("edits");
        PreviewController c(std::filesystem::path(args[1].toStdWString()), nullptr, {}, edits);
        {
            QEventLoop wait;
            QObject::connect(&c, &PreviewController::initialized, &wait, &QEventLoop::quit);
            QTimer::singleShot(60000, &wait, &QEventLoop::quit);
            if (!c.ready() && !c.failed()) wait.exec();
        }
        check(c.ready(), "engine initialization: " + c.status().toStdString());

        // The rows: engine fields are sent, the product rows are not.
        for (const char* key : {"overscan_active", "overscan_format", "overscan_mode", "overscan_gate", "overscan_holes",
                                "overscan_carrier", "overscan_camera_seed", "overscan_frame_seed",
                                "overscan_frame_number", "overscan_fog", "overscan_leaks", "date_imprint_active",
                                "date_imprint_style", "date_imprint_placement", "date_imprint_corner",
                                "date_imprint_inset_x", "date_imprint_inset_y", "date_imprint_size", "date_imprint_ev"})
            check(row(c, key).value("sent").toBool(), std::string("not sent: ") + key);
        for (const char* key : {"film_edge_seeded", "date_back_order", "date_back_with_data", "date_back_text_source",
                                "date_back_custom_text"})
            check(!row(c, key).value("sent").toBool(), std::string("a product row is sent: ") + key);
        check(row(c, "overscan_format").value("choices").toStringList() ==
                  QStringList{"135", "135_half", "120_645", "120_6x6", "120_6x7", "120_6x8", "120_6x9", "135_xpan",
                              "120_6x12", "120_6x17"}, "format choices");
        check(c.filmFormats().size() == 10 && c.filmFormats()[1].toMap().value("title") == "Half" &&
              c.filmFormats()[4].toMap().value("gate").toString().contains("69.5"), "the Format menu");
        check(!c.parameter("overscan_active").toBool() && !c.parameter("date_imprint_active").toBool() &&
              c.parameter("overscan_format") == "135" && c.parameter("date_imprint_ev").toDouble() == 3.5 &&
              c.parameter("date_back_order") == "japan", "defaults");

        // Refusals: a format the engine lacks, a frame past 99, text the
        // faces cannot print.
        const auto refused = [&](const char* key, const QVariant& value, const char* why) {
            const auto was = c.parameters();
            check(!c.setParameter(key, value) && c.parameters() == was, std::string("accepted: ") + why);
        };
        refused("overscan_format", QStringLiteral("110"), "an unknown format");
        refused("overscan_frame_number", 100.0, "frame 100");
        refused("date_imprint_corner", QStringLiteral("middle"), "an unknown corner");
        refused("date_back_custom_text", QStringLiteral("two\nlines"), "a line break");
        refused("date_back_custom_text", QString(33, QChar('1')), "33 characters");
        check(c.setParameter("date_back_custom_text", QStringLiteral("'26 10 1")) &&
              c.parameter("date_back_custom_text") == "'26 10 1", "typed text");

        // A Date Back switched on takes a face its camera prints: without a
        // film edge the data face has nowhere to go (DateBackSection.setActive).
        check(c.setParameter("date_imprint_style", QStringLiteral("data")), "choose the data face while off");
        check(c.dateBack().value("prints").toMap().value("data") == false &&
              c.dateBack().value("prints").toMap().value("lcd") == true && c.dateBack().value("camera") == "135",
              "the bare 135 frame's faces");
        check(c.setDateBackActive(true) && c.parameter("date_imprint_style") == "lcd" &&
              c.dateBack().value("effective").toBool(), "switching on did not take a printable face");

        // The film edge: its camera prints every face, the crop editor holds
        // the gate's shape, and its edge print comes from the stock.
        check(!c.geometryInNegative() || c.parameter("date_imprint_active").toBool(), "geometry state");
        check(c.cropLockRatio() == 0, "a crop held without a film edge");
        check(c.setFilmEdgeActive(true) && c.parameter("overscan_active").toBool(), "switch the film edge on");
        check(c.cropLockRatio() == 1.5 && c.geometryInNegative(), "the 135 gate does not hold the crop");
        check(c.dateBack().value("cameraFromEdge").toBool() && c.dateBack().value("dataPrintable").toBool() &&
              c.dateBack().value("prints").toMap().value("data") == true, "the film edge's camera");
        check(c.filmEdge().value("edgeText").toString() == "KODAK PORTRA 400", "edge print of Portra 400: " +
              c.filmEdge().value("edgeText").toString().toStdString());
        check(c.setParameter("overscan_format", QStringLiteral("120_6x6")) && std::abs(c.cropLockRatio() - 1.0) < 1e-12 &&
              c.dateBack().value("printsInMargin").toBool(), "6x6 holds a square and prints in the margin");
        check(c.setParameter("overscan_format", QStringLiteral("120_6x17")) &&
              !c.dateBack().value("hasBack").toBool() && !c.dateBack().value("effective").toBool(),
              "a panoramic camera printed a date");
        c.setParameter("overscan_format", QStringLiteral("135"));
        c.setParameter("film_stock", QStringLiteral("kodak_gold_200"));
        check(c.filmEdge().value("edgeText") == "KODAK GB 200-7", "Gold 200's own edge print");

        // The body is the user's: Another draws a new one, kept beside the
        // edit store for new frames.
        const double before = c.parameter("overscan_camera_seed").toDouble();
        c.anotherCameraBody();
        const double body = c.parameter("overscan_camera_seed").toDouble();
        check(body != before && body >= 1 && body <= 999 && c.bodySeed() == int(body), "Another body");
        check(QSettings(edits + "/preferences.ini", QSettings::IniFormat).value("filmEdge/bodySeed").toInt() == int(body),
              "the body is not kept for new frames");
        const double frameSeed = c.parameter("overscan_frame_seed").toDouble();
        c.anotherFrameAdvance();
        check(c.parameter("overscan_frame_seed").toDouble() != frameSeed, "Another frame");

        // Reset is a new photograph's settings, but the frame keeps its seeds.
        c.resetSettings();
        check(!c.parameter("overscan_active").toBool() && !c.parameter("date_imprint_active").toBool() &&
              c.parameter("overscan_camera_seed").toDouble() == body, "reset lost the body or kept the film edge");

        // Sync copies neither section (SettingsClipboard.swift:75-76).
        {
            desktop::RenderSettings from, to;
            from.set("overscan_active", true);
            from.set("date_back_text_source", std::string("typed"));
            from.halation_active = false;
            to.set("overscan_frame_number", 4.0);
            const auto synced = desktop::synced_settings(from, to);
            check(!synced.halation_active && !std::get<bool>(synced.get("overscan_active")) &&
                  synced.get("date_back_text_source") == desktop::SettingValue(std::string("exif")) &&
                  synced.get("overscan_frame_number") == desktop::SettingValue(4.0), "sync rules");
        }

        // The record: every new row, the typed text and the held crop survive
        // a save and a load; a save without a held crop clears it; a record
        // from before the rows loads at the engine's defaults.
        const auto source = scratch.absoluteFilePath("source/frame.NEF");
        check(QDir().mkpath(scratch.absoluteFilePath("source")), "source folder");
        {
            QFile f(source);
            check(f.open(QIODevice::WriteOnly | QIODevice::NewOnly) && f.write(QByteArray(4096, 'x')) == 4096,
                  "dummy source");
        }
        const auto url = QUrl::fromLocalFile(source);
        const auto catalog = desktop::read_catalog(std::filesystem::path(args[1].toStdWString()));
        const auto store = scratch.absoluteFilePath("store");
        editing::State state;
        state.settings.set("overscan_active", true);
        state.settings.set("overscan_format", std::string("120_6x7"));
        state.settings.set("overscan_frame_number", 23.0);
        state.settings.set("overscan_camera_seed", 412.0);
        state.settings.set("overscan_fog", 2.25);
        state.settings.set("overscan_carrier", std::string("black"));
        state.settings.set("film_edge_seeded", true);
        state.settings.set("date_imprint_active", true);
        state.settings.set("date_imprint_corner", std::string("tl"));
        state.settings.set("date_back_order", std::string("us"));
        state.settings.set("date_back_with_data", true);
        state.settings.set("date_back_text_source", std::string("typed"));
        state.settings.set("date_back_custom_text", std::string("SPEKTRA 26"));
        state.geometry.crop = QRectF(0.1, 0.0, 0.62, 1.0);
        state.heldGeometry = output::Geometry{QRectF(0.2, 0.2, 0.5, 0.5), 1, true, false, 2.5};
        {
            editing::Store s(store);
            check(!s.load(url, catalog).state, "a new store has a record");
            s.save(url, state);
        }
        {
            editing::Store s(store);
            const auto loaded = s.load(url, catalog);
            check(loaded.state && *loaded.state == state && loaded.preserved.isEmpty(),
                  "the film edge record did not round-trip");
            auto cleared = state;
            cleared.heldGeometry.reset();
            s.save(url, cleared);
            check(*editing::Store(store).load(url, catalog).state == cleared, "a save without a held crop kept the old one");
        }
        {
            // A version-2 record from before these rows and the held crop.
            const auto path = editing::Store(store).filePath(url);
            QFile f(path);
            check(f.open(QIODevice::ReadOnly), "read the record");
            auto document = QJsonDocument::fromJson(f.readAll()).object();
            f.close();
            auto st = document["state"].toObject();
            auto settings = st["settings"].toObject();
            for (const auto& field : desktop::setting_fields())
                if (desktop::per_photo_setting(field.key)) settings.remove(QString::fromStdString(field.key));
            st["settings"] = settings;
            st.remove("heldGeometry");
            document["state"] = st;
            check(f.open(QIODevice::WriteOnly | QIODevice::Truncate) &&
                      f.write(QJsonDocument(document).toJson()) > 0, "write the older record");
            f.close();
            const auto old = editing::Store(store).load(url, catalog);
            check(old.state && !old.state->heldGeometry && old.preserved.isEmpty(), "an older record failed to load");
            for (const auto& field : desktop::setting_fields())
                if (desktop::per_photo_setting(field.key))
                    check(old.state->settings.get(field.key) == field.absent, "an older record's " + field.key);
        }
        std::printf("Film edge state: %d checks passed; no RAW.\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "Film edge state FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
