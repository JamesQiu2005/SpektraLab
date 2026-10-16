#include "HalfFramePair.hpp"
#include "EditStore.hpp"
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <type_traits>
#include <variant>

namespace spk::desktop::pairs {
namespace {
constexpr int currentVersion = 1;
constexpr qint64 maximumDocumentBytes = 128 * 1024;
const QString formatName = QStringLiteral("SpektraLab.Windows.HalfFramePair");

[[noreturn]] void fail(const QString& message) { throw std::runtime_error(message.toUtf8().toStdString()); }
void require(bool value, const QString& message) { if (!value) fail(message); }

// The Scene Placement rows a frame keeps (the curve the Fit solved and the
// two sliders it was solved from); the norm, the roll-off and the lift bound
// are the engine's shared ones (API-SPEC "Scene Placement per frame").
constexpr const char* latitudeKeys[] = {"scene_latitude_active", "scene_latitude_highlight_knee",
                                        "scene_latitude_highlight_room", "scene_latitude_shadow_knee",
                                        "scene_latitude_shadow_room", "scene_latitude_highlight_pull_back",
                                        "scene_latitude_shadow_pull_back", "scene_latitude_needs_fit"};

bool same(const SettingValue& a, const SettingValue& b) {
    if (a.index() != b.index()) return false;
    if (const auto* x = std::get_if<double>(&a)) {
        const double y = std::get<double>(b);
        // The brightness round-trips through stops in the controls.
        return std::abs(*x - y) <= 1e-9 * std::max({1.0, std::abs(*x), std::abs(y)});
    }
    return a == b;
}
double number(const RenderSettings& s, std::string_view key) { return std::get<double>(s.get(key)); }

// `value` moved as `from` moved to `to`: by the same stops for the
// brightness (print_exposure is 2^-stops), by the same amount otherwise, in
// the control's range (Session.clamped(_:_:), :4937-4943).
SettingValue moved(const std::string& key, const SettingValue& value, const SettingValue& from, const SettingValue& to) {
    const double v = std::get<double>(value), a = std::get<double>(from), b = std::get<double>(to);
    if (key == "print_exposure") {
        const double out = a > 0 ? v * b / a : v;
        return std::clamp(out, std::exp2(-3.0), std::exp2(3.0));
    }
    const auto* field = find_setting(key);
    return std::clamp(v + (b - a), field->low, field->high);
}
// Both frames get a print of their own -- the film's -- before one of them is
// changed, so the other does not ride along with the film (:5051-5053).
void givePrints(const RenderSettings& film, Pair& pair) {
    for (auto& hole : pair.holes) {
        if (!hole || hole->print) continue;
        RenderSettings print;
        for (const auto& key : printKeys()) print.set(key, film.get(key));
        hole->print = print;
    }
}

QJsonValue jsonValue(const SettingValue& value) {
    return std::visit([](const auto& v) -> QJsonValue {
        if constexpr (std::is_same_v<std::decay_t<decltype(v)>, std::string>) return QString::fromStdString(v);
        else return QJsonValue(v);
    }, value);
}
QJsonObject rowsJson(const RenderSettings& s, const std::vector<std::string>& keys) {
    QJsonObject out;
    for (const auto& key : keys) out.insert(QString::fromStdString(key), jsonValue(s.get(key)));
    return out;
}
// The rows `keys` from `object` onto `out`, each checked as the edit store
// checks a row; a missing row keeps `out`'s value, an unknown one is recorded.
void parseRows(const QJsonObject& object, const std::vector<std::string>& keys, RenderSettings& out,
               const QString& label, QStringList& preserved) {
    for (auto it = object.begin(); it != object.end(); ++it) {
        const auto key = it.key().toStdString();
        if (std::find(keys.begin(), keys.end(), key) == keys.end()) { preserved.append(label + "." + it.key()); continue; }
        const auto* field = find_setting(key);
        SettingValue value;
        switch (field->type) {
        case SettingType::boolean:
            require(it.value().isBool(), QStringLiteral("Pair field must be true or false: ") + it.key());
            value = it.value().toBool();
            break;
        case SettingType::number:
            require(it.value().isDouble(), QStringLiteral("Pair field must be numeric: ") + it.key());
            value = it.value().toDouble();
            break;
        case SettingType::text:
            require(it.value().isString(), QStringLiteral("Pair field must be text: ") + it.key());
            value = it.value().toString().toStdString();
            break;
        }
        require(check_setting(*field, value).empty(), QStringLiteral("Pair field is outside its valid range: ") + it.key());
        out.set(key, value);
    }
}
QString scopeName(Scope s) { return s == Scope::film ? QStringLiteral("film") : QStringLiteral("frame"); }
Scope parseScope(const QJsonValue& v, Scope fallback) {
    if (v.toString() == QLatin1String("film")) return Scope::film;
    if (v.toString() == QLatin1String("frame")) return Scope::frame;
    return fallback;
}

QJsonObject holeJson(const Hole& h) {
    QJsonObject o{{"path", QDir::toNativeSeparators(h.path)},
        {"placement", QJsonObject{{"scale", h.placement.scale}, {"x", h.placement.x}, {"y", h.placement.y},
                                  {"quarterTurns", h.placement.quarter_turns}}},
        {"geometry", editing::geometryToJson(h.geometry)},
        {"frame", rowsJson(h.frame, cameraKeys())},
        {"print", h.print ? QJsonValue(rowsJson(*h.print, printKeys())) : QJsonValue()},
        {"printScope", scopeName(h.printScope)}, {"exposureScope", scopeName(h.exposureScope)}};
    if (!h.postDev.isEmpty()) o.insert("postDev", h.postDev);
    return o;
}
Hole parseHole(const QJsonObject& o, const QString& label, QStringList& preserved) {
    Hole h;
    require(o.value("path").isString() && QDir::isAbsolutePath(o.value("path").toString()),
            QStringLiteral("Pair hole has no absolute path"));
    h.path = QDir::cleanPath(QDir::fromNativeSeparators(o.value("path").toString()));
    const auto p = o.value("placement").toObject();
    h.placement = clamped({p.value("scale").toDouble(1.0), p.value("x").toDouble(0.0), p.value("y").toDouble(0.0),
                           p.value("quarterTurns").toInt(0)});
    if (o.value("geometry").isObject())
        h.geometry = editing::geometryFromJson(o.value("geometry").toObject(), label + ".geometry", &preserved);
    h.frame = RenderSettings();
    parseRows(o.value("frame").toObject(), cameraKeys(), h.frame, label + ".frame", preserved);
    if (o.value("print").isObject()) {
        RenderSettings print;
        parseRows(o.value("print").toObject(), printKeys(), print, label + ".print", preserved);
        h.print = print;
    }
    h.printScope = parseScope(o.value("printScope"), Scope::film);
    h.exposureScope = parseScope(o.value("exposureScope"), Scope::frame);
    h.postDev = o.value("postDev").toObject();
    static const QStringList known{"path", "placement", "geometry", "frame", "print", "printScope", "exposureScope", "postDev"};
    for (auto it = o.begin(); it != o.end(); ++it)
        if (!known.contains(it.key())) preserved.append(label + "." + it.key());
    return h;
}
QJsonObject pairJson(const Pair& pair) {
    QJsonArray holes;
    for (const auto& hole : pair.holes) holes.append(hole ? QJsonValue(holeJson(*hole)) : QJsonValue());
    return {{"folder", QDir::toNativeSeparators(pair.folder)}, {"turned", pair.turned},
            {"spacingMM", pair.spacingMM}, {"holes", holes}};
}
// Replaces what this build writes and keeps every other field (EditStore's
// overlay): a hole's rows and the crop are replaced whole.
QJsonObject overlay(QJsonObject base, const QJsonObject& known) {
    for (auto it = known.begin(); it != known.end(); ++it) {
        const auto previous = base.value(it.key());
        const bool whole = it.key() == QLatin1String("crop") || it.key() == QLatin1String("frame") ||
                           it.key() == QLatin1String("print") || it.key() == QLatin1String("holes");
        if (it.value().isObject() && previous.isObject() && !whole)
            base.insert(it.key(), overlay(previous.toObject(), it.value().toObject()));
        else
            base.insert(it.key(), it.value());
    }
    return base;
}
QJsonObject readDocument(const QString& path) {
    QFile file(path);
    require(file.open(QIODevice::ReadOnly), QStringLiteral("Cannot read the pair: ") + file.errorString());
    require(file.size() <= maximumDocumentBytes, QStringLiteral("The pair's record exceeds 128 KiB"));
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(file.readAll(), &error);
    require(error.error == QJsonParseError::NoError && document.isObject(),
            QStringLiteral("The pair's record is not valid JSON: ") + error.errorString());
    const auto o = document.object();
    require(o.value("format").toString() == formatName, QStringLiteral("The pair's record has another format"));
    require(o.value("version").toDouble() == currentVersion,
            QStringLiteral("The pair's record is from a newer version; it was preserved"));
    return o;
}
QString identity(const QString& path) {
#ifdef _WIN32
    return QDir::fromNativeSeparators(QDir::cleanPath(path)).toCaseFolded();
#else
    return QDir::cleanPath(path);
#endif
}
}  // namespace

const std::vector<std::string>& cameraKeys() {
    static const std::vector<std::string> keys = [] {
        std::vector<std::string> k{"white_balance", "white_balance_temperature", "white_balance_tint",
                                   "auto_exposure", "auto_exposure_method", "exposure_compensation_ev"};
        for (const char* key : latitudeKeys) k.emplace_back(key);
        return k;
    }();
    return keys;
}
const std::vector<std::string>& printKeys() {
    static const std::vector<std::string> keys{"print_exposure", "y_filter_shift", "m_filter_shift", "preflash_exposure"};
    return keys;
}
bool cameraKey(std::string_view key) {
    const auto& k = cameraKeys();
    return std::find(k.begin(), k.end(), key) != k.end();
}
bool printKey(std::string_view key) {
    const auto& k = printKeys();
    return std::find(k.begin(), k.end(), key) != k.end();
}

double Pair::effectiveSpacing(bool onStrip) const {
    return onStrip ? kPairStripSpacing : std::clamp(std::isfinite(spacingMM) ? spacingMM : 1.0, kPairSpacingMin, kPairSpacingMax);
}
int Pair::filled() const { return int(bool(holes[0])) + int(bool(holes[1])); }
bool Pair::complete() const {
    return std::all_of(holes.begin(), holes.end(), [](const auto& h) { return h && QFileInfo(h->path).isFile(); });
}

bool isPairFile(const QString& path) { return QFileInfo(path).suffix().compare(QLatin1String(kExtension), Qt::CaseInsensitive) == 0; }
QString storeDirectory(const QString& editDirectory) { return QDir(editDirectory).filePath(QStringLiteral("Pairs")); }

QString newPairPath(const QString& editDirectory, const QString& folder) {
    // A short tag of the folder keeps two folders' "Pair 1" apart (newURL).
    const auto tag = QString::fromLatin1(QCryptographicHash::hash(identity(folder).toUtf8(), QCryptographicHash::Sha256).toHex().left(6));
    const QDir dir(storeDirectory(editDirectory));
    for (int n = 1;; ++n) {
        const auto path = dir.filePath(QStringLiteral("Half-Frame Pair %1 %2.%3").arg(n).arg(tag, QLatin1String(kExtension)));
        if (!QFileInfo::exists(path)) return path;
    }
}
QString title(const QString& path) {
    auto name = QFileInfo(path).completeBaseName();
    // The folder's tag is for the store, not for the strip.
    const auto space = name.lastIndexOf(u' ');
    if (space > 0 && name.size() - space - 1 == 6) name.truncate(space);
    return name;
}
QStringList pairsIn(const QString& editDirectory, const QString& folder) {
    QStringList out;
    QDir dir(storeDirectory(editDirectory));
    auto names = dir.entryList({QStringLiteral("*.") + QLatin1String(kExtension)}, QDir::Files, QDir::Name);
    std::sort(names.begin(), names.end(), [](const QString& a, const QString& b) {
        // Name order with numbers as numbers: "Pair 2" before "Pair 10".
        static const auto key = [](const QString& s) {
            const auto parts = s.split(u' ');
            return parts.size() > 3 ? parts[3].toInt() : 0;
        };
        return key(a) != key(b) ? key(a) < key(b) : a < b;
    });
    for (const auto& name : names) {
        const auto path = dir.filePath(name);
        try {
            const auto o = readDocument(path);
            const auto f = o.value("pair").toObject().value("folder").toString();
            if (identity(QDir::fromNativeSeparators(f)) == identity(folder)) out.append(path);
        } catch (const std::exception&) {}
    }
    return out;
}

Loaded load(const QString& path, const Catalog* catalog, editing::State& state) {
    Loaded result;
    try {
        const auto o = readDocument(path);
        for (auto it = o.begin(); it != o.end(); ++it)
            if (!QStringList{"format", "version", "pair", "state"}.contains(it.key())) result.preserved.append(it.key());
        const auto p = o.value("pair").toObject();
        Pair pair;
        require(p.value("folder").isString(), QStringLiteral("The pair names no folder"));
        pair.folder = QDir::cleanPath(QDir::fromNativeSeparators(p.value("folder").toString()));
        pair.turned = p.value("turned").toBool(false);
        pair.spacingMM = std::clamp(p.value("spacingMM").toDouble(1.0), kPairSpacingMin, kPairSpacingMax);
        const auto holes = p.value("holes").toArray();
        for (int side = 0; side < 2 && side < holes.size(); ++side)
            if (holes[side].isObject())
                pair.holes[side] = parseHole(holes[side].toObject(), QStringLiteral("pair.holes[%1]").arg(side), result.preserved);
        state = editing::stateFromJson(o.value("state").toObject(), catalog, &result.preserved);
        state.geometry = {};
        state.heldGeometry.reset();
        state.pair = pair;
        result.pair = std::move(pair);
    } catch (const std::exception& e) {
        result.warning = QString::fromUtf8(e.what());
    }
    return result;
}

void save(const QString& path, const Pair& pair, const editing::State& state) {
    require(QDir().mkpath(QFileInfo(path).absolutePath()), QStringLiteral("Cannot create the pairs directory"));
    QJsonObject document;
    if (QFileInfo::exists(path)) {
        try { document = readDocument(path); } catch (const std::exception&) {
            fail(QStringLiteral("The pair's record cannot be read; it was preserved"));
        }
    }
    editing::State film = state;
    film.pair.reset();
    film.geometry = {};
    film.heldGeometry.reset();
    document = overlay(document, QJsonObject{{"format", formatName}, {"version", currentVersion},
                                             {"pair", pairJson(pair)}, {"state", editing::stateToJson(film)}});
    const auto bytes = QJsonDocument(document).toJson(QJsonDocument::Indented);
    require(bytes.size() <= maximumDocumentBytes, QStringLiteral("The pair's record exceeds 128 KiB"));
    QSaveFile file(path);
    file.setDirectWriteFallback(false);
    require(file.open(QIODevice::WriteOnly), QStringLiteral("Cannot write the pair: ") + file.errorString());
    require(file.write(bytes) == bytes.size(), QStringLiteral("Cannot write the pair: ") + file.errorString());
    require(file.commit(), QStringLiteral("Cannot save the pair: ") + file.errorString());
}

int cameraSide(const Pair& pair, Layer layer, int last) {
    if (layer != Layer::film && pair.holes[int(layer) - 1]) return int(layer) - 1;
    if ((last == 0 || last == 1) && pair.holes[last]) return last;
    for (int side = 0; side < 2; ++side)
        if (pair.holes[side]) return side;
    return -1;
}
namespace {
int pickedSide(const Pair& pair, Layer layer) {
    return layer != Layer::film && pair.holes[int(layer) - 1] ? int(layer) - 1 : -1;
}
}  // namespace

RenderSettings shown(const RenderSettings& film, const Pair& pair, Layer layer, int last) {
    RenderSettings s = film;
    if (const int cam = cameraSide(pair, layer, last); cam >= 0)
        for (const auto& key : cameraKeys()) s.set(key, pair.holes[cam]->frame.get(key));
    if (const int picked = pickedSide(pair, layer); picked >= 0 && pair.holes[picked]->print)
        for (const auto& key : printKeys()) s.set(key, pair.holes[picked]->print->get(key));
    return s;
}

void takeEdit(const RenderSettings& now, RenderSettings& film, Pair& pair, Layer layer, int last) {
    const RenderSettings before = shown(film, pair, layer, last);
    const int cam = cameraSide(pair, layer, last);
    const int picked = pickedSide(pair, layer);
    for (const auto& field : setting_fields()) {
        const auto& key = field.key;
        const SettingValue value = now.get(key), was = before.get(key);
        if (same(value, was)) continue;
        if (cameraKey(key)) {
            if (cam < 0) { film.set(key, value); continue; }
            Hole& hole = *pair.holes[cam];
            // + Film: the film's print brightness moves by the same stops,
            // so the rebate follows the frame (setHoleExposure, :4380-4394).
            if (key == "exposure_compensation_ev" && hole.exposureScope == Scope::film) {
                givePrints(film, pair);
                const double stops = std::get<double>(value) - std::get<double>(was);
                film.print_exposure = std::clamp(film.print_exposure * std::exp2(-stops), std::exp2(-3.0), std::exp2(3.0));
            }
            hole.frame.set(key, value);
        } else if (printKey(key)) {
            if (picked >= 0) {
                givePrints(film, pair);
                Hole& hole = *pair.holes[picked];
                const SettingValue own = hole.print->get(key);
                hole.print->set(key, value);
                if (hole.printScope == Scope::film) film.set(key, moved(key, film.get(key), own, value));
            } else {
                // The film is the whole piece: a frame with a print of its own
                // moves with it and keeps its distance (:5026-5044).
                const SettingValue filmWas = film.get(key);
                film.set(key, value);
                for (auto& hole : pair.holes)
                    if (hole && hole->print) hole->print->set(key, moved(key, hole->print->get(key), filmWas, value));
            }
        } else {
            film.set(key, value);
        }
    }
}

RenderSettings engineSettings(const RenderSettings& film, const Pair& pair) {
    RenderSettings s = film;
    const RenderSettings defaults;
    for (const char* key : latitudeKeys) s.set(key, pair.holes[0] ? pair.holes[0]->frame.get(key) : defaults.get(key));
    // One strip, one meter reading per hole (adoptPair, :4248-4250): the
    // engine's own meter would read both pictures and the gap as one scene.
    s.set("auto_exposure", false);
    s.film_exposure_ev = 0;
    for (const char* key : {"white_balance", "white_balance_temperature", "white_balance_tint"}) s.set(key, defaults.get(key));
    const auto* mm = find_setting("film_format_mm");
    s.film_format_mm = std::clamp(pair_piece_mm(pair.effectiveSpacing(std::get<bool>(film.get("overscan_active")))),
                                  mm->low, mm->high);
    return s;
}

PairInput engineInput(const RenderSettings& film, const Pair& pair) {
    PairInput in;
    const RenderSettings base = engineSettings(film, pair);
    in.spacing_mm = pair.effectiveSpacing(std::get<bool>(film.get("overscan_active")));
    in.turned = pair.turned;
    for (int side = 0; side < 2; ++side) {
        const auto& hole = pair.holes[side];
        if (!hole) continue;
        PairHole h;
        h.source = std::filesystem::path(QDir::toNativeSeparators(hole->path).toStdWString());
        for (const char* key : {"white_balance", "white_balance_temperature", "white_balance_tint"})
            h.decode.set(key, hole->frame.get(key));
        const auto& g = hole->geometry;
        h.geometry = {g.crop.x(), g.crop.y(), g.crop.width(), g.crop.height(), g.quarterTurns, g.flipHorizontal,
                      g.flipVertical, g.straightenDegrees};
        h.placement = clamped(hole->placement);
        h.exposure_ev = number(hole->frame, "exposure_compensation_ev");
        h.meter = std::get<bool>(hole->frame.get("auto_exposure"));
        h.meter_method = std::get<std::string>(hole->frame.get("auto_exposure_method"));
        if (hole->print) {
            bool differs = false;
            for (const auto& key : printKeys()) differs = differs || !same(hole->print->get(key), base.get(key));
            if (differs) {
                RenderSettings printed = base;
                for (const auto& key : printKeys()) printed.set(key, hole->print->get(key));
                h.print = printed;
            }
        }
        in.holes[side] = std::move(h);
    }
    if (const auto& b = pair.holes[1]) {
        in.latitude_b.active = std::get<bool>(b->frame.get("scene_latitude_active"));
        in.latitude_b.highlight_knee = number(b->frame, "scene_latitude_highlight_knee");
        in.latitude_b.highlight_room = number(b->frame, "scene_latitude_highlight_room");
        in.latitude_b.shadow_knee = number(b->frame, "scene_latitude_shadow_knee");
        in.latitude_b.shadow_room = number(b->frame, "scene_latitude_shadow_room");
    }
    return in;
}

Hole holeFor(const QString& path, const RenderSettings* own, const output::Geometry& geometry) {
    Hole h;
    h.path = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
    h.geometry = geometry;
    h.frame = RenderSettings();
    // The shot stays the frame's (Session.hole(for:), :4281-4287): its own
    // white balance and its crop come with it. Its meter starts on, at its own
    // intent, with no exposure of its own; its Scene Placement starts clear --
    // the curve was fitted to the frame as a whole (resetPlacement, :4843).
    if (own) {
        for (const char* key : {"white_balance", "white_balance_temperature", "white_balance_tint", "auto_exposure_method"})
            h.frame.set(key, own->get(key));
    }
    return h;
}

}  // namespace spk::desktop::pairs
