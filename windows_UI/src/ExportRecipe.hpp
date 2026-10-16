#pragma once
// A named, saved answer to "where, called what, in what": the macOS export
// page's recipe (modern_UI/.../Export/ExportRecipe.swift), its colour-space
// catalogue, its four naming tokens, its destination rules and its JSON file.
// Rendering is not here (RecipeExport.hpp owns the pixels); this file only
// answers where they go and what tag they carry.
//
// The JSON is the Mac's own shape (Swift's synthesized Codable), so one
// export-recipes.json reads on either platform:
//   {"id": "<UUID>", "name": "...", "format": "JPEG" | "PNG 8-bit" |
//    "TIFF 16-bit" | "DI package",
//    "colorSpace": {"builtIn": {"_0": "kCGColorSpaceDisplayP3"}}
//                | {"installed": {"path": "..."}},
//    "folder": {"besideOriginal": {}} | {"fixed": {"path": "..."}},
//    "subfolder": "_prints",
//    "naming": {"order": [...4 tokens], "tokens": [...on], "separator": "_"},
//    "existing": "addSuffix" | "overwrite" | "skip",
//    "quality": 0.95, "outputSize": {"original": true} | {"longEdge": 4000},
//    "openWith": {"path": "..."} (absent: None), "embedsPreview": false}
// plus one Windows field the Mac does not have (its exporter always copies
// the camera's EXIF): "metadata": {"exif": true, "fields": [...]}. Every
// field reads leniently, as the Mac's init(from:) does: a missing or unknown
// value takes its default instead of failing the whole file.
#include <QDate>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace spk::desktop::recipes {

// ExportFormat (Exporter.swift:28): the format *is* the bit depth.
enum class Format { jpeg, png, tiff, di };
QString formatRaw(Format);             // "JPEG", "PNG 8-bit", "TIFF 16-bit", "DI package"
QString formatLabel(Format);           // the pill: "JPEG", "PNG", "TIFF", "Digital Intermediate"
QString formatExtension(Format);       // jpg, png, tif, tif
int formatBitDepth(Format);            // 8, 8, 16, 16
inline bool takesColorSpace(Format f) { return f != Format::di; }
inline bool takesQuality(Format f) { return f == Format::jpeg; }
inline bool carriesPreviewPage(Format f) { return f == Format::tiff; }
// The depth pill: PNG <-> TIFF only (ExportFormat.withDepth).
std::optional<Format> withDepth(int depth, Format like);

// ColorSpaceCatalog.builtIns, in the Mac's order. `key` is the CGColorSpace
// name the Mac stores; `engine` the engine's name for the same space.
struct ColorSpaceEntry { QString key, name; std::string engine; };
const std::vector<ColorSpaceEntry>& colorSpaces();
const ColorSpaceEntry* colorSpace(const QString& key);
inline const QString kDisplayP3 = QStringLiteral("kCGColorSpaceDisplayP3");
inline const QString kSRGB = QStringLiteral("kCGColorSpaceSRGB");

// NameToken: four, and only four (notes.md via ExportRecipe.swift:219).
enum class Token { originalName, filmStock, printStock, date };
QString tokenRaw(Token);
QString tokenLabel(Token);
std::optional<Token> tokenFromRaw(const QString&);
inline const QList<Token> kAllTokens{Token::originalName, Token::filmStock, Token::printStock, Token::date};

struct NameContext {
    QString originalName, filmStock, printStock;
    QDate date = QDate::currentDate();
};

// NamingRule: `order` holds all four tokens in the chip row's order,
// `tokens` the ones switched on (never empty); the filename is the order
// filtered by the selection.
struct Naming {
    QList<Token> tokens{Token::originalName, Token::filmStock, Token::printStock};
    QList<Token> order = kAllTokens;
    QString separator = QStringLiteral("_");
    QList<Token> chosen() const;
    bool isOn(Token t) const { return tokens.contains(t); }
    void toggle(Token t);              // refuses to turn off the last one
    void move(Token t, Token before);  // drag one chip onto another
    void resetOrder() { order = kAllTokens; }
    // The stem: no extension, no directory. Empty falls back to the original
    // name; characters a Windows filename cannot hold become "-".
    QString stem(const NameContext&) const;
    QJsonObject toJson() const;
    static Naming fromJson(const QJsonObject&);
    bool operator==(const Naming&) const = default;
};

enum class Existing { addSuffix, overwrite, skip };
QString existingRaw(Existing);
QString existingLabel(Existing);

// Windows: which EXIF fields an export copies from the camera file.
struct Metadata {
    bool exif = true;
    bool camera = true, lens = true, exposure = true, date = true;
    QJsonObject toJson() const;
    static Metadata fromJson(const QJsonObject&);
    bool operator==(const Metadata&) const = default;
};

struct Recipe {
    QString id;                         // UUID, upper case as Swift writes it
    QString name = QStringLiteral("Untitled");
    Format format = Format::jpeg;
    QString colorSpace = kDisplayP3;    // a catalogue key, or "installed:<path>"
    bool besideOriginal = true;
    QString folder;                     // when not beside the original
    QString subfolder = QStringLiteral("_prints");
    Naming naming;
    Existing existing = Existing::addSuffix;
    double quality = 0.95;              // JPEG, 0.3..1 on the page
    int longEdge = 0;                   // 0: Original; else 16..60000, never enlarged
    QString openWith;                   // "" None, "default", "explorer", or an .exe path
    bool embedsPreview = false;
    Metadata metadata;

    Recipe();                           // a fresh id
    QJsonObject toJson() const;
    static Recipe fromJson(const QJsonObject&);
    bool operator==(const Recipe&) const = default;

    // The directory for a source photograph, not created here.
    QString directory(const QString& sourcePath) const;
    // The path for `stem`, ignoring the existing-file policy. A Digital
    // Intermediate is `<stem>_DI.tif` (ExportRecipe.destinationPath).
    QString destinationPath(const QString& sourcePath, const QString& stem) const;
    // The engine space the file is converted to and tagged with, and whether
    // the recipe's choice could not be honoured (an installed profile the
    // engine has no space for: Display P3, said so -- Exporter.resolveTarget).
    std::string engineSpace(bool* fellBack = nullptr) const;
    QString colorSpaceName() const;
    // OutputSize.pixels(for:): the size to write, or the source's own.
    static int clampEdge(int edge);
};

// A path the policy would claim, with `exists` as the test; nullopt for
// Skip when the first is taken. Suffixes are -1, -2, ... on the stem.
std::optional<QString> resolveDestination(const Recipe&, const QString& sourcePath, const NameContext&,
                                          const std::function<bool(const QString&)>& exists);

QList<Recipe> defaults();
inline const QString kDigitalIntermediateName = QStringLiteral("Digital Intermediate");

// The recipes file. Never fatal: an unreadable file yields the defaults and
// `problem`, and the file is left alone until the next edit saves over it.
struct LoadResult { QList<Recipe> recipes; QString problem; bool existed = false; };
LoadResult load(const QString& path);
// Atomic (QSaveFile). Empty string on success, else the reason.
QString save(const QString& path, const QList<Recipe>& recipes);
// Where the file lives: beside the edit store's folder, so the default is
// <AppLocalData>/export-recipes.json next to <AppLocalData>/Edits and a test
// that passes --edit-store <dir>/edits gets <dir>/export-recipes.json.
QString storePath(const QString& editDirectory);

}  // namespace spk::desktop::recipes
