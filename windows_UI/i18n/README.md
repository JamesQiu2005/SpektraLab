# Interface text

Every user-visible string in the Windows editor's QML is looked up by key in
a JSON table, one file per language. The application ships English only
(`en.json`); the tables, the lookup and the switch are in place so another
language is a file, not a code change.

## How it fits together

- `en.json` is the source of truth. Every key the interface uses exists here,
  in English. Where the macOS app has the same string, the English is the
  Mac's (`modern_UI/Spektrafilm/Spektrafilm/Localization/Strings.swift`).
- `src/Localizer.hpp/.cpp` loads the tables and answers lookups. It is
  registered for QML as the `Localizer` singleton (`SpektraLab.Native`); C++
  code can use `Localizer::text(key, args)` with the same tables.
- `qml/L10n.qml` is what QML calls: `L10n.tr("film.title")` or
  `L10n.tr("strip.count", [photos, selected])`. It reads `Localizer.revision`
  on every call, which is what makes each binding that shows a string
  re-evaluate when the language changes; calling `Localizer.translate()`
  directly from a binding would not update on a switch.
- Tables are loaded from the compiled-in resources (`:/i18n`, listed in
  `windows_UI/CMakeLists.txt`) and then from an `i18n` folder beside
  `SpektraLabQt.exe`, if there is one. A later table for the same language
  overrides it key by key, so a translator can fix or add text without a
  rebuild.
- The language is English unless something sets `Localizer.language` (or
  calls `L10n.setLanguage(code)`): to a loaded code, or to `"system"`, which
  follows the Windows display languages. Nothing selects a language from the
  system automatically, there is no language menu yet, and the choice is not
  persisted.

## File format

```json
{
    "language": "de",
    "name": "Deutsch",
    "englishName": "German",
    "strings": {
        "film.title": "Film",
        "strip.count": "{0} Fotos · {1} ausgewählt"
    }
}
```

- `language` is the code (BCP 47: `de`, `pt-BR`, `zh-Hans`). The file name
  is used only when the header has none.
- `name` is the language's name in that language, for a future language menu
  (its reader may not read the current language); `englishName` is for
  everyone else.
- `strings` is a flat map of key to text. UTF-8, no comments (JSON has none).

## Keys

`area.item`, optionally `area.item.variant`, in lowerCamelCase segments. The
area is the part of the window that shows the text: `toolbar`, `navigator`,
`film`, `print`, `crop`, `enlarger`, `canvas`, `statusBar`, `strip`,
`camera`, `format`, `effect`, `decode`, `info`, `status`, `export`, `dialog`,
`rail`. Verbs used in more than one place are `action.*`. Two strings that
happen to share an English spelling but mean different things (the Crop
section title and the Crop button) get separate keys, because another
language may not spell them alike.

Not looked up, and written where they are used: film and paper names, file
names, units with their numbers (`18 mm`, `100%`, `°`, ` EV`), aspect ratios
(`3:2`), file-name patterns (`*.arw`) and shortcut names inside a string's own
text.

## Placeholders

`{0}`, `{1}`, ... are replaced by the arguments in order, and may appear in
any order or more than once (`"{1} of {0}"`). Any other text in braces is
left as it is. A placeholder that is in the English must stay in each
translation; numbers arrive already formatted (`"2.31"`, not `2.3071`).

## Adding a language

1. Copy `en.json` to `<code>.json`, set the header, translate the values.
   A key you leave out, or leave empty, shows the English.
2. To try it without rebuilding, put the file in `i18n\` beside
   `SpektraLabQt.exe` and set the language (there is no menu yet). To ship
   it, add it to the `qt_add_resources(... spektralab_i18n ...)` list in
   `windows_UI/CMakeLists.txt`.
3. Run CTest: `spk_qt_localizer` checks that every shipped table only uses
   keys `en.json` defines and that every key the QML asks for exists. At run
   time a key a table has but English lacks is logged at start
   (`spektralab.l10n`), and a key English lacks is logged once and shown as
   the key itself.

## Adding a string

Add the key and its English to `en.json` and use `L10n.tr("area.key")` in
QML. A QML `ComboBox` whose model is built from `L10n.tr()` and whose
`currentIndex` is a binding must read `model` in that binding (see
`qml/right/FilmFormatSection.qml`): a language switch replaces the model,
which resets the index to 0, and only a binding that depends on `model`
puts it back.

## Not localised yet

Status and error text produced in C++ (`src/PreviewController.cpp`, the
host's messages) reaches QML already written and is shown as is.
