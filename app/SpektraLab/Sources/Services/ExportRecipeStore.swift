//  ExportRecipeStore.swift — the saved export recipes, in a file of their own.
//
//  The desktop's `ExportRecipeStore` (`Export/ExportRecipe.swift` there, the
//  maintainer's), on the host: a JSON file beside the library's,
//  `export-recipes.json`, written whole and atomically at every change and
//  read once at launch. **Never fatal**: a file that cannot be read leaves the
//  built-in recipes in place and says so (`problem`); the file itself is not
//  touched until the user saves a recipe again, and is copied aside at the
//  read (`KeptFileAside`), so that save does not take the only copy.
//
//  What it keeps is the list. Which recipe Export opens with is the app's own
//  preference (`AppSettings.recipe`: the last one exported with), not part of
//  the list.
//
//  No UIKit and no engine: `tools/selftest.sh` holds it on the Mac.

import Foundation
import Observation

@MainActor
@Observable
final class ExportRecipeStore {
    /// The recipes, in the order their chips are shown: the app's own first,
    /// then the user's as they were saved.
    private(set) var recipes: [ExportRecipe]
    /// Why the file could not be read or written, for a page to say; nil when
    /// all is well.
    private(set) var problem: String?

    @ObservationIgnored private let url: URL?

    static let fileName = "export-recipes.json"

    /// `url` nil keeps nothing: the snapshot harness, a test. `defaults` holds the
    /// once-only moves of a kept list (the app's own; nil for a test).
    init(url: URL?, defaults: UserDefaults? = nil) {
        self.url = url
        let loaded = Self.load(from: url)
        recipes = loaded.recipes
        problem = loaded.problem
        if let defaults, loaded.problem == nil { moveToFull(defaults) }
    }

    /// The app's own recipes, kept at the 12 MP every recipe began at, to Full —
    /// once, so a built-in the user set to 12 MP afterwards keeps it
    /// (`ExportRecipe.movedToFullKey`). The user's own named recipes are theirs.
    private func moveToFull(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: ExportRecipe.movedToFullKey) else { return }
        defaults.set(true, forKey: ExportRecipe.movedToFullKey)
        let own = Set(ExportRecipe.builtIn.map(\.id))
        var moved = false
        for i in recipes.indices where own.contains(recipes[i].id) && recipes[i].size == ExportRecipe.formerDefaultSize {
            recipes[i].size = .full
            moved = true
        }
        if moved { save() }
    }

    private static func load(from url: URL?) -> (recipes: [ExportRecipe], problem: String?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return (ExportRecipe.builtIn, nil) }
        do {
            var seen = Set<ExportRecipe.ID>()
            let read = try JSONDecoder().decode([ExportRecipe].self, from: Data(contentsOf: url)).compactMap { r -> ExportRecipe? in
                // One chip an id; and the preview size is a frame's state, never a recipe's.
                guard seen.insert(r.id).inserted else { return nil }
                var r = r
                if r.size == .preview { r.size = ExportRecipe().size }
                return r
            }
            // A file that says "no recipes" leaves a sheet with nothing to choose.
            return (read.isEmpty ? ExportRecipe.builtIn : read, nil)
        } catch {
            // Copied aside as well (`KeptFileAside`): the next recipe saved writes the list over the file.
            KeptFileAside.setAside(url, error: error)
            return (ExportRecipe.builtIn, L("The saved recipes could not be read, so the app's own are shown. The file has not been changed."))
        }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipes).write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = L("The recipes could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: reading

    func recipe(_ id: ExportRecipe.ID) -> ExportRecipe? { recipes.first { $0.id == id } }

    /// The saved recipe that makes exactly what `settings` makes, if one does:
    /// the chip a sheet lights for the settings it shows.
    func saved(as settings: ExportRecipe) -> ExportRecipe? {
        recipe(settings.id).flatMap { $0.sameSettings(as: settings) ? $0 : nil } ?? recipes.first { $0.sameSettings(as: settings) }
    }

    /// Whether a recipe may be removed: never the last one.
    var canRemove: Bool { recipes.count > 1 }

    // MARK: changing

    /// Save `settings` as a new recipe under `title`, at the end of the list.
    /// A name already taken gets a number after it; an empty one leaves the
    /// recipe named for what it makes.
    @discardableResult
    func add(_ settings: ExportRecipe, named title: String) -> ExportRecipe {
        var recipe = settings
        recipe.id = UUID()
        recipe.title = ExportRecipe.cleanTitle(title).map(freeTitle)
        if recipe.size == .preview { recipe.size = ExportRecipe().size }
        recipes.append(recipe)
        save()
        return recipe
    }

    /// Put `settings` in place of what a recipe makes. Its name and its place
    /// in the list stay.
    func update(_ id: ExportRecipe.ID, with settings: ExportRecipe) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        var recipe = settings
        recipe.id = id
        recipe.title = recipes[i].title
        if recipe.size == .preview { recipe.size = recipes[i].size }
        guard recipe != recipes[i] else { return }
        recipes[i] = recipe
        save()
    }

    /// An empty name gives the recipe back the name of what it makes.
    func rename(_ id: ExportRecipe.ID, to title: String) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        let clean = ExportRecipe.cleanTitle(title)
        let next = clean == recipes[i].title ? clean : clean.map { freeTitle($0, besides: id) }
        guard next != recipes[i].title else { return }
        recipes[i].title = next
        save()
    }

    /// Remove a recipe. Refused for the last one: a sheet with no recipe has
    /// nothing to offer and no way back.
    @discardableResult
    func remove(_ id: ExportRecipe.ID) -> Bool {
        guard canRemove, let i = recipes.firstIndex(where: { $0.id == id }) else { return false }
        recipes.remove(at: i)
        save()
        return true
    }

    /// `title`, or `title 2`, `title 3`… where another recipe already has it.
    private func freeTitle(_ title: String) -> String { freeTitle(title, besides: nil) }

    private func freeTitle(_ title: String, besides id: ExportRecipe.ID?) -> String {
        let taken = Set(recipes.filter { $0.id != id }.map(\.name))
        guard taken.contains(title) else { return title }
        for n in 2...999 {
            let suffix = " \(n)"
            let next = String(title.prefix(ExportRecipe.longestTitle - suffix.count)) + suffix
            if !taken.contains(next) { return next }
        }
        return title
    }
}
