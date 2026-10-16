// Temporary source files and an explicit store root: this test never reads or
// writes the user's real edit history and needs neither a RAW decoder nor GPU.
#include "EditStore.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QTemporaryDir>
#include <cstdio>
#include <functional>
#include <limits>
#include <stdexcept>

namespace editing = spk::desktop::editing;
namespace {
int checks = 0;
void check(bool value, const char* message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
void rejects(const std::function<void()>& action, const char* message) {
    try { action(); } catch (const std::exception&) { ++checks; return; }
    throw std::runtime_error(message);
}
QByteArray read(const QString& path) {
    QFile file(path);
    check(file.open(QIODevice::ReadOnly), "cannot read test file");
    return file.readAll();
}
void write(const QString& path, const QByteArray& bytes) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly | QIODevice::Truncate), "cannot write test file");
    check(file.write(bytes) == bytes.size(), "incomplete test write");
}
QByteArray digest(const QString& path) {
    return QCryptographicHash::hash(read(path), QCryptographicHash::Sha256);
}
void mutateObject(QJsonObject& parent, const char* name,
                  const std::function<void(QJsonObject&)>& change) {
    auto child = parent.value(QLatin1String(name)).toObject();
    change(child);
    parent.insert(QLatin1String(name), child);
}
void mutateSettings(QJsonObject& document, const std::function<void(QJsonObject&)>& change) {
    mutateObject(document, "state", [&](auto& s) { mutateObject(s, "settings", change); });
}
// Version 1's thirteen settings, under their version 2 names.
const QStringList version1Keys{"film_stock", "print_stock", "print_exposure", "exposure_compensation_ev",
                               "film_format_mm", "grain_active", "grain_amount", "halation_active",
                               "halation_amount", "glare_active", "glare_amount", "y_filter_shift", "m_filter_shift"};
// The same record as version 1 wrote it: thirteen settings, film exposure
// under its old name, nothing added since.
QJsonObject toVersion1(QJsonObject document) {
    document["version"] = 1;
    mutateSettings(document, [](auto& f) {
        for (const auto& field : spk::desktop::setting_fields())
            if (!version1Keys.contains(QString::fromStdString(field.key))) f.remove(QString::fromStdString(field.key));
        f["film_exposure_ev"] = f.take("exposure_compensation_ev");
    });
    // Version 1 had no held crop either (a film edge's, added in version 2).
    mutateObject(document, "state", [](auto& s) { s.remove("heldGeometry"); });
    return document;
}
QByteArray bytesOf(const QJsonObject& document) { return QJsonDocument(document).toJson(); }
} // namespace

