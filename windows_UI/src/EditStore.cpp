#include "EditStore.hpp"
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QRegularExpression>
#include <QSaveFile>
#include <algorithm>
#include <cmath>
#include <iterator>
#include <stdexcept>
#include <type_traits>
#include <variant>

namespace spk::desktop::editing {
namespace {
constexpr qint64 maximumDocumentBytes = 64 * 1024;
constexpr qint64 sampleBytes = 64 * 1024;
constexpr int currentVersion = 2;
const QString formatName = QStringLiteral("SpektraLab.Windows.Editor");

// Version 1's settings, frozen: a record of that version carries exactly
// these keys, in its own spelling. Every writer since has written each of
// them, so they stay required in version 2, under the wire name -- a record
// without one is damaged, not old. Rows added later are optional.
struct Version1Key { const char* saved; const char* key; };
constexpr Version1Key version1Settings[] = {
    {"film_stock", "film_stock"}, {"print_stock", "print_stock"}, {"print_exposure", "print_exposure"},
    {"film_exposure_ev", "exposure_compensation_ev"}, {"film_format_mm", "film_format_mm"},
    {"grain_active", "grain_active"}, {"grain_amount", "grain_amount"},
    {"halation_active", "halation_active"}, {"halation_amount", "halation_amount"},
    {"glare_active", "glare_active"}, {"glare_amount", "glare_amount"},
    {"y_filter_shift", "y_filter_shift"}, {"m_filter_shift", "m_filter_shift"}};
bool requiredSetting(const std::string& key) {
    return std::any_of(std::begin(version1Settings), std::end(version1Settings),
                       [&](const Version1Key& v) { return key == v.key; });
}

[[noreturn]] void fail(const QString& message) {
    throw std::runtime_error(message.toUtf8().toStdString());
}
void require(bool value, const QString& message) { if (!value) fail(message); }

QString sourcePath(const QUrl& url) {
    require(url.isLocalFile() && !url.toLocalFile().isEmpty(),
            QStringLiteral("Saved edits require a local source file"));
    const QFileInfo info(url.toLocalFile());
    const auto canonical = info.canonicalFilePath();
    return QDir::cleanPath(canonical.isEmpty() ? info.absoluteFilePath() : canonical);
}
QString pathIdentity(const QString& path) {
#ifdef _WIN32
    return QDir::fromNativeSeparators(path).toCaseFolded();
#else
    return QDir::fromNativeSeparators(path);
#endif
}
QString observationKey(const QUrl& source) {
    require(source.isLocalFile() && !source.toLocalFile().isEmpty(),
            QStringLiteral("Saved edits require a local source file"));
    // Keep this key tied to the name the user opened. If a symlink is retargeted,
    // its canonical record path changes, but it must still fail the observation
    // check instead of looking like a never-before-opened photograph.
    return pathIdentity(QDir::cleanPath(QFileInfo(source.toLocalFile()).absoluteFilePath()));
}
// Version 1 shapes are exact (no `unknown` list). From version 2 the listed
// keys are required and any other key is a field from a newer build: it is
// reported in `unknown`, ignored here, and kept by the next save.
void keys(const QJsonObject& object, const QStringList& expected, const QString& label,
          QStringList* unknown = nullptr) {
    for (const auto& key : expected)
        require(object.contains(key), QStringLiteral("Saved edits are missing ") + label + "." + key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (expected.contains(it.key())) continue;
        require(unknown != nullptr, QStringLiteral("Saved edits contain missing or unsupported fields in ") + label);
        unknown->append(label + "." + it.key());
    }
}
QJsonObject object(const QJsonObject& parent, const char* key) {
    const auto value = parent.value(QLatin1String(key));
    require(value.isObject(), QStringLiteral("Saved edit field must be an object: ") + QLatin1String(key));
    return value.toObject();
}
QString string(const QJsonObject& parent, const char* key) {
    const auto value = parent.value(QLatin1String(key));
    require(value.isString(), QStringLiteral("Saved edit field must be text: ") + QLatin1String(key));
    return value.toString();
}
double number(const QJsonObject& parent, const char* key, double low, double high) {
    const auto value = parent.value(QLatin1String(key));
    require(value.isDouble(), QStringLiteral("Saved edit field must be numeric: ") + QLatin1String(key));
    const double result = value.toDouble();
    require(std::isfinite(result) && result >= low && result <= high,
            QStringLiteral("Saved edit field is outside its valid range: ") + QLatin1String(key));
    return result;
}
bool boolean(const QJsonObject& parent, const char* key) {
    const auto value = parent.value(QLatin1String(key));
    require(value.isBool(), QStringLiteral("Saved edit field must be true or false: ") + QLatin1String(key));
    return value.toBool();
}
const SettingField& settingRow(const char* key) {
    const auto* field = find_setting(key);
    require(field != nullptr, QStringLiteral("Saved edits name a setting this build has no row for: ") +
                                  QLatin1String(key));
    return *field;
}
// A stock is an identifier, never a path. With the caller's catalogue it
// must also be installed; a missing one blocks the record rather than
// silently falling back to a default.
std::string stockId(const QString& id, const SettingField& field, const Catalog* catalog) {
    static const QRegularExpression syntax(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"));
    require(syntax.match(id).hasMatch(), QStringLiteral("Saved edits contain an invalid stock ID"));
    const auto value = id.toStdString();
    if (catalog)
        require(check_setting(field, value, catalog).empty(),
                QStringLiteral("Saved edits refer to an unavailable stock: ") + id);
    return value;
}
QJsonValue jsonValue(const SettingValue& value) {
    return std::visit([](const auto& v) -> QJsonValue {
        if constexpr (std::is_same_v<std::decay_t<decltype(v)>, std::string>) return QString::fromStdString(v);
        else return QJsonValue(v);
    }, value);
}
// Strict: the row's JSON type, range and choices, exactly as the host will
// validate them, so a record that loads is a record that renders.
SettingValue settingValue(const SettingField& field, const QJsonValue& value, const QString& name,
                          const Catalog* catalog) {
    switch (field.type) {
    case SettingType::boolean:
        require(value.isBool(), QStringLiteral("Saved edit field must be true or false: ") + name);
        return value.toBool();
    case SettingType::number: {
        require(value.isDouble(), QStringLiteral("Saved edit field must be numeric: ") + name);
        const double result = value.toDouble();
        require(check_setting(field, result).empty(),
                QStringLiteral("Saved edit field is outside its valid range: ") + name);
        return result;
    }
    case SettingType::text: {
        require(value.isString(), QStringLiteral("Saved edit field must be text: ") + name);
        if (field.choices == SettingChoices::free) {
            // The user's own line (the Date Back's typed date): the row's
            // length and character rule, exactly as the host checks it.
            auto text = value.toString().toStdString();
            require(check_setting(field, text).empty(), QStringLiteral("Saved edit field has unsupported text: ") + name);
            return text;
        }
        if (field.choices != SettingChoices::listed) return stockId(value.toString(), field, catalog);
        auto text = value.toString().toStdString();
        require(check_setting(field, text).empty(), QStringLiteral("Saved edit field has an unsupported value: ") + name);
        return text;
    }
    }
    fail(QStringLiteral("Saved edit field has an unknown type: ") + name);
}

QJsonObject settingsJson(const RenderSettings& settings) {
    QJsonObject out;
    for (const auto& field : setting_fields())
        out.insert(QString::fromStdString(field.key), jsonValue(settings.get(field.key)));
    return out;
}
RenderSettings parseSettings(const QJsonObject& s, int version, const Catalog* catalog, QStringList* unknown) {
    RenderSettings out;
    if (version == 1) {
        QStringList saved;
        for (const auto& v : version1Settings) saved.append(QLatin1String(v.saved));
        keys(s, saved, QStringLiteral("state.settings"));
        // Rows added since take what the record was rendered with: the
        // engine default, which is every row's `absent`.
        for (const auto& field : setting_fields()) out.set(field.key, field.absent);
        for (const auto& v : version1Settings)
            out.set(v.key, settingValue(settingRow(v.key), s.value(QLatin1String(v.saved)),
                                        QLatin1String(v.saved), catalog));
        // Except the filter scale when both shifts are zero: the pack is
        // neutral + shift x scale, so such a print is identical at any scale
        // (spk_desktop_settings_engine renders it), and the photograph gets
        // the macOS slider strength at no cost to how it looks.
        if (out.y_filter_shift == 0.0 && out.m_filter_shift == 0.0)
            out.set("filter_shift_scale", settingRow("filter_shift_scale").initial);
        return out;
    }
    QStringList known;
    for (const auto& field : setting_fields()) {
        const auto name = QString::fromStdString(field.key);
        known.append(name);
        if (s.contains(name)) {
            out.set(field.key, settingValue(field, s.value(name), name, catalog));
        } else {
            require(!requiredSetting(field.key), QStringLiteral("Saved edits are missing state.settings.") + name);
            out.set(field.key, field.absent);
        }
    }
    for (auto it = s.begin(); it != s.end(); ++it)
        if (!known.contains(it.key())) unknown->append(QStringLiteral("state.settings.") + it.key());
    return out;
}

QJsonObject geometryJson(const output::Geometry& g) {
    return QJsonObject{
        {"crop", QJsonObject{{"x", g.crop.x()}, {"y", g.crop.y()},
                              {"width", g.crop.width()}, {"height", g.crop.height()}}},
        {"quarterTurns", g.quarterTurns}, {"flipHorizontal", g.flipHorizontal},
        {"flipVertical", g.flipVertical}, {"straightenDegrees", g.straightenDegrees}};
}
QJsonObject stateJson(const State& state) {
    QString mode;
    switch (state.mode) {
    case DecodeMode::compatible16: mode = QStringLiteral("compatible16"); break;
    case DecodeMode::headroom: mode = QStringLiteral("headroom"); break;
    default: fail(QStringLiteral("Saved edits contain an unsupported RAW decode mode"));
    }
    // heldGeometry is always written, null when there is none, so a save
    // over a record that had one clears it rather than keeping it as a newer
    // build's field.
    return {{"settings", settingsJson(state.settings)},
        {"decodeMode", mode}, {"geometry", geometryJson(state.geometry)},
        {"heldGeometry", state.heldGeometry ? QJsonValue(geometryJson(*state.heldGeometry)) : QJsonValue()}};
}
output::Geometry parseGeometry(const QJsonObject& g, const QString& label, QStringList* extra) {
    keys(g, {"crop", "quarterTurns", "flipHorizontal", "flipVertical", "straightenDegrees"}, label, extra);
    // A rectangle has exactly four numbers in every version.
    const auto crop = object(g, "crop");
    keys(crop, {"x", "y", "width", "height"}, label + QStringLiteral(".crop"));
    const double x = number(crop, "x", 0.0, 1.0), y = number(crop, "y", 0.0, 1.0);
    const double width = number(crop, "width", 0.0, 1.0), height = number(crop, "height", 0.0, 1.0);
    require(width > 0 && height > 0 && x + width <= 1.0 && y + height <= 1.0,
            QStringLiteral("Saved crop is empty or outside the image"));
    output::Geometry geometry;
    geometry.crop = QRectF(x, y, width, height);
    const double turns = number(g, "quarterTurns", 0.0, 3.0);
    require(std::floor(turns) == turns, QStringLiteral("Saved quarter turns must be an integer"));
    geometry.quarterTurns = int(turns);
    geometry.flipHorizontal = boolean(g, "flipHorizontal");
    geometry.flipVertical = boolean(g, "flipVertical");
    geometry.straightenDegrees = number(g, "straightenDegrees", -45.0, 45.0);
    return geometry;
}
// `unknown` collects version-2 fields this build does not know; a caller
// that does not need them may pass nullptr. Version 1 has none to collect.
State parseState(const QJsonObject& value, int version, const Catalog* catalog, QStringList* unknown) {
    QStringList ignored;
    QStringList* extra = version == 1 ? nullptr : unknown ? unknown : &ignored;
    // Version 2's optional heldGeometry -- the user's own crop while a film
    // edge holds the crop at its gate (macOS Sidecar.heldCrop) -- is known
    // here; a record from before it has none.
    QJsonObject required = value;
    const auto held = version == 1 ? QJsonValue() : required.take(QStringLiteral("heldGeometry"));
    keys(required, {"settings", "decodeMode", "geometry"}, QStringLiteral("state"), extra);
    State state;
    state.settings = parseSettings(object(value, "settings"), version, catalog, extra);
    const auto mode = string(value, "decodeMode");
    require(mode == "compatible16" || mode == "headroom",
            QStringLiteral("Saved edits contain an unsupported RAW decode mode"));
    state.mode = mode == "headroom" ? DecodeMode::headroom : DecodeMode::compatible16;
    state.geometry = parseGeometry(object(value, "geometry"), QStringLiteral("state.geometry"), extra);
    if (!held.isNull() && !held.isUndefined()) {
        require(held.isObject(), QStringLiteral("Saved edit field must be an object: heldGeometry"));
        state.heldGeometry = parseGeometry(held.toObject(), QStringLiteral("state.heldGeometry"), extra);
    }
    return state;
}

struct Identity {
    QString path;
    qint64 size = 0, mtime = 0;
    QString sample;
    bool operator==(const Identity&) const = default;
};
Identity identity(const QString& source) {
    const QFileInfo before(source);
    require(before.exists() && before.isFile(), QStringLiteral("Cannot find source while checking saved edits"));
    QFile file(source);
    require(file.open(QIODevice::ReadOnly), QStringLiteral("Cannot read source while checking saved edits: ") + file.errorString());
    Identity result{pathIdentity(source), before.size(), before.lastModified().toMSecsSinceEpoch(), {}};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    const auto first = file.read(std::min(result.size, sampleBytes));
    require(first.size() == std::min(result.size, sampleBytes), QStringLiteral("Cannot fingerprint source for saved edits"));
    hash.addData(first);
    if (result.size > sampleBytes) {
        const qint64 tail = std::min(sampleBytes, result.size - sampleBytes);
        require(file.seek(result.size - tail), QStringLiteral("Cannot seek source while checking saved edits"));
        const auto last = file.read(tail);
        require(last.size() == tail, QStringLiteral("Cannot fingerprint the end of the source"));
        hash.addData(last);
    }
    const QFileInfo after(source);
    require(after.exists() && after.size() == result.size &&
                after.lastModified().toMSecsSinceEpoch() == result.mtime,
            QStringLiteral("Source changed while checking saved edits; try again when copying has finished"));
    result.sample = QString::fromLatin1(hash.result().toHex());
    return result;
}
QJsonObject identityJson(const Identity& value) {
    // Decimal strings keep 64-bit timestamps and file sizes exact in JSON.
    return {{"path", value.path}, {"size", QString::number(value.size)},
            {"mtimeMs", QString::number(value.mtime)}, {"sampleSha256", value.sample}};
}
Identity parseIdentity(const QJsonObject& value) {
    keys(value, {"path", "size", "mtimeMs", "sampleSha256"}, QStringLiteral("source"));
    Identity result;
    result.path = string(value, "path");
    require(!result.path.isEmpty() && QDir::isAbsolutePath(result.path),
            QStringLiteral("Saved edits have an invalid source path"));
    bool ok = false;
    const QString size = string(value, "size");
    result.size = size.toLongLong(&ok);
    require(ok && result.size >= 0 && QString::number(result.size) == size,
            QStringLiteral("Saved edits have an invalid source size"));
    const QString mtime = string(value, "mtimeMs");
    result.mtime = mtime.toLongLong(&ok);
    require(ok && QString::number(result.mtime) == mtime,
            QStringLiteral("Saved edits have an invalid source timestamp"));
    result.sample = string(value, "sampleSha256");
    static const QRegularExpression hex(QStringLiteral("^[0-9a-f]{64}$"));
    require(hex.match(result.sample).hasMatch(), QStringLiteral("Saved edits have an invalid source fingerprint"));
    return result;
}
QByteArray fingerprint(const Identity& value) {
    return QCryptographicHash::hash(QJsonDocument(identityJson(value)).toJson(QJsonDocument::Compact),
                                    QCryptographicHash::Sha256);
}
bool recordExists(const QString& path) {
    const QFileInfo info(path);
    return info.exists() || info.isSymLink();
}
QJsonObject readDocument(const QString& path, QByteArray* digest, int* version, QStringList* unknown) {
    const QFileInfo info(path);
    require(!info.isSymLink() && info.isFile(), QStringLiteral("Saved edit path is not a regular file"));
    QFile file(path);
    require(file.open(QIODevice::ReadOnly), QStringLiteral("Cannot read saved edits: ") + file.errorString());
    require(file.size() <= maximumDocumentBytes, QStringLiteral("Saved edit document exceeds the 64 KiB limit"));
    const auto bytes = file.read(maximumDocumentBytes + 1);
    require(bytes.size() == file.size() && bytes.size() <= maximumDocumentBytes,
            QStringLiteral("Cannot read the complete saved edit document"));
    if (digest) *digest = QCryptographicHash::hash(bytes, QCryptographicHash::Sha256);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    require(error.error == QJsonParseError::NoError && document.isObject(),
            QStringLiteral("Saved edits contain invalid JSON: ") + error.errorString());
    const auto result = document.object();
    const auto format = result.value(QStringLiteral("format"));
    require(format.isString() && format.toString() == formatName,
            QStringLiteral("Saved edits use an unsupported document format"));
    // A later version is preserved, never reinterpreted: only 1 and 2 load.
    const auto number = result.value(QStringLiteral("version"));
    require(number.isDouble() && (number.toDouble() == 1.0 || number.toDouble() == 2.0),
            QStringLiteral("Saved edits use an unsupported version; existing file was preserved"));
    const int found = int(number.toDouble());
    QStringList ignored;
    keys(result, {"format", "version", "source", "state"}, QStringLiteral("document"),
         found == 1 ? nullptr : unknown ? unknown : &ignored);
    *version = found;
    return result;
}
State checkDocument(const QJsonObject& document, int version, const Identity& source,
                    const Catalog* catalog, QStringList* unknown) {
    const auto stored = parseIdentity(object(document, "source"));
    require(stored.path == source.path, QStringLiteral("Saved edits belong to a different source; existing file was preserved"));
    require(stored == source, QStringLiteral("The source file changed since these edits were saved; existing edits were preserved"));
    return parseState(object(document, "state"), version, catalog, unknown);
}
// Replaces what this build writes and keeps every other field, at every
// level a newer build may extend. The crop is a rectangle and is replaced.
QJsonObject overlay(QJsonObject base, const QJsonObject& known) {
    for (auto it = known.begin(); it != known.end(); ++it) {
        const auto previous = base.value(it.key());
        if (it.value().isObject() && previous.isObject() && it.key() != QStringLiteral("crop"))
            base.insert(it.key(), overlay(previous.toObject(), it.value().toObject()));
        else
            base.insert(it.key(), it.value());
    }
    return base;
}
} // namespace

Store::Store(QString directory) : directory_(QDir::cleanPath(directory)) {
    require(!directory.isEmpty() && QDir::isAbsolutePath(directory),
            QStringLiteral("Saved edit store requires an explicit absolute directory"));
}
QString Store::filePath(const QUrl& source) const {
    const auto digest = QCryptographicHash::hash(pathIdentity(sourcePath(source)).toUtf8(),
                                                QCryptographicHash::Sha256).toHex();
    return QDir(directory_).filePath(QString::fromLatin1(digest) + ".json");
}
LoadResult Store::load(const QUrl& source, const Catalog& catalog) const {
    QString key;
    try {
        key = observationKey(source);
        const auto path = filePath(source);
        const auto sourceId = identity(sourcePath(source));
        if (!recordExists(path)) {
            observations_.insert(key, {fingerprint(sourceId), {}, {}, catalog});
            return {};
        }
        QByteArray recordDigest;
        int version = 0;
        QStringList preserved;
        const auto document = readDocument(path, &recordDigest, &version, &preserved);
        observations_.insert(key, {fingerprint(sourceId), recordDigest, {}, catalog});
        auto state = checkDocument(document, version, sourceId, &catalog, &preserved);
        return {std::move(state), {}, false, version, preserved};
    } catch (const std::exception& error) {
        const auto warning = QString::fromUtf8(error.what());
        if (!key.isEmpty()) {
            auto& observation = observations_[key];
            observation.warning = warning;
            observation.catalog = catalog;
        }
        return {{}, warning, true};
    }
}
void Store::save(const QUrl& source, const State& state) const {
    const auto key = observationKey(source);
    const auto path = filePath(source);
    const auto observed = observations_.constFind(key);
    if (observed != observations_.cend() && !observed->warning.isEmpty()) fail(observed->warning);
    const auto value = stateJson(state);
    const auto catalog = observed != observations_.cend() ? observed->catalog : std::optional<Catalog>{};
    // Root callers load with a current catalogue first. Direct save callers
    // have no catalogue, but still receive complete shape/range validation.
    const Catalog* stocks = catalog ? &*catalog : nullptr;
    (void)parseState(value, currentVersion, stocks, nullptr);
    const auto sourceFile = sourcePath(source);
    const auto sourceId = identity(sourceFile);
    if (observed != observations_.cend())
        require(observed->source == fingerprint(sourceId),
                QStringLiteral("The source file changed after it was opened; edits remain unsaved"));
    require(pathIdentity(QFileInfo(sourceFile).absolutePath()) !=
                pathIdentity(QFileInfo(directory_).canonicalFilePath().isEmpty()
                    ? directory_ : QFileInfo(directory_).canonicalFilePath()),
            QStringLiteral("Saved edit store must not be beside the source photograph"));
    require(QDir().mkpath(directory_), QStringLiteral("Cannot create the saved edit directory"));
    QLockFile lock(path + ".lock");
    lock.setStaleLockTime(30000);
    require(lock.tryLock(0), QStringLiteral("Saved edits are being written by another process; try again"));
    QByteArray previousDigest;
    QJsonObject previous;
    int previousVersion = 0;
    if (recordExists(path)) {
        previous = readDocument(path, &previousDigest, &previousVersion, nullptr);
        (void)checkDocument(previous, previousVersion, sourceId, nullptr, nullptr);
    }
    if (observed != observations_.cend())
        require(observed->record == previousDigest,
                QStringLiteral("Saved edits changed in another instance; restart the app and reopen the photo before saving"));
    // A version-1 record is rewritten whole (it can hold nothing unknown). A
    // version-2 record keeps every field a newer build wrote there: the digest
    // check above proves it is the record this instance loaded.
    const bool extend = previousVersion == currentVersion;
    QJsonObject document = extend ? previous : QJsonObject{};
    document.insert(QStringLiteral("format"), formatName);
    document.insert(QStringLiteral("version"), currentVersion);
    document.insert(QStringLiteral("source"), identityJson(sourceId));
    document.insert(QStringLiteral("state"),
                    extend ? overlay(previous.value(QStringLiteral("state")).toObject(), value) : value);
    (void)parseState(document.value(QStringLiteral("state")).toObject(), currentVersion, stocks, nullptr);
    const auto bytes = QJsonDocument(document).toJson(QJsonDocument::Indented);
    require(bytes.size() <= maximumDocumentBytes, QStringLiteral("Saved edit document exceeds the 64 KiB limit"));
    QSaveFile file(path);
    file.setDirectWriteFallback(false);
    require(file.open(QIODevice::WriteOnly), QStringLiteral("Cannot open saved edits for atomic writing: ") + file.errorString());
    require(file.write(bytes) == bytes.size(), QStringLiteral("Cannot write saved edits: ") + file.errorString());
    require(file.commit(), QStringLiteral("Cannot atomically save edits: ") + file.errorString());
    observations_.insert(key, {fingerprint(sourceId),
                                QCryptographicHash::hash(bytes, QCryptographicHash::Sha256), {}, catalog});
}

QJsonObject stateToJson(const State& state) { return stateJson(state); }
State stateFromJson(const QJsonObject& value, const Catalog* catalog, QStringList* unknown) {
    return parseState(value, currentVersion, catalog, unknown);
}
QJsonObject geometryToJson(const output::Geometry& geometry) { return geometryJson(geometry); }
output::Geometry geometryFromJson(const QJsonObject& value, const QString& label, QStringList* unknown) {
    return parseGeometry(value, label, unknown);
}

} // namespace spk::desktop::editing
