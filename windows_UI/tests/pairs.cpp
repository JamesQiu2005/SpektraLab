// spk_qt_pairs_test -- the half-frame pair's model without an engine, a GPU or
// a RAW (src/HalfFramePair.*): the pair's own record in the edit store's
// directory and its round trip, a newer build's fields kept, a newer version
// refused; where each edit of the rails lands -- the picked frame's camera and
// its own print, + Film moving the film around it, the film moving the frames
// that print for themselves (Session.setEnlarger / setHoleExposure,
// Session.swift:4380-4394, :5025-5065); what the engine is handed; and the
// undo states a pair edit makes. The argument is a scratch directory inside
// the build tree; it is emptied first.
#include "EditStore.hpp"
#include "HalfFramePair.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <cmath>
#include <cstdio>

using namespace spk::desktop;
namespace {
int failures = 0, checks = 0;
void check(bool ok, const char* what) {
    ++checks;
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++failures;
}
double num(const RenderSettings& s, const char* key) { return std::get<double>(s.get(key)); }
bool near(double a, double b, double tol = 1e-9) { return std::abs(a - b) <= tol; }
QJsonObject readJson(const QString& path) {
    QFile f(path);
    f.open(QIODevice::ReadOnly);
    return QJsonDocument::fromJson(f.readAll()).object();
}
void writeJson(const QString& path, const QJsonObject& o) {
    QFile f(path);
    f.open(QIODevice::WriteOnly | QIODevice::Truncate);
    f.write(QJsonDocument(o).toJson());
}
}  // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    if (argc < 2) return 2;
    const QString root = QDir(QString::fromLocal8Bit(argv[1])).absolutePath();
    QDir(root).removeRecursively();
    QDir().mkpath(root);
    const QString edits = root + "/edits", folder = root + "/roll";
    QDir().mkpath(folder);
    const QString a = folder + "/A.NEF", b = folder + "/B.ARW";
    for (const auto& p : {a, b}) { QFile f(p); f.open(QIODevice::WriteOnly); f.write("raw"); }

    // --- a new pair --------------------------------------------------------------
    RenderSettings ownA, ownB;
    ownA.set("white_balance", std::string("custom"));
    ownA.set("white_balance_temperature", 4300.0);
    ownA.set("auto_exposure_method", std::string("protect_highlights"));
    ownA.set("scene_latitude_active", true);
    ownB.set("white_balance", std::string("daylight"));
    ownB.set("white_balance_temperature", 5500.0);
    output::Geometry cropB;
    cropB.crop = QRectF(0.1, 0.1, 0.5, 0.6);
    cropB.quarterTurns = 1;
    pairs::Pair pair;
    pair.folder = folder;
    pair.holes[0] = pairs::holeFor(a, &ownA, {});
    pair.holes[1] = pairs::holeFor(b, &ownB, cropB);
    check(std::get<std::string>(pair.holes[0]->frame.get("white_balance")) == "custom" &&
              num(pair.holes[0]->frame, "white_balance_temperature") == 4300 &&
              std::get<std::string>(pair.holes[0]->frame.get("auto_exposure_method")) == "protect_highlights",
          "a frame in a hole keeps its own white balance and metering intent (Session.hole(for:))");
    check(!std::get<bool>(pair.holes[0]->frame.get("scene_latitude_active")) &&
              std::get<bool>(pair.holes[0]->frame.get("auto_exposure")) &&
              num(pair.holes[0]->frame, "exposure_compensation_ev") == 0,
          "its Scene Placement starts clear, its meter on with no exposure of its own");
    check(pair.holes[1]->geometry == cropB, "its own crop and turn come with it");

    // --- the record: round trip, unknown fields, newer versions ---------------
    const QString path = pairs::newPairPath(edits, folder);
    check(pairs::title(path) == "Half-Frame Pair 1" && path.endsWith(".spkpair") && path.startsWith(pairs::storeDirectory(edits)),
          "a new pair's record is \"Half-Frame Pair 1\" in <edits>/Pairs");
    editing::State state;
    state.settings.film_stock = "kodak_gold_200";
    state.settings.set("overscan_active", true);
    state.settings.set("overscan_format", std::string("135_half"));
    state.mode = DecodeMode::headroom;
    pair.holes[1]->placement = {2.0, 0.25, -0.5, 1};
    pair.holes[1]->printScope = pairs::Scope::frame;
    RenderSettings print;
    print.set("y_filter_shift", 0.3);
    print.print_exposure = 0.5;
    pair.holes[0]->print = print;
    pair.holes[0]->postDev = QJsonObject{{"exposure", 0.4}};
    pair.spacingMM = 1.5;
    pair.turned = true;
    pairs::save(path, pair, state);
    check(QFile::exists(path), "the pair's record is written");
    check(!QFile::exists(a + ".json") && QDir(folder).entryList(QDir::Files).size() == 2,
          "nothing is written beside the photographs");
    editing::State loadedState;
    const auto loaded = pairs::load(path, nullptr, loadedState);
    check(loaded.pair && *loaded.pair == pair && loaded.warning.isEmpty(), "the record round-trips the piece and both frames");
    check(loadedState.settings == state.settings && loadedState.mode == DecodeMode::headroom && loadedState.pair == pair,
          "and the pair's own settings, as a photograph's edit");
    check(pairs::pairsIn(edits, folder) == QStringList{path} && pairs::pairsIn(edits, root).isEmpty(),
          "the store lists a folder's pairs only");
    check(pairs::newPairPath(edits, folder) != path && pairs::title(pairs::newPairPath(edits, folder)) == "Half-Frame Pair 2",
          "the next pair takes the next number");
    {
        auto doc = readJson(path);
        doc.insert("future", 7);
        auto p = doc.value("pair").toObject();
        auto holes = p.value("holes").toArray();
        auto h = holes[0].toObject();
        h.insert("future", "kept");
        holes[0] = h;
        p.insert("holes", holes);
        doc.insert("pair", p);
        writeJson(path, doc);
        editing::State s2;
        const auto again = pairs::load(path, nullptr, s2);
        check(again.pair && again.preserved.contains("future") && again.preserved.contains("pair.holes[0].future"),
              "a newer build's fields are reported");
        pairs::Pair moved = *again.pair;
        moved.spacingMM = 0.8;
        pairs::save(path, moved, s2);
        const auto after = readJson(path);
        check(after.value("future").toInt() == 7 && after.value("pair").toObject().value("spacingMM").toDouble() == 0.8,
              "and kept by the next save, which writes its own");
        auto newer = after;
        newer.insert("version", 2);
        writeJson(path, newer);
        editing::State s3;
        const auto refused = pairs::load(path, nullptr, s3);
        check(!refused.pair && !refused.warning.isEmpty(), "a newer version is refused");
        bool threw = false;
        try { pairs::save(path, moved, s2); } catch (const std::exception&) { threw = true; }
        check(threw && readJson(path).value("version").toInt() == 2, "and preserved, never overwritten");
        writeJson(path, after);
    }

    // --- the rails: where an edit lands ------------------------------------------
    pairs::Pair p;
    p.folder = folder;
    p.holes[0] = pairs::holeFor(a, &ownA, {});
    p.holes[1] = pairs::holeFor(b, &ownB, {});
    RenderSettings film;
    film.set("y_filter_shift", 0.1);
    using pairs::Layer;
    {
        // The picked frame's camera.
        auto f = film; auto q = p;
        auto shown = pairs::shown(f, q, Layer::second, 0);
        check(num(shown, "white_balance_temperature") == 5500 && std::get<std::string>(shown.get("white_balance")) == "daylight",
              "with the second frame picked the rails show its white balance");
        shown.set("exposure_compensation_ev", 1.5);
        shown.set("white_balance_temperature", 6100.0);
        shown.set("white_balance", std::string("custom"));
        pairs::takeEdit(shown, f, q, Layer::second, 0);
        check(num(q.holes[1]->frame, "exposure_compensation_ev") == 1.5 && num(q.holes[1]->frame, "white_balance_temperature") == 6100 &&
                  num(q.holes[0]->frame, "exposure_compensation_ev") == 0 && num(q.holes[0]->frame, "white_balance_temperature") == 4300,
              "its exposure and white balance are its own: the other frame is untouched");
        check(f == film, "and the film is untouched");
        check(num(pairs::shown(f, q, Layer::film, 1), "exposure_compensation_ev") == 1.5,
              "with the film picked the camera rows are the frame picked last's");
    }
    {
        // The picked frame's print, + Film (the default): both frames get a
        // print of their own first, the film moves by the same amount.
        auto f = film; auto q = p;
        auto shown = pairs::shown(f, q, Layer::first, 0);
        shown.set("y_filter_shift", 0.4);
        pairs::takeEdit(shown, f, q, Layer::first, 0);
        check(q.holes[0]->print && near(num(*q.holes[0]->print, "y_filter_shift"), 0.4), "the Enlarger moves the picked frame's print");
        check(q.holes[1]->print && near(num(*q.holes[1]->print, "y_filter_shift"), 0.1), "the other frame keeps the film's print");
        check(near(num(f, "y_filter_shift"), 0.4), "+ Film: the film around it moves by the same amount");
        // Frame only.
        q.holes[0]->printScope = pairs::Scope::frame;
        shown = pairs::shown(f, q, Layer::first, 0);
        shown.set("y_filter_shift", 0.6);
        pairs::takeEdit(shown, f, q, Layer::first, 0);
        check(near(num(*q.holes[0]->print, "y_filter_shift"), 0.6) && near(num(f, "y_filter_shift"), 0.4),
              "Frame: the film stays");
        // The film picked: frames printing for themselves move with it.
        shown = pairs::shown(f, q, Layer::film, 0);
        check(near(num(shown, "y_filter_shift"), 0.4), "with the film picked the Enlarger shows the film's print");
        shown.set("y_filter_shift", 0.5);
        shown.print_exposure = 0.5;
        pairs::takeEdit(shown, f, q, Layer::film, 0);
        check(near(num(f, "y_filter_shift"), 0.5) && near(num(*q.holes[0]->print, "y_filter_shift"), 0.7) &&
                  near(num(*q.holes[1]->print, "y_filter_shift"), 0.2),
              "the film's print moves the frames' own by the same amount");
        check(near(q.holes[0]->print->print_exposure, 0.5) && near(q.holes[1]->print->print_exposure, 0.5),
              "the brightness by the same stops");
        // The rails round-trip the brightness through stops: no edit.
        auto again = q; auto filmAgain = f;
        auto rounded = pairs::shown(filmAgain, again, Layer::first, 0);
        rounded.print_exposure = std::exp2(-(-std::log2(rounded.print_exposure)));
        pairs::takeEdit(rounded, filmAgain, again, Layer::first, 0);
        check(again == q && filmAgain == f, "a value read back through the controls is no edit");
    }
    {
        // Exposure on + Film: the film's print brightness follows by the same stops.
        auto f = film; auto q = p;
        q.holes[0]->exposureScope = pairs::Scope::film;
        auto shown = pairs::shown(f, q, Layer::first, 0);
        shown.set("exposure_compensation_ev", 1.0);
        pairs::takeEdit(shown, f, q, Layer::first, 0);
        check(near(f.print_exposure, 0.5) && q.holes[1]->print && near(q.holes[1]->print->print_exposure, 1.0),
              "exposure on + Film moves the film's print a stop; the other frame keeps its print");
        // Any other row is the film's.
        shown = pairs::shown(f, q, Layer::second, 0);
        shown.grain_amount = 1.7;
        pairs::takeEdit(shown, f, q, Layer::second, 0);
        check(near(f.grain_amount, 1.7), "a row no frame keeps (grain) is the film's");
    }

    // --- what the engine is handed ----------------------------------------------
    {
        auto f = film; auto q = p;
        q.holes[0]->frame.set("scene_latitude_active", true);
        q.holes[0]->frame.set("scene_latitude_highlight_room", 1.25);
        q.holes[1]->frame.set("scene_latitude_active", true);
        q.holes[1]->frame.set("scene_latitude_shadow_room", 0.75);
        q.holes[1]->frame.set("exposure_compensation_ev", -0.5);
        q.holes[1]->frame.set("auto_exposure", false);
        f.set("auto_exposure", true);
        f.film_exposure_ev = 2;
        q.spacingMM = 1.5;
        const auto s = pairs::engineSettings(f, q);
        check(!std::get<bool>(s.get("auto_exposure")) && s.film_exposure_ev == 0, "the piece is developed with the meter off");
        check(near(s.film_format_mm, 37.5), "film_format_mm is the piece's long edge (18 + 1.5 + 18 mm)");
        check(std::get<bool>(s.get("scene_latitude_active")) && num(s, "scene_latitude_highlight_room") == 1.25,
              "the first frame's Scene Placement is the engine's first curve");
        const auto in = pairs::engineInput(f, q);
        check(in.holes[0] && in.holes[1] && in.holes[1]->exposure_ev == -0.5 && !in.holes[1]->meter && in.holes[0]->meter &&
                  in.holes[0]->meter_method == "protect_highlights",
              "each hole's exposure and meter are its frame's");
        check(std::get<std::string>(in.holes[0]->decode.get("white_balance")) == "custom" &&
                  std::get<double>(in.holes[0]->decode.get("white_balance_temperature")) == 4300,
              "each hole decodes with its frame's white balance");
        check(in.latitude_b.active && in.latitude_b.shadow_room == 0.75, "the second frame's curve rides as the second one");
        check(!in.holes[0]->print && !in.holes[1]->print, "a frame printing as the film adds no layer");
        auto layered = q;
        layered.holes[1]->print = RenderSettings();
        for (const auto& key : pairs::printKeys()) layered.holes[1]->print->set(key, f.get(key));
        check(!pairs::engineInput(f, layered).holes[1]->print, "nor does a print of its own that equals the film's");
        layered.holes[1]->print->set("m_filter_shift", -0.2);
        const auto withPrint = pairs::engineInput(f, layered);
        check(withPrint.holes[1]->print && num(*withPrint.holes[1]->print, "m_filter_shift") == -0.2 &&
                  !std::get<bool>(withPrint.holes[1]->print->get("auto_exposure")),
              "a print of its own is the piece's settings with its enlarger");
        check(same_piece(in, withPrint) && !(in == withPrint), "and is the same piece, printed again");
        f.set("overscan_active", true);
        check(near(pairs::engineSettings(f, q).film_format_mm, 37) && pairs::engineInput(f, q).spacing_mm == 1.0,
              "on a strip the camera's 1 mm advance, whatever the user's gap");
    }

    // --- undo states --------------------------------------------------------------
    {
        editing::State before{film, DecodeMode::compatible16, {}, std::nullopt, p};
        auto q = p;
        q.holes[1]->placement.scale = 1.5;
        editing::State after{film, DecodeMode::compatible16, {}, std::nullopt, q};
        check(!(before == after), "a placement is an undo step of its own");
        q = p;
        std::swap(q.holes[0], q.holes[1]);
        check(!(before == editing::State{film, DecodeMode::compatible16, {}, std::nullopt, q}), "so is swapping the frames");
        check(before == editing::State{film, DecodeMode::compatible16, {}, std::nullopt, p}, "the same piece is the same state");
    }

    std::printf("%s: %d of %d checks failed\n", failures ? "FAILED" : "OK", failures, checks);
    return failures ? 1 : 0;
}
