pragma Singleton
import QtQuick
import SpektraLab.Native 1.0

// Every user-visible string in QML is L10n.tr("area.key") or
// L10n.tr("area.key", [arg0, arg1]); the text lives in windows_UI/i18n/*.json
// (i18n/README.md) and is served by the C++ Localizer.
//
// Why this file exists rather than calling Localizer directly: a binding that
// calls into C++ registers no dependency, so `text: Localizer.translate("x")`
// would keep the old language after a switch. Reading `revision` here does
// register one, for every binding that calls tr(), so switching `language`
// re-evaluates every label at once -- no reload and no retranslate pass, and
// no call site can forget it.
QtObject {
    // "en" by default; see Localizer.hpp for "system" and the loaded codes.
    readonly property string language: Localizer.language
    readonly property var availableLanguages: Localizer.availableLanguages
    function setLanguage(code) { Localizer.language = code }

    function tr(key, args) {
        Localizer.revision
        return Localizer.translate(key, args === undefined ? [] : args)
    }
}