int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    try {
        // CTest passes a scratch root in the build tree; a manual run without
        // one falls back to the system temporary folder.
        const auto scratch = application.arguments().value(1);
        check(scratch.isEmpty() || QDir().mkpath(scratch), "cannot create scratch root");
        QTemporaryDir temporary(scratch.isEmpty() ? QDir::tempPath() + "/spk-edit-store-XXXXXX"
                                                  : scratch + "/run-XXXXXX");
        check(temporary.isValid(), "temporary root unavailable");
        // CJK folder and file names with spaces, written as escapes: the
        // store must handle non-ASCII paths whatever the system code page.
        const auto sources = temporary.filePath(QString::fromUtf8("\u7167\u7247 \u6587\u4ef6\u5939"));
        check(QDir().mkpath(sources), "cannot create source folder");
        const auto source = QDir(sources).filePath(QString::fromUtf8("\u6d77\u8fb9 \u65e5\u843d.ARW"));
        QByteArray input(200000, 'R');
        for (qsizetype i = 0; i < input.size(); ++i) input[i] = char((i * 31 + i / 257) % 251);
        write(source, input);
        const auto originalHash = digest(source);
        const auto originalTime = QFileInfo(source).lastModified();
        const QUrl url = QUrl::fromLocalFile(source);
        const auto root = temporary.filePath("editor-state");
        const editing::Store store(root);
        const spk::desktop::Catalog catalog{
            {{"kodak_portra_400", "Portra", false}, {"fuji_provia_100f", "Provia", true}},
            {{"kodak_portra_endura", "Portra paper", false}, {"fuji_crystal", "Crystal", false},
             {"kodak_supra_endura", "Supra paper", false}}};
        check(!store.load(url, catalog).state && !QFileInfo::exists(root),
              "reading missing state must not create a directory");
        check(!store.load(url, catalog).blocked, "missing state is not blocked");
        rejects([&] { editing::Store invalid(QString{}); }, "empty store directory accepted");
        rejects([&] { editing::Store invalid("relative/path"); }, "relative store directory accepted");
        rejects([&] { (void)store.filePath(QUrl("https://example.com/photo.ARW")); },
                "remote source URL accepted");
        editing::State state;
        state.settings.film_stock = "fuji_provia_100f";
        state.settings.print_stock = "fuji_crystal";
        state.settings.print_exposure = 0.625;
        state.settings.film_exposure_ev = -2.25;
        state.settings.film_format_mm = 61.5;
        state.settings.grain_active = false;
        state.settings.grain_amount = 0.3125;
        state.settings.halation_active = false;
        state.settings.halation_amount = 2.625;
        state.settings.glare_active = false;
        state.settings.glare_amount = 11.25;
        state.settings.y_filter_shift = -0.3125;
        state.settings.m_filter_shift = 0.375;
        // Rows stored by key, not by named member, round-trip the same way.
        state.settings.set("filter_shift_scale", 12.5);
        state.settings.set("auto_exposure_method", std::string("protect_highlights"));
        state.mode = spk::desktop::DecodeMode::headroom;
        state.geometry.crop = QRectF(0.125, 0.25, 0.5, 0.625);
        state.geometry.quarterTurns = 3;
        state.geometry.flipHorizontal = true;
        state.geometry.flipVertical = true;
        state.geometry.straightenDegrees = -12.75;
        store.save(url, state);
        const auto path = store.filePath(url);
        const auto result = store.load(url, catalog);
        check(result.state && *result.state == state && result.warning.isEmpty() && !result.blocked,
              "complete state did not roundtrip exactly");
        check(result.version == 2 && result.preserved.isEmpty(), "new record is not a plain version 2");
        {
            // Version 2 keys every table row by its wire name.
            const auto written = QJsonDocument::fromJson(read(store.filePath(url))).object();
            const auto settings = written["state"].toObject()["settings"].toObject();
            check(written["version"].toInt() == 2 && settings.size() == qsizetype(spk::desktop::setting_fields().size()),
                  "version 2 does not write every settings row");
            for (const auto& field : spk::desktop::setting_fields())
                check(settings.contains(QString::fromStdString(field.key)), "version 2 omitted a settings row");
            check(!settings.contains("film_exposure_ev") && settings["exposure_compensation_ev"].toDouble() == -2.25,
                  "version 2 kept the version 1 spelling");
        }
        check(QFileInfo(path).absolutePath() == root && QFileInfo(path).fileName().size() == 69,
              "edit file must be a hash inside the explicit store");
        check(QDir(sources).entryList(QDir::Files).size() == 1,
              "edit store wrote next to the source photograph");
        check(digest(source) == originalHash && QFileInfo(source).lastModified() == originalTime,
              "saving edits touched source bytes or modification time");
        const editing::Store reopened(root);
        check(reopened.load(url, catalog).state == result.state,
              "new store instance did not restore saved edits");
#ifdef _WIN32
        check(store.filePath(QUrl::fromLocalFile(source.toUpper())) == path,
              "Windows path case created two histories");
#endif
        const auto relativeEquivalent = QDir(sources).filePath("../" + QFileInfo(sources).fileName() + "/" + QFileInfo(source).fileName());
        check(store.filePath(QUrl::fromLocalFile(relativeEquivalent)) == path,
              "equivalent local paths created two histories");
        state.settings.print_exposure = 1.25;
        state.geometry.quarterTurns = 1;
        store.save(url, state);
        check(store.load(url, catalog).state == std::optional(state), "atomic update did not replace prior state");
        const auto validBytes = read(path);
        const auto validJson = QJsonDocument::fromJson(validBytes).object();
        rejects([&] { reopened.save(url, state); },
                "second instance overwrote edits saved since its load");
        check(read(path) == validBytes, "optimistic conflict changed existing edits");
        check(reopened.load(url, catalog).state == std::optional(state),
              "reopening did not refresh conflict observation");
        reopened.save(url, state);

        auto corruptFrom = [&](const QJsonObject& base, const std::function<void(QJsonObject&)>& change) {
            auto document = base;
            change(document);
            const auto bytes = QJsonDocument(document).toJson();
            write(path, bytes);
            const auto rejected = store.load(url, catalog);
            check(!rejected.state && rejected.blocked && !rejected.warning.isEmpty(),
                  "invalid document loaded or failed without a warning");
            rejects([&] { store.save(url, state); }, "save replaced an incompatible or corrupt record");
            check(read(path) == bytes, "rejected save changed existing edit history");
            write(path, validBytes);
        };
        auto corrupt = [&](const std::function<void(QJsonObject&)>& change) { corruptFrom(validJson, change); };
        auto geometryOf = [](const std::function<void(QJsonObject&)>& change) {
            return [change](QJsonObject& d) { mutateObject(d, "state", [&](auto& s) { mutateObject(s, "geometry", change); }); };
        };
        // Version 2 is strict about everything it knows.
        corrupt([](auto& d) { d["version"] = 3; });
        corrupt([](auto& d) { d["version"] = 99; });
        corrupt([](auto& d) { d["version"] = "2"; });
        corrupt([](auto& d) { d["version"] = 1.5; });
        corrupt([](auto& d) { d["format"] = "Unrelated.Application"; });
        corrupt([](auto& d) { d.remove("format"); });
        corrupt([](auto& d) { d.remove("source"); });
        corrupt([](auto& d) { d.remove("state"); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["path"] = "D:/different.ARW"; }); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["size"] = 123; }); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["sampleSha256"] = "broken"; }); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["volume"] = "C:"; }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) { s["decodeMode"] = "future-decoder"; }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) { s.remove("geometry"); }); });
        // Version 1's keys stay required: a record without one is damaged.
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f.remove("film_format_mm"); }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["film_exposure_ev"] = f.take("exposure_compensation_ev"); }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["grain_active"] = 1; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["print_exposure"] = "1.0"; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["exposure_compensation_ev"] = 8.01; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["film_stock"] = "../bad"; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["filter_shift_scale"] = 0.5; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["filter_shift_scale"] = "40"; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["auto_exposure_method"] = "spot"; }); });
        corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["auto_exposure_method"] = true; }); });
        corrupt(geometryOf([](auto& g) { g["quarterTurns"] = 0.5; }));
        corrupt(geometryOf([](auto& g) { g["straightenDegrees"] = -45.1; }));
        corrupt(geometryOf([](auto& g) { g["flipVertical"] = "false"; }));
        corrupt(geometryOf([](auto& g) { mutateObject(g, "crop", [](auto& c) { c["width"] = 0; }); }));
        corrupt(geometryOf([](auto& g) { mutateObject(g, "crop", [](auto& c) { c["width"] = 1; }); }));
        corrupt(geometryOf([](auto& g) { mutateObject(g, "crop", [](auto& c) { c["angle"] = 0; }); }));

        // Version 1, as that build wrote it, loads with what it was made
        // with: the engine's metering, and the engine's filter scale while a
        // shift is non-zero. It keeps its own exact shape.
        const auto version1 = toVersion1(validJson);
        auto madeWith = state;
        madeWith.settings.set("filter_shift_scale", 1.0);
        madeWith.settings.set("auto_exposure_method", std::string("center_weighted"));
        write(path, bytesOf(version1));
        const auto legacy = store.load(url, catalog);
        check(legacy.state == std::optional(madeWith) && legacy.version == 1 && !legacy.blocked &&
              legacy.preserved.isEmpty(), "version 1 record did not load as it was made");
        corruptFrom(version1, [](auto& d) { d["version"] = "1"; });
        corruptFrom(version1, [](auto& d) { d["format"] = "Unrelated.Application"; });
        corruptFrom(version1, [](auto& d) { d["futureField"] = true; });
        corruptFrom(version1, [](auto& d) { d.remove("source"); });
        corruptFrom(version1, [](auto& d) { mutateObject(d, "state", [](auto& s) { s["mask"] = 1; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f.remove("film_format_mm"); }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["filter_shift_scale"] = 40; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["exposure_compensation_ev"] = 0; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["grain_active"] = 1; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["print_exposure"] = "1.0"; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["film_exposure_ev"] = 8.01; }); });
        corruptFrom(version1, [](auto& d) { mutateSettings(d, [](auto& f) { f["film_stock"] = "../bad"; }); });
        corruptFrom(version1, geometryOf([](auto& g) { g["quarterTurns"] = 0.5; }));
        corruptFrom(version1, geometryOf([](auto& g) { g["perspective"] = 0; }));
        corruptFrom(version1, geometryOf([](auto& g) { mutateObject(g, "crop", [](auto& c) { c["width"] = 0; }); }));
        {
            // With both shifts at zero the scale cannot move the print, so
            // the photograph takes the macOS slider strength.
            auto neutral = version1;
            mutateSettings(neutral, [](auto& f) { f["y_filter_shift"] = 0; f["m_filter_shift"] = 0; });
            write(path, bytesOf(neutral));
            const auto loaded = store.load(url, catalog);
            check(loaded.state && loaded.state->settings.get("filter_shift_scale") == spk::desktop::SettingValue(40.0) &&
                  loaded.state->settings.get("auto_exposure_method") == spk::desktop::SettingValue(std::string("center_weighted")),
                  "neutral version 1 filters did not take the new scale");
            mutateSettings(neutral, [](auto& f) { f["m_filter_shift"] = 0.01; });
            write(path, bytesOf(neutral));
            check(store.load(url, catalog).state->settings.get("filter_shift_scale") == spk::desktop::SettingValue(1.0),
                  "a version 1 filter shift lost the scale it was made with");
        }
        // The first save rewrites a version-1 record as version 2.
        write(path, bytesOf(version1));
        check(store.load(url, catalog).version == 1, "version 1 record not reloaded");
        store.save(url, madeWith);
        const auto migrated = store.load(url, catalog);
        check(QJsonDocument::fromJson(read(path)).object()["version"].toInt() == 2 && migrated.version == 2 &&
              migrated.state == std::optional(madeWith), "saving a version 1 record did not migrate it");
        write(path, validBytes);
        check(store.load(url, catalog).state == std::optional(state), "restored version 2 record did not reload");

        {
            // Rows added after version 1 are optional; absent, each takes what
            // the record rendered with, the engine default.
            auto older = validJson;
            mutateSettings(older, [](auto& f) { f.remove("filter_shift_scale"); f.remove("auto_exposure_method"); });
            write(path, bytesOf(older));
            const auto loaded = store.load(url, catalog);
            check(loaded.state == std::optional(madeWith) && loaded.version == 2 && loaded.preserved.isEmpty(),
                  "an optional row did not default to what the record rendered with");
            write(path, validBytes);
        }
        {
            // The macOS Film and Print rows: each round-trips away from its
            // default, and a record from before them loads each as `absent`.
            check(store.load(url, catalog).state == std::optional(state), "record before the new rows");
            auto extended = state;
            extended.settings.set("auto_exposure", false);
            extended.settings.set("scan_film", true);
            extended.settings.set("print_effects", false);
            extended.settings.set("preflash_exposure", 0.0225);
            extended.settings.set("antihalation_removed", true);
            extended.settings.set("halation_scatter_amount", 0.375);
            extended.settings.set("halation_boost_ev", 2.5);
            extended.settings.set("dir_couplers_active", false);
            extended.settings.set("dir_couplers_amount", 1.25);
            extended.settings.set("grain_sublayers_active", false);
            store.save(url, extended);
            check(store.load(url, catalog).state == std::optional(extended), "the new rows did not round-trip");
            const QStringList added{"auto_exposure", "scan_film", "print_effects", "preflash_exposure",
                                    "antihalation_removed", "halation_scatter_amount", "halation_boost_ev",
                                    "dir_couplers_active", "dir_couplers_amount", "grain_sublayers_active"};
            auto before = QJsonDocument::fromJson(read(path)).object();
            mutateSettings(before, [&](auto& f) { for (const auto& key : added) f.remove(key); });
            write(path, bytesOf(before));
            const auto loaded = store.load(url, catalog);
            check(loaded.state && loaded.version == 2 && loaded.preserved.isEmpty(), "a record without the new rows");
            for (const auto& key : added) {
                const auto* field = spk::desktop::find_setting(key.toStdString());
                check(field && loaded.state->settings.get(field->key) == field->absent,
                      "a missing new row did not take what the record was made with");
            }
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["preflash_exposure"] = 0.031; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["print_effects"] = 1; }); });
            write(path, validBytes);
            check(store.load(url, catalog).state == std::optional(state), "restored record after the new rows");
        }
        {
            // The Pre-Dev rows -- white balance, Scene Placement's curve and
            // UI state, the Tone Mask -- the same way: version 2's optional
            // keys, round-tripped away from default, `absent` when missing,
            // refused outside their ranges and choices.
            auto predev = state;
            predev.settings.set("white_balance", std::string("custom"));
            predev.settings.set("white_balance_temperature", 3150.0);
            predev.settings.set("white_balance_tint", -12.5);
            predev.settings.set("scene_latitude_active", true);
            predev.settings.set("scene_latitude_norm", std::string("y"));
            predev.settings.set("scene_latitude_highlight_knee", 0.875);
            predev.settings.set("scene_latitude_highlight_room", 1.625);
            predev.settings.set("scene_latitude_shadow_knee", -1.25);
            predev.settings.set("scene_latitude_shadow_room", 2.5);
            predev.settings.set("scene_latitude_rolloff", 3.0);
            predev.settings.set("scene_latitude_max_lift", 6.0);
            predev.settings.set("scene_latitude_highlight_pull_back", 1.5);
            predev.settings.set("scene_latitude_shadow_pull_back", 0.75);
            predev.settings.set("scene_latitude_needs_fit", true);
            predev.settings.set("contrast_mask_active", true);
            predev.settings.set("contrast_mask_highlights", 1.25);
            predev.settings.set("contrast_mask_shadows", 0.5);
            predev.settings.set("contrast_mask_core", 2.0);
            predev.settings.set("contrast_mask_scale", 0.05);
            store.save(url, predev);
            check(store.load(url, catalog).state == std::optional(predev), "the Pre-Dev rows did not round-trip");
            const QStringList added{"white_balance", "white_balance_temperature", "white_balance_tint",
                "scene_latitude_active", "scene_latitude_norm", "scene_latitude_highlight_knee",
                "scene_latitude_highlight_room", "scene_latitude_shadow_knee", "scene_latitude_shadow_room",
                "scene_latitude_rolloff", "scene_latitude_max_lift", "scene_latitude_highlight_pull_back",
                "scene_latitude_shadow_pull_back", "scene_latitude_needs_fit", "contrast_mask_active",
                "contrast_mask_highlights", "contrast_mask_shadows", "contrast_mask_core", "contrast_mask_scale",
                "contrast_mask_scheme"};
            auto before = QJsonDocument::fromJson(read(path)).object();
            mutateSettings(before, [&](auto& f) { for (const auto& key : added) f.remove(key); });
            write(path, bytesOf(before));
            const auto loaded = store.load(url, catalog);
            check(loaded.state && loaded.version == 2 && loaded.preserved.isEmpty(), "a record without the Pre-Dev rows");
            for (const auto& key : added) {
                const auto* field = spk::desktop::find_setting(key.toStdString());
                check(field && loaded.state->settings.get(field->key) == field->absent,
                      "a missing Pre-Dev row did not take what the record was made with");
            }
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["white_balance"] = "candlelight"; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["white_balance_temperature"] = 1900.0; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["scene_latitude_norm"] = "luma"; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["scene_latitude_highlight_pull_back"] = 8.5; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["contrast_mask_scale"] = 0.25; }); });
            corrupt([](auto& d) { mutateSettings(d, [](auto& f) { f["contrast_mask_scheme"] = "guided"; }); });
            write(path, validBytes);
            check(store.load(url, catalog).state == std::optional(state), "restored record after the Pre-Dev rows");
        }
        {
            // A newer build's fields are reported, ignored and kept by the
            // next save, at each level such a build may extend.
            auto newer = validJson;
            newer["futureField"] = QJsonObject{{"kept", true}};
            mutateObject(newer, "state", [](auto& s) {
                s["mask"] = QJsonArray{1, 2, 3};
                mutateObject(s, "settings", [](auto& f) { f["future_strength"] = 0.7; });
                mutateObject(s, "geometry", [](auto& g) { g["perspective"] = QJsonObject{{"x", 0.1}}; });
            });
            write(path, bytesOf(newer));
            const auto loaded = store.load(url, catalog);
            auto preserved = loaded.preserved;
            preserved.sort();
            check(loaded.state == std::optional(state) && !loaded.blocked && loaded.version == 2 &&
                  preserved == QStringList{"document.futureField", "state.geometry.perspective", "state.mask",
                                           "state.settings.future_strength"},
                  "newer version 2 fields were refused or not reported");
            auto edited = state;
            edited.settings.grain_amount = 0.75;
            edited.geometry.quarterTurns = 2;
            store.save(url, edited);
            const auto saved = QJsonDocument::fromJson(read(path)).object();
            const auto savedState = saved.value("state").toObject();
            check(saved.value("futureField") == newer.value("futureField") &&
                  savedState.value("mask") == QJsonArray{1, 2, 3} &&
                  savedState.value("settings").toObject().value("future_strength").toDouble() == 0.7 &&
                  savedState.value("geometry").toObject().value("perspective") == QJsonObject{{"x", 0.1}},
                  "save dropped a newer build's fields");
            check(savedState.value("settings").toObject().value("grain_amount").toDouble() == 0.75 &&
                  savedState.value("geometry").toObject().value("quarterTurns").toInt() == 2,
                  "save did not replace the fields it knows");
            check(store.load(url, catalog).state == std::optional(edited), "extended record did not reload");
            write(path, validBytes);
            check(store.load(url, catalog).state == std::optional(state), "restored record did not reload");
        }

        auto noStocks = catalog;
        noStocks.films.clear();
        const auto unavailable = store.load(url, noStocks);
        check(!unavailable.state && unavailable.blocked && !unavailable.warning.isEmpty(),
              "unavailable catalog stock silently fell back to defaults");
        rejects([&] { store.save(url, state); }, "blocked catalog load could still overwrite its history");
        check(read(path) == validBytes, "catalog validation modified saved data");
        for (const QByteArray& bytes : {QByteArray("{\"version\":1,"), QByteArray(65537, ' ')}) {
            write(path, bytes);
            const auto bad = store.load(url, catalog);
            check(!bad.state && bad.blocked && !bad.warning.isEmpty(), "bad JSON or oversize document loaded");
            rejects([&] { store.save(url, state); }, "save overwrote truncated or oversize history");
            check(read(path) == bytes, "failed save modified unreadable history");
        }
        write(path, validBytes);
        check(store.load(url, catalog).state == std::optional(state), "reopen did not clear a resolved load warning");

        auto invalidState = [&](const std::function<void(editing::State&)>& change) {
            auto candidate = state;
            change(candidate);
            rejects([&] { store.save(url, candidate); }, "invalid in-memory state was saved");
            check(read(path) == validBytes, "invalid state modified valid history");
        };
        invalidState([](auto& s) { s.settings.grain_amount = std::numeric_limits<double>::quiet_NaN(); });
        invalidState([](auto& s) { s.settings.glare_amount = std::numeric_limits<double>::infinity(); });
        invalidState([](auto& s) { s.settings.film_format_mm = 3.99; });
        invalidState([](auto& s) { s.settings.print_exposure = 0.049; });
        invalidState([](auto& s) { s.settings.halation_amount = 4.01; });
        invalidState([](auto& s) { s.settings.m_filter_shift = 1.01; });
        invalidState([](auto& s) { s.settings.film_stock = "syntactically_valid_but_missing"; });
        invalidState([](auto& s) { s.settings.set("filter_shift_scale", 0.5); });
        invalidState([](auto& s) { s.settings.set("auto_exposure_method", std::string("spot")); });
        invalidState([](auto& s) { s.mode = static_cast<spk::desktop::DecodeMode>(17); });
        invalidState([](auto& s) { s.geometry.quarterTurns = 4; });
        invalidState([](auto& s) { s.geometry.crop = QRectF(-0.1, 0, 1, 1); });
        invalidState([](auto& s) { s.geometry.straightenDegrees = std::numeric_limits<double>::quiet_NaN(); });

        QLockFile lock(path + ".lock");
        check(lock.tryLock(0), "test could not acquire store lock");
        rejects([&] { store.save(url, state); }, "concurrent writer bypassed store lock");
        check(read(path) == validBytes, "locked save changed history");
        lock.unlock();

        // Same name, size and timestamp, but changed sampled bytes: the hash
        // prevents an unrelated replacement from inheriting these edits.
        QByteArray replaced = input;
        replaced[replaced.size() - 9] = char(replaced[replaced.size() - 9] ^ 63);
        write(source, replaced);
        QFile sourceHandle(source);
        check(sourceHandle.open(QIODevice::ReadWrite), "cannot open owned source timestamp");
        check(sourceHandle.setFileTime(originalTime, QFileDevice::FileModificationTime),
              "cannot restore owned source timestamp");
        sourceHandle.close();
        const auto stale = store.load(url, catalog);
        check(!stale.state && stale.blocked && stale.warning.contains("changed"),
              "changed sampled source content was not detected");
        rejects([&] { store.save(url, state); }, "save overwrote edits after the source changed");
        check(read(path) == validBytes, "stale source check discarded old edits");

        const auto another = QDir(sources).filePath("separate.ARW");
        write(another, QByteArray("independent source"));
        const auto otherUrl = QUrl::fromLocalFile(another);
        check(store.filePath(otherUrl) != path && !store.load(otherUrl, catalog).state,
              "separate source inherited another photograph's settings");
        store.save(otherUrl, editing::State{});
        check(store.load(otherUrl, catalog).state == std::optional(editing::State{}),
              "default state failed to roundtrip independently");
        const auto firstSaveSource = QDir(sources).filePath("changed-before-first-save.ARW");
        write(firstSaveSource, "first source contents");
        const auto firstSaveUrl = QUrl::fromLocalFile(firstSaveSource);
        check(!store.load(firstSaveUrl, catalog).state,
              "new source unexpectedly had edit history");
        write(firstSaveSource, "replacement contents");
        rejects([&] { store.save(firstSaveUrl, state); },
                "first save adopted a replaced source file");
        check(!QFileInfo::exists(store.filePath(firstSaveUrl)),
              "first-save source conflict created an edit record");
        const auto contested = QDir(sources).filePath("two-first-writers.ARW");
        write(contested, "contested source");
        const auto contestedUrl = QUrl::fromLocalFile(contested);
        editing::Store firstWriter(root), secondWriter(root);
        check(!firstWriter.load(contestedUrl, catalog).state && !secondWriter.load(contestedUrl, catalog).state,
              "contested source had prior state");
        firstWriter.save(contestedUrl, state);
        const auto firstBytes = read(firstWriter.filePath(contestedUrl));
        rejects([&] { secondWriter.save(contestedUrl, editing::State{}); },
                "second first-save writer replaced new history from another instance");
        check(read(firstWriter.filePath(contestedUrl)) == firstBytes,
              "competing first save modified the winner's edits");
        const auto blockedRoot = temporary.filePath("store-is-a-file");
        write(blockedRoot, "keep");
        rejects([&] { editing::Store(blockedRoot).save(otherUrl, state); },
                "save succeeded with a regular file as root");
        check(read(blockedRoot) == "keep", "failed directory creation changed its obstacle");
        rejects([&] { editing::Store(sources).save(otherUrl, state); },
                "store wrote edits beside the source image");
        check(QDir(root).entryList({"*.lock", "*.tmp"}, QDir::Files).isEmpty(),
              "store left lock or temporary files behind");

        std::printf("Edit store: %d checks passed; explicit temporary files only.\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "Edit store FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
