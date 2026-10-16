// The controller's settings API without a photograph: the real engine supplies
// the catalogue, an explicit directory is the edit store (nothing is opened, so
// nothing is written), and no RAW fixture is needed. Undo steps need an open
// photograph and are covered by spk_qt_editing_workflow_test.
#include "PreviewController.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFileInfo>
#include <QTimer>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>

namespace desktop = spk::desktop;
namespace {
int checks = 0;
void check(bool value, const std::string& message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
QVariant initial(const char* key) {
    const auto* field = desktop::find_setting(key);
    check(field != nullptr, std::string("no settings row ") + key);
    const auto& value = field->initial;
    if (std::holds_alternative<bool>(value)) return std::get<bool>(value);
    if (std::holds_alternative<double>(value)) return std::get<double>(value);
    return QString::fromStdString(std::get<std::string>(value));
}
int stockIndex(const QVariantList& stocks, const QString& id) {
    for (int i = 0; i < stocks.size(); ++i)
        if (stocks[i].toMap().value("id").toString() == id) return i;
    return -1;
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    try {
        const auto args = application.arguments();
        check(args.size() == 3, "usage: spk_qt_controller_settings_test <resources> <scratch-directory>");
        check(QDir().mkpath(args[2]), "cannot create scratch directory");
        const auto edits = QDir(args[2]).absoluteFilePath("edits");
        PreviewController c(std::filesystem::path(args[1].toStdWString()), nullptr, {}, edits);
        {
            QEventLoop wait;
            QObject::connect(&c, &PreviewController::initialized, &wait, &QEventLoop::quit);
            QTimer::singleShot(60000, &wait, &QEventLoop::quit);
            if (!c.ready() && !c.failed()) wait.exec();
        }
        check(c.ready(), "engine initialization: " + c.status().toStdString());

        // The table, as QML sees it.
        const auto fields = c.parameterFields();
        check(fields.size() == qsizetype(desktop::setting_fields().size()), "parameterFields omits rows");
        for (const auto& entry : fields) {
            const auto row = entry.toMap();
            const auto* field = desktop::find_setting(row.value("key").toString().toStdString());
            check(field != nullptr, "parameterFields names an unknown key");
            check(row.value("label").toString().size() > 0 && !row.value("layer").toString().isEmpty(),
                  "parameterFields row lacks label or layer");
            if (field->type == desktop::SettingType::number)
                check(row.value("type") == "number" && row.value("from").toDouble() == field->low &&
                      row.value("to").toDouble() == field->high, "number row range not exposed");
        }
        for (const auto& entry : fields) {
            const auto row = entry.toMap();
            if (row.value("key") == "auto_exposure_method")
                check(row.value("choices").toStringList().contains("protect_shadows"), "metering choices not exposed");
            if (row.value("key") == "print_stock") check(row.value("catalog") == "papers", "paper row lacks catalogue");
        }

        // A new photograph's settings: macOS's paper, filter strength and metering.
        auto parameters = c.parameters();
        check(parameters.size() == fields.size(), "parameters omits rows");
        for (const auto& field : desktop::setting_fields())
            check(parameters.value(QString::fromStdString(field.key)) == initial(field.key.c_str()),
                  "default parameter differs from its row: " + field.key);
        check(parameters.value("print_stock") == "kodak_supra_endura" &&
              c.paperIndex() == stockIndex(c.papers(), "kodak_supra_endura"), "default paper is not Supra Endura");
        check(c.filmIndex() == stockIndex(c.films(), "kodak_portra_400"), "default film is not Portra 400");
        check(parameters.value("filter_shift_scale").toDouble() == 40.0, "filter sliders are not macOS strength");
        check(parameters.value("auto_exposure_method") == "balanced", "default metering is not balanced");
        check(c.exposureEv() == 0 && !c.dirty(), "default brightness or dirty state");

        int changes = 0;
        QObject::connect(&c, &PreviewController::settingsChanged, &c, [&] { ++changes; });
        const auto refused = [&](const char* key, const QVariant& value, const char* why) {
            const int before = changes;
            const auto was = c.parameters();
            check(!c.setParameter(key, value), std::string("accepted: ") + why);
            check(changes == before && c.parameters() == was, std::string("refusal changed settings: ") + why);
        };
        refused("no_such_setting", 1.0, "unknown key");
        refused("grain_amount", true, "bool for a number");
        refused("grain_amount", QStringLiteral("0.5"), "numeric text for a number");
        refused("grain_amount", 2.01, "above range");
        refused("grain_amount", std::numeric_limits<double>::quiet_NaN(), "NaN");
        refused("grain_active", 1.0, "number for a bool");
        refused("filter_shift_scale", 0.5, "scale below 1");
        refused("auto_exposure_method", QStringLiteral("spot"), "unknown metering");
        refused("film_stock", QStringLiteral("no_such_film"), "film outside the catalogue");

        // Generic and legacy names reach the same value.
        check(c.setParameter("y_filter_shift", 0.25) && c.adjustments().value("yFilterShift").toDouble() == 0.25 &&
              c.parameter("y_filter_shift").toDouble() == 0.25, "generic setter missed the legacy view");
        c.setAdjustment("grainAmount", QStringLiteral("0.5"));  // the first QML's lenient conversion
        check(c.parameters().value("grain_amount").toDouble() == 0.5, "legacy setter missed the generic view");
        c.setAdjustment("glareActive", 0);
        check(c.parameter("glare_active") == false && c.adjustments().value("glareActive") == false,
              "legacy bool setter");
        check(c.setParameter("filter_shift_scale", 12) && c.parameter("filter_shift_scale").toDouble() == 12.0,
              "integer for a number row");
        check(c.setParameter("auto_exposure_method", QStringLiteral("center")) &&
              c.parameter("auto_exposure_method") == "center", "metering choice");
        const int before = changes;
        check(c.setParameter("auto_exposure_method", QStringLiteral("center")) && changes == before,
              "an unchanged value counted as an edit");

        // Stocks and brightness keep their own state and rules.
        check(c.setParameter("film_stock", QStringLiteral("kodak_ektar_100")) &&
              c.filmIndex() == stockIndex(c.films(), "kodak_ektar_100"), "generic film change");
        check(c.setParameter("print_exposure", 0.5) && c.exposureEv() == 1.0 &&
              c.parameter("print_exposure").toDouble() == 0.5, "print exposure is not 2^-stops");
        check(c.setParameter("print_stock", QStringLiteral("kodak_portra_endura")) &&
              c.paperIndex() == stockIndex(c.papers(), "kodak_portra_endura"), "generic paper change");
        check(c.setParameter("film_stock", QStringLiteral("kodak_ektachrome_100")) && c.filmIsPositive(),
              "generic slide film change");
        refused("print_stock", QStringLiteral("kodak_supra_endura"), "paper for a slide");
        refused("print_exposure", 2.0, "brightness for a slide");
        check(c.setParameter("film_stock", QStringLiteral("kodak_portra_400")) && !c.filmIsPositive() &&
              c.parameter("print_stock") == "kodak_portra_endura", "negative film lost its paper");

        // The deployed resources carry the product's black-and-white profiles
        // and their notice, beside the application's licences too.
        const QDir resources(args[1]);
        for (const char* id : {"kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii",
                               "ilford_hp5_plus_400", "ilford_multigrade_iv_rc"})
            check(QFileInfo(resources.filePath(QStringLiteral("profiles/%1.json").arg(QLatin1String(id)))).isFile(),
                  std::string("black-and-white profile not deployed: ") + id);
        check(QFileInfo(resources.filePath("PRODUCT_PROFILES_NOTICE.md")).isFile() &&
              QFileInfo(resources.filePath("../licenses/PRODUCT_PROFILES_NOTICE.md")).isFile(),
              "the black-and-white profiles' notice is not deployed");

        // The macOS lists: films Positive, Negative, Black & White; papers
        // Still, Cine, then the Positive group's No Print Profile row.
        const auto filmRows = c.filmCatalog();
        check(filmRows.size() == c.films().size(), "filmCatalog omits films");
        QStringList filmGroups, silverFilms;
        for (const auto& entry : filmRows) {
            const auto row = entry.toMap();
            const auto group = row.value("group").toString();
            if (filmGroups.isEmpty() || filmGroups.last() != group) filmGroups.append(group);
            const int index = row.value("index").toInt();
            check(index >= 0 && index < c.films().size() &&
                  c.films()[index].toMap().value("id") == row.value("id"), "filmCatalog index is not the films index");
            if (group == "blackAndWhite") {
                silverFilms.append(row.value("id").toString());
                check(row.value("monochrome").toBool() && row.value("targetPrint") == "ilford_multigrade_iv_rc",
                      "black-and-white film metadata");
            } else if (group == "positive") {
                check(row.value("positive").toBool() && row.value("targetPrint").toString().isEmpty(), "slide metadata");
            } else {
                check(group == "negative" && !row.value("positive").toBool() && !row.value("monochrome").toBool() &&
                      !row.value("targetPrint").toString().isEmpty(), "colour negative metadata");
            }
        }
        check(filmGroups == QStringList{"positive", "negative", "blackAndWhite"}, "film groups or their order");
        check(silverFilms == QStringList{"fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400", "kodak_tmax_100",
                                         "kodak_tri_x_400"}, "black-and-white films");
        const auto paperRow = [&](const QString& id) {
            for (const auto& entry : c.paperCatalog())
                if (entry.toMap().value("id") == id) return entry.toMap();
            throw std::runtime_error("paperCatalog lacks " + id.toStdString());
        };
        {
            const auto rows = c.paperCatalog();
            check(rows.size() == c.papers().size() + 1, "paperCatalog omits papers or No Print Profile");
            QStringList groups;
            for (const auto& entry : rows) {
                const auto group = entry.toMap().value("group").toString();
                if (groups.isEmpty() || groups.last() != group) groups.append(group);
            }
            check(groups == QStringList{"still", "cine", "positive"}, "paper groups or their order");
            const auto last = rows.last().toMap();
            check(last.value("id") == "__scan_film__" && last.value("noPrintProfile").toBool() &&
                  last.value("enabled").toBool(), "No Print Profile row");
            const auto silver = paperRow("ilford_multigrade_iv_rc");
            check(silver.value("group") == "still" && silver.value("monochrome").toBool() &&
                  !silver.value("printable").toBool() && !silver.value("enabled").toBool() &&
                  silver.value("reason") == "silverPaper", "a colour film may choose the silver paper");
            const auto own = paperRow("kodak_portra_endura");
            check(own.value("enabled").toBool() && own.value("declared").toBool() && own.value("reason") == "",
                  "the film's own paper is not offered as its own");
            check(paperRow("kodak_2383").value("cine").toBool() && paperRow("kodak_2383").value("group") == "cine",
                  "cine paper metadata");
        }

        // Paper follows film (Session.selectFilmStock), and black and white
        // prints only on the silver paper (StockCatalog.canPrint).
        check(c.selectFilm("kodak_tri_x_400") && c.filmIsMonochrome() &&
              c.parameter("print_stock") == "ilford_multigrade_iv_rc", "a black-and-white film kept a colour paper");
        refused("print_stock", QStringLiteral("kodak_supra_endura"), "colour paper for a black-and-white film");
        check(!c.selectPaper("kodak_supra_endura") && c.parameter("print_stock") == "ilford_multigrade_iv_rc",
              "selectPaper took a colour paper for a black-and-white film");
        check(paperRow("kodak_supra_endura").value("reason") == "colourPaper" &&
              paperRow("ilford_multigrade_iv_rc").value("enabled").toBool() &&
              paperRow("ilford_multigrade_iv_rc").value("declared").toBool(), "silver pairing in paperCatalog");
        check(c.selectFilm("ilford_hp5_plus_400") && c.parameter("print_stock") == "ilford_multigrade_iv_rc",
              "black-and-white to black-and-white lost the silver paper");
        check(c.selectFilm("kodak_gold_200") && !c.filmIsMonochrome() &&
              c.parameter("print_stock") == "kodak_portra_endura", "a colour film did not take its own paper back");
        refused("print_stock", QStringLiteral("ilford_multigrade_iv_rc"), "silver paper for a colour film");
        // A chosen paper, No Print Profile over it, and the film's own paper.
        check(c.selectPaper("kodak_supra_endura") && c.printSelection() == "kodak_supra_endura" && !c.noPrintProfile(),
              "paper choice");
        check(c.selectPaper("__scan_film__") && c.parameter("scan_film") == true &&
              c.parameter("print_stock") == "kodak_supra_endura" && c.printSelection() == "__scan_film__" &&
              c.noPrintProfile(), "No Print Profile did not scan, or dropped the paper");
        check(c.selectPaper("kodak_supra_endura") && c.parameter("scan_film") == false,
              "choosing the paper again did not print on it");
        c.selectPaper("__scan_film__");
        check(c.canUseFilmPaper() && c.useFilmPaper() && c.parameter("print_stock") == "kodak_portra_endura" &&
              c.parameter("scan_film") == false, "Use film's paper");
        // A slide is scanned and keeps the paper for the next negative; it has
        // no paper of its own to use.
        check(c.selectFilm("fujifilm_provia_100f") && c.noPrintProfile() && c.printSelection() == "__scan_film__" &&
              c.parameter("print_stock") == "kodak_portra_endura" && c.parameter("scan_film") == false &&
              !c.canUseFilmPaper() && !c.useFilmPaper(), "slide film's print state");
        check(paperRow("kodak_portra_endura").value("reason") == "positiveFilm" &&
              !paperRow("kodak_portra_endura").value("enabled").toBool(), "slide film's papers are not greyed");
        // macOS moves the paper even when the film is already chosen.
        check(c.selectFilm("kodak_portra_400") && c.selectPaper("kodak_supra_endura") &&
              c.selectFilm("kodak_portra_400") && c.parameter("print_stock") == "kodak_portra_endura",
              "choosing the current film again did not return to its paper");
        // The Film section's reset: Portra 400, and from black and white the
        // default paper.
        check(c.selectFilm("kodak_tri_x_400"), "choose black and white before the film reset");
        c.resetFilmStock();
        check(c.parameter("film_stock") == "kodak_portra_400" && c.parameter("print_stock") == "kodak_supra_endura",
              "film reset from black and white");

        // The AE Method pill: Custom is the meter off and keeps the intent.
        check(c.aeMethod() == "center" && c.aeMethodChoices() ==
              QStringList{"custom", "balanced", "center", "protect_highlights", "protect_shadows"}, "AE method choices");
        c.setAeMethod("protect_shadows");
        check(c.aeMethod() == "protect_shadows" && c.parameter("auto_exposure") == true &&
              c.parameter("auto_exposure_method") == "protect_shadows", "AE method intent");
        c.setAeMethod("custom");
        check(c.aeMethod() == "custom" && c.parameter("auto_exposure") == false &&
              c.parameter("auto_exposure_method") == "protect_shadows", "Custom is not the meter off");
        c.setAeMethod("balanced");
        check(c.aeMethod() == "balanced" && c.parameter("auto_exposure") == true, "AE method back on");
        check(c.setParameter("auto_exposure_method", QStringLiteral("center_weighted")) && c.aeMethod() == "legacy",
              "an engine meter the pill does not offer");
        {
            const int beforeLegacy = changes;
            c.setAeMethod("legacy");
            check(changes == beforeLegacy && c.parameter("auto_exposure_method") == "center_weighted",
                  "legacy is not a choice");
        }

        // Brightness is macOS's -3..3 stops; the Enlarger reset zeroes it,
        // both shifts and pre-flash.
        c.setExposureEv(-3);
        check(c.exposureEv() == -3 && c.parameter("print_exposure").toDouble() == 8.0, "brightness -3 stops");
        c.setExposureEv(3.01);
        check(c.exposureEv() == -3, "brightness past 3 stops");
        refused("preflash_exposure", 0.031, "pre-flash past macOS's 0.03");
        refused("dir_couplers_amount", 1.51, "couplers past macOS's 1.5");
        refused("halation_boost_ev", 8.01, "highlight boost past the wire's 8");
        check(c.setParameter("preflash_exposure", 0.03) && c.setParameter("m_filter_shift", -0.2) &&
              c.setParameter("y_filter_shift", 0.3), "enlarger edits");
        c.resetEnlarger();
        check(c.exposureEv() == 0 && c.parameter("preflash_exposure").toDouble() == 0.0 &&
              c.parameter("y_filter_shift").toDouble() == 0.0 && c.parameter("m_filter_shift").toDouble() == 0.0,
              "Enlarger reset");
        // Print Effects is a row that is not sent.
        check(c.setParameter("print_effects", false) && c.parameter("print_effects") == false, "Print Effects off");
        for (const auto& entry : c.parameterFields()) {
            const auto row = entry.toMap();
            // Product rows (Print Effects, the Date Back's order, source and
            // text, the film edge's seeded flag) shape the wire, not sent.
            check(row.value("sent").toBool() == desktop::find_setting(row.value("key").toString().toStdString())->wire &&
                  (row.value("key") != "print_effects" || !row.value("sent").toBool()), "parameterFields sent flag");
        }

        // Locked while a file dialog is open, as every other edit is.
        c.setDialogOpen(true);
        refused("grain_amount", 1.5, "edit while locked");
        c.setDialogOpen(false);
        check(c.setParameter("grain_amount", 1.5), "edit after unlock");

        // Reset is a new photograph's settings again.
        c.resetSettings();
        parameters = c.parameters();
        for (const auto& field : desktop::setting_fields())
            check(parameters.value(QString::fromStdString(field.key)) == initial(field.key.c_str()),
                  "reset left a parameter changed: " + field.key);
        check(!QFileInfo::exists(edits), "no photograph was opened, yet the edit store was written");
        std::printf("Controller settings: %d checks passed; no RAW, no edit store writes.\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "Controller settings FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
