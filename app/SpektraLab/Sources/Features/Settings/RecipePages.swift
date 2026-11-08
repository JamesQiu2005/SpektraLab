//  RecipePages.swift — how Settings' Recipes say what a recipe makes (`MacSettingsRecipes`).

import SwiftUI

/// How the recipes' pages say what a recipe makes.
enum RecipeWords {
    /// "JPEG · 12 MP · Display P3 · Photos".
    static func makes(_ r: ExportRecipe) -> String {
        [r.format.title, ExportWords.size(r.size, capped: nil), r.colour.rawValue, r.destination.shownTitle]
            .joined(separator: Fmt.dot)
    }
}
