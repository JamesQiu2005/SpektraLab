// Temporary source files and an explicit store root: this test never reads or
// writes the user's real edit history and needs neither a RAW decoder nor GPU.
#include "EditStore.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
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
} // namespace

int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    try {
        QTemporaryDir temporary;
        check(temporary.isValid(), "temporary root unavailable");
        const auto sources = temporary.filePath(QString::fromUtf8("照片 文件夹"));
        check(QDir().mkpath(sources), "cannot create source folder");
        const auto source = QDir(sources).filePath(QString::fromUtf8("海边 日落.ARW"));
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
            {{"kodak_portra_endura", "Portra paper", false}, {"fuji_crystal", "Crystal", false}}};
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

        auto corrupt = [&](const std::function<void(QJsonObject&)>& change) {
            auto document = validJson;
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
        corrupt([](auto& d) { d["version"] = 2; });
        corrupt([](auto& d) { d["version"] = "1"; });
        corrupt([](auto& d) { d["format"] = "Unrelated.Application"; });
        corrupt([](auto& d) { d["futureField"] = true; });
        corrupt([](auto& d) { d.remove("source"); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["path"] = "D:/different.ARW"; }); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["size"] = 123; }); });
        corrupt([](auto& d) { mutateObject(d, "source", [](auto& s) { s["sampleSha256"] = "broken"; }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) { s["decodeMode"] = "future-decoder"; }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "settings", [](auto& f) { f.remove("film_format_mm"); }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "settings", [](auto& f) { f["grain_active"] = 1; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "settings", [](auto& f) { f["print_exposure"] = "1.0"; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "settings", [](auto& f) { f["film_exposure_ev"] = 8.01; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "settings", [](auto& f) { f["film_stock"] = "../bad"; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "geometry", [](auto& g) { g["quarterTurns"] = 0.5; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "geometry", [](auto& g) { g["straightenDegrees"] = -45.1; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "geometry", [](auto& g) { g["flipVertical"] = "false"; }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "geometry", [](auto& g) {
                mutateObject(g, "crop", [](auto& c) { c["width"] = 0; }); }); }); });
        corrupt([](auto& d) { mutateObject(d, "state", [](auto& s) {
            mutateObject(s, "geometry", [](auto& g) {
                mutateObject(g, "crop", [](auto& c) { c["width"] = 1; }); }); }); });

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
