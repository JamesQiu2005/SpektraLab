//  MacSettingsRecipes.swift — Settings › Export on the Mac: the recipes, and the chosen one edited in place.
//
//  The window's *Recipes* page and its recipe pages (`RecipePages.swift`) as one section:
//  - **The list**: every saved recipe, what it makes under its name; the one Export opens with ticked at
//    its leading edge (a click on the tick chooses it, as a tap on the window's row does); a click on the
//    row shows that recipe in the group under the list.
//  - **The recipe**: its name (empty names it for what it makes), and the Export page's own choices —
//    Format, Size (Full, 12 MP, or a long or short edge typed in pixels, never under 16), Colour,
//    Quality, Save to. Each change is kept as it is made (`ExportRecipeStore.update`), and Export follows
//    it when the recipe is the one it opens with (the window page's `follow`).
//  - **New Recipe** saves what Export would open with now as a recipe of its own and shows it (the window
//    makes a draft first and saves it with *Add Recipe*; a Mac list adds the row at once). **Delete
//    Recipe…** asks first; the last recipe stays.

import SwiftUI

struct MacSettingsRecipes: View {
    @Environment(ExportRecipeStore.self) private var recipes
    @Environment(AppSettings.self) private var settings

    @State private var shown: ExportRecipe.ID?
    @State private var name = ""
    @State private var edgeText = ""
    @State private var confirmingDelete = false

