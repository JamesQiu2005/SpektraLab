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
