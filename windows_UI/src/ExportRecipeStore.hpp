#pragma once
// The export page's recipes for QML: the macOS ExportRecipeStore
// (ExportRecipe.swift:714-816) over ExportRecipe.hpp. Every edit is written
// straight back to the JSON file -- there is no Apply button, a recipe is a
// saved preference (ExportPage.swift:123-130). Registered as the context
// property `exportRecipes`; the file is recipes::storePath(editDirectory).
#include "ExportRecipe.hpp"
#include <QObject>
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class ExportRecipeStore final : public QObject {
    Q_OBJECT
    // [{id, name}] in the file's order, and the chosen row.
    Q_PROPERTY(QVariantList recipes READ recipes NOTIFY changed)
    Q_PROPERTY(int selectedIndex READ selectedIndex WRITE select NOTIFY changed)
    // The chosen recipe, flattened for bindings (see recipeMap()).
    Q_PROPERTY(QVariantMap selected READ selected NOTIFY changed)
    // The recipe's JSON, as PreviewController::exportWithRecipe takes it.
    Q_PROPERTY(QVariantMap selectedJson READ selectedJson NOTIFY changed)
    Q_PROPERTY(QString problem READ problem NOTIFY changed)
    Q_PROPERTY(QString path READ path CONSTANT)
    Q_PROPERTY(QStringList formatLabels READ formatLabels CONSTANT)
    Q_PROPERTY(QStringList colorSpaceNames READ colorSpaceNames CONSTANT)
    Q_PROPERTY(QStringList existingLabels READ existingLabels CONSTANT)
public:
    explicit ExportRecipeStore(QString path, QObject* parent = nullptr);
    QVariantList recipes() const;
    int selectedIndex() const { return selected_; }
    QVariantMap selected() const;
    QVariantMap selectedJson() const;
    QString problem() const { return problem_; }
    QString path() const { return path_; }
    QStringList formatLabels() const;
    QStringList colorSpaceNames() const;
    QStringList existingLabels() const;
    const QList<spk::desktop::recipes::Recipe>& all() const { return recipes_; }
    const spk::desktop::recipes::Recipe& current() const { return recipes_[selected_]; }

    Q_INVOKABLE void select(int index);
    Q_INVOKABLE void add();
    Q_INVOKABLE void duplicate();
    Q_INVOKABLE void remove();          // refused for the last recipe
    Q_INVOKABLE void rename(const QString& name);
    Q_INVOKABLE void setFormat(int index);
    Q_INVOKABLE void setDepth(int bits);
    Q_INVOKABLE void setColorSpace(int index);
    Q_INVOKABLE void setBesideOriginal();
    Q_INVOKABLE void setFolder(const QUrl& folder);
    Q_INVOKABLE void setSubfolder(const QString& subfolder);
    Q_INVOKABLE void toggleToken(const QString& token);
    Q_INVOKABLE void moveToken(const QString& token, const QString& before);
    Q_INVOKABLE void originalNameOnly();
    Q_INVOKABLE void selectAllTokens();
    Q_INVOKABLE void resetTokenOrder();
    Q_INVOKABLE void setExisting(int index);
    Q_INVOKABLE void setQuality(double quality);
    Q_INVOKABLE void setLongEdge(int edge);   // 0: Original
    Q_INVOKABLE void setOpenWith(const QString& value);
    Q_INVOKABLE void setOpenWithApplication(const QUrl& exe);
    Q_INVOKABLE void setEmbedsPreview(bool on);
    Q_INVOKABLE void setMetadata(const QString& field, bool on);   // exif, camera, lens, exposure, date

    // The filename this recipe gives a photograph (stem + extension).
    Q_INVOKABLE QString sampleName(const QUrl& source, const QString& film, const QString& paper) const;
    // Every distinct folder the recipe writes into for these sources.
    Q_INVOKABLE QStringList destinationFolders(const QVariantList& sources) const;   // QUrls
    // Open a folder in Explorer, walking up to the nearest one that exists
    // (the subfolder is created by the export, not before).
    Q_INVOKABLE void reveal(const QString& folder) const;
    Q_INVOKABLE void revealRecipesFile() const;
    // After an export: hand the files to the recipe's Open With.
    Q_INVOKABLE void openAfterExport(const QStringList& files) const;
    // The summary lines (ExportPage.summaryLines), for Copy Summary.
    Q_INVOKABLE void copyText(const QString& text) const;

signals:
    void changed();

private:
    void edit(const std::function<void(spk::desktop::recipes::Recipe&)>& change);
    void persist();
    QString path_, problem_;
    QList<spk::desktop::recipes::Recipe> recipes_;
    int selected_ = 0;
};