    /// The saved recipe Export opens with (the window page's `ticked`).
    private var ticked: ExportRecipe? { recipes.saved(as: settings.recipe) }
    private var current: ExportRecipe? { (shown.flatMap { recipes.recipe($0) }) ?? ticked ?? recipes.recipes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            list
            if let recipe = current { editor(recipe) }
        }
        .onAppear { load(current) }
        .onChange(of: current?.id) { _, _ in load(current) }
        .confirmationDialog(L("Delete \(current?.name ?? "")?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { delete() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Frames already exported keep their files."))
        }
    }

    // MARK: the list

    private var list: some View {
        MacSettingsGroup(title: L("Recipes"),
                         footer: L("The ticked recipe is what Export opens with. Choose a recipe to change it, rename it or delete it.")) {
            ForEach(Array(recipes.recipes.enumerated()), id: \.element.id) { i, recipe in
                row(recipe, last: i == recipes.recipes.count - 1)
            }
            .macSettingsItem("Export", "Recipes", "Recipe")
        } accessory: {
            HStack(spacing: MacMetric.pt(6)) {
                Button(L("New Recipe")) { add() }
                    .buttonStyle(MacSettingsButtonStyle())
                    .macSettingsItem("New Recipe", "Add Recipe")
                Button(L("Delete Recipe")) { confirmingDelete = true }
                    .buttonStyle(MacSettingsButtonStyle(kind: .destructive))
                    .disabled(!recipes.canRemove || current == nil)
                    .macSettingsItem("Delete Recipe")
            }
        }
    }

    private func row(_ recipe: ExportRecipe, last: Bool) -> some View {
        let isTicked = recipe.id == ticked?.id
        let isShown = recipe.id == current?.id
        return HStack(spacing: MacMetric.pt(8)) {
            Button {
                settings.recipe = recipe
            } label: {
                Image(systemName: isTicked ? "largecircle.fill.circle" : "circle")
                    .font(MacMetric.font(14)).foregroundStyle(isTicked ? (isShown ? Theme.onSelection : Theme.accent) : Theme.dim)
                    .frame(width: MacMetric.pt(20), height: MacMetric.pt(20))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recipe.name)
            .accessibilityHint(L("What Export opens with"))
            .accessibilityAddTraits(isTicked ? .isSelected : [])
            HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(8)) {
                Text(recipe.name).font(MacMetric.font(13, .medium)).foregroundStyle(isShown ? Theme.onSelection : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: MacMetric.pt(8))
                Text(RecipeWords.makes(recipe)).font(MacMetric.font(11)).foregroundStyle(isShown ? Theme.onSelection.opacity(0.7) : Theme.dim)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .onTapGesture { shown = recipe.id }
        }
        .padding(.horizontal, MacMetric.pt(8))
        .frame(minHeight: MacMetric.pt(26))
        .background {
            if isShown { RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous).fill(Theme.selection) }
        }
        .padding(.horizontal, MacMetric.pt(4))
        .padding(.vertical, MacMetric.pt(1))
        .accessibilityIdentifier("mac.settings.recipe")
    }

    // MARK: the recipe

    private func editor(_ recipe: ExportRecipe) -> some View {
        let draft = Binding<ExportRecipe>(get: { recipes.recipe(recipe.id) ?? recipe }, set: { change(recipe.id, $0) })
        return MacSettingsGroup(title: recipe.name, footer: recipes.problem, capitals: false) {
            MacSettingsRow(label: L("Name"), caption: L("Left empty, the recipe is named for what it makes.")) {
                MacSettingsField(placeholder: recipe.builtName, text: $name, width: 220) { commitName(recipe.id) }
                    .accessibilityLabel(L("Recipe name"))
            }
            .macSettingsItem("Name")
            MacSettingsRow(label: L("Format")) {
                MacSettingsPopUp(label: L("Format"), options: ExportRecipe.Format.allCases.map { ($0, $0.title) },
                                 selection: draft.format)
            }
            .macSettingsItem("File", "Format")
            MacSettingsRow(label: L("Size")) { size(draft) }
                .macSettingsItem("Size")
            MacSettingsRow(label: L("Colour")) {
                MacSettingsPopUp(label: L("Colour"), options: ExportRecipe.Colour.allCases.map { ($0, $0.fullName) },
                                 selection: draft.colour)
            }
            .macSettingsItem("Colour")
            MacSettingsRow(label: L("Quality"), caption: draft.wrappedValue.mayBand ? L("In 8 bits ProPhoto can band in smooth tones") : nil) {
                if draft.wrappedValue.format.takesQuality {
                    MacSettingsPopUp(label: L("Quality"), options: Self.qualities.map { ($0, "\($0)") }, selection: draft.quality,
                                     other: "\(draft.wrappedValue.quality)")
                } else {
                    Text(L("\(draft.wrappedValue.format.bitDepth)-bit, lossless")).font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
            }
            .macSettingsItem("Quality")
            MacSettingsRow(label: L("Save to"), last: true) {
                MacSettingsPopUp(label: L("Save to"), options: ExportRecipe.Destination.allCases.map { ($0, $0.shownTitle) },
                                 selection: draft.destination)
            }
            .macSettingsItem("Save to")
        }
    }

    /// The Export sheet's Quality steps (`QualityRow`).
    static let qualities = [100, 95, 90, 85, 80, 75]

    private enum SizeKind: Hashable { case full, twelve, long, short }

    /// Full, 12 MP, or an edge typed in pixels (`ExportSizePage`'s four).
    private func size(_ draft: Binding<ExportRecipe>) -> some View {
        let r = draft.wrappedValue
        let kind: SizeKind = switch r.size {
        case .full, .preview: .full
        case .megapixels: .twelve
        case .longEdge: .long
        case .shortEdge: .short
        }
        let options: [(SizeKind, String)] = [(.full, L("Full size")), (.twelve, "\(Int(ExportRecipe.twelveMegapixels)) MP"),
                                             (.long, L("Long edge")), (.short, L("Short edge"))]
        return HStack(spacing: MacMetric.pt(6)) {
            if kind == .long || kind == .short {
                MacSettingsField(placeholder: "\(edge(of: r.size))", text: $edgeText, width: 64) { commitEdge(draft) }
                    .accessibilityLabel(kind == .long ? L("Long edge") : L("Short edge"))
                Text("px").font(MacMetric.font(12)).foregroundStyle(Theme.dim)
            }
            MacSettingsPopUp(label: L("Size"), options: options,
                             selection: Binding(get: { kind }, set: { new in
                                 let e = edge(of: r.size)
                                 switch new {
                                 case .full: draft.wrappedValue.size = .full
                                 case .twelve: draft.wrappedValue.size = .megapixels(ExportRecipe.twelveMegapixels)
                                 case .long: draft.wrappedValue.size = .longEdge(e)
                                 case .short: draft.wrappedValue.size = .shortEdge(e)
                                 }
                                 edgeText = ""
                             }))
        }
    }

    /// The edge a size names, or the one an edge starts at (`ExportSizePage`'s 2,048).
    private func edge(of size: ExportRecipe.Size) -> Int {
        switch size {
        case .longEdge(let e), .shortEdge(let e): e
        default: 2048
        }
    }

    private func commitEdge(_ draft: Binding<ExportRecipe>) {
        defer { edgeText = "" }
        guard let n = Int(edgeText.filter(\.isNumber)) else { return }
        let e = max(n, ExportSizePage.smallestEdge)
        switch draft.wrappedValue.size {
        case .longEdge: draft.wrappedValue.size = .longEdge(e)
        case .shortEdge: draft.wrappedValue.size = .shortEdge(e)
        default: break
        }
    }

    // MARK: changing (the window page's own calls)

    private func load(_ recipe: ExportRecipe?) {
        name = recipe?.title ?? ""
        edgeText = ""
    }

    private func change(_ id: ExportRecipe.ID, _ now: ExportRecipe) {
        recipes.update(id, with: now)
        follow(id)
    }

    private func commitName(_ id: ExportRecipe.ID) {
        guard let saved = recipes.recipe(id), ExportRecipe.cleanTitle(name) != saved.title else { return }
        recipes.rename(id, to: name)
        name = recipes.recipe(id)?.title ?? ""
        follow(id)
    }

    /// Export opens with this recipe: it opens with it as it is now.
    private func follow(_ id: ExportRecipe.ID) {
        guard settings.recipe.id == id, let now = recipes.recipe(id), now != settings.recipe else { return }
        settings.recipe = now
    }

    private func add() {
        var draft = settings.recipe
        draft.title = nil
        if draft.size == .preview { draft.size = ExportRecipe().size }
        let made = recipes.add(draft, named: "")
        shown = made.id
    }

    private func delete() {
        guard let id = current?.id, recipes.remove(id) else { return }
        if settings.recipe.id == id, let first = recipes.recipes.first { settings.recipe = first }
        shown = nil
    }
}
