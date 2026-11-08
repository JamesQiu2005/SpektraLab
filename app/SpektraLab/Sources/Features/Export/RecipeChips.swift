//  RecipeChips.swift — the saved export recipes, as the Export sheet's row of chips.
//
//  E1's *Recipe* row (`export_sheet`), which was three chips drawn into the
//  sheet. They are the saved recipes now (`ExportRecipeStore`), and the row is
//  where a recipe is made and kept (the owner, 2026-10-08: "an actual create
//  export recipe feature must exist"):
//
//  - **a chip** puts everything its recipe names into the sheet — container,
//    colour space, size, quality, where it goes — and is lit for as long as
//    the sheet is working from it;
//  - **New**, the row's last chip, saves what the sheet shows under a name;
//  - **a long press on a chip** renames it, saves the sheet's settings into
//    it when they have moved from what it holds, or deletes it. The last
//    recipe cannot be deleted.
//
//  **No recipe has a page of its own**: the sheet's own rows are the recipe's
//  settings, so making one is setting the sheet and giving it a name. Nothing
//  of this is in the drawings — E1 was drawn before recipes could be saved —
//  and it is built from the drawing's own parts: the chip, the row, the
//  system's menu and its alert.
//
//  The row's look began as `ChipCarousel`'s (a chip partly off the page keeps
//  its capsule and shows no words), written out here because that row's chips
//  have nothing to press and hold. Since 2026-10-12 such a chip shows the
//  words of its name that are whole on the page (`chip`): its bare capsule
//  read as a recipe with no name.
//
//  **On a window the row wraps** (`wraps`, 2026-10-21, the owner: "the word and
//  pill snapping and not displaying issue, on window"). The host's row is drawn
//  for a 393 pt sheet whose third chip starts at its edge; on a window's sheet
//  every recipe could be seen, yet the row still cut its last chips at the
//  sheet's edge — a capsule with only its lock, or with only the words that
//  were whole — and every tap scrolled the row to centre the chip, so words
//  came and went as they crossed the edge. Wrapped (`ChipFlow`), every chip is
//  on the page whole, with every word, and nothing scrolls; each chip keeps the
//  width of its name in the lit chip's weight, so lighting one moves no other.

import SwiftUI

struct RecipeChips: View {
    /// The settings the sheet shows. A chip writes them; New and "Save
    /// changes" read them.
    @Binding var recipe: ExportRecipe
    /// What a recipe's settings become before the sheet takes them (`ExportSheet.opening`).
    var admit: (ExportRecipe) -> ExportRecipe = { $0 }
    /// The chips in lines, wrapped at the row's width, in place of the host's
    /// scrolled row: a window's sheet (`ExportSheet`).
    var wraps = false

    @Environment(ExportRecipeStore.self) private var store
    @State private var naming: Naming?
    @State private var name = ""

    /// What the name alert is for.
    private enum Naming: Equatable {
        case new
        case rename(ExportRecipe.ID)
    }

    var body: some View {
        Group {
            if wraps { wrapped } else { scrolled }
        }
        .alert(naming == .new ? L("New Recipe") : L("Rename Recipe"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(recipe.builtName, text: $name)
                .textInputAutocapitalization(.words)
            Button(L("Cancel"), role: .cancel) { naming = nil }
            Button(L("Save")) { commit() }
        } message: {
            Text(naming == .new ? L("Saves the settings on this sheet under a name. Leave it empty to name the recipe for what it makes.")
                                : L("Leave it empty to name the recipe for what it makes."))
        }
    }

    /// The window's row: every chip whole, in as many lines as it takes.
    private var wrapped: some View {
        ChipFlow(spacing: 8, lineSpacing: 8) {
            ForEach(store.recipes) { saved in
                wholeChip(saved.name, on: saved.id == recipe.id) {
                    withAnimation(.easeOut(duration: 0.15)) { recipe = admit(saved) }
                }
                .contextMenu { menu(saved) }
            }
            wholeChip(L("＋ New"), on: false) {
                name = ""
                naming = .new
            }
            .accessibilityLabel(L("New recipe"))
            .accessibilityHint(L("Saves these settings under a name"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metric.margin)
    }

    /// The host's row, scrolled sideways.
    private var scrolled: some View {
        ScrollViewReader { row in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.recipes) { saved in
                        chip(saved.name, on: saved.id == recipe.id) {
                            withAnimation(.easeOut(duration: 0.15)) { recipe = admit(saved) }
                        }
                        .contextMenu { menu(saved) }
                    }
                    chip(L("＋ New"), on: false) {
                        name = ""
                        naming = .new
                    }
                    .accessibilityLabel(L("New recipe"))
                    .accessibilityHint(L("Saves these settings under a name"))
                }
            }
            .contentMargins(.horizontal, Theme.Metric.margin, for: .scrollContent)
            .frame(height: 30)
            // The chip in hand is on the page whole, with its words: a recipe saved
            // just now is the row's last but one, and the one a sheet opens with may
            // lie past the row's edge.
            .onAppear { row.scrollTo(recipe.id, anchor: .center) }
            .onChange(of: recipe.id) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { row.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// One chip of the row, as the drawing draws the row's: its capsule kept
    /// while it is partly off the page — and of its name, **the words that
    /// are whole on the page** (`ExportRecipe.words`).
    ///
    /// Until 2026-10-12 a chip partly off the page showed no words at all,
    /// which is how the drawing has it (`export_sheet`: "show the swatch of the
    /// next chip, never a cut word"). On every reference device the third recipe starts
    /// there, and a tester of the beta took its bare capsule for a recipe with
    /// no name ("recipe名字空了"). The rule is kept — no word is ever cut — and
    /// the capsule says what it is: "TIFF 16-bit", with the rest a swipe away.
    ///
    /// Each word is its own text, shown while it is whole inside the row and
    /// `clear` of its edge; `Chip` is written out here for that, with its look
    /// (12.5 pt, 12 of padding, 30 high). **The name written whole is still
    /// the chip's measure**, unseen, and the words are drawn over it from its
    /// leading edge: texts laid out one by one come to a point more than the
    /// name does, which would have moved every chip after the first.
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        let font = Theme.Font.ui(12.5, on ? .semibold : .medium)
        let clear = Self.clear
        return Button(action: action) {
          HStack(spacing: 5) {
            Text(title)
                .font(font)
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(ExportRecipe.words(of: title).enumerated()), id: \.offset) { _, word in
                            Text(Self.keepingItsSpace(word))
                                .font(font)
                                .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                                .lineLimit(1)
                                .fixedSize()
                                .visualEffect { text, proxy in
                                    let frame = proxy.frame(in: .scrollView(axis: .horizontal))
                                    let row = proxy.bounds(of: .scrollView(axis: .horizontal))?.width ?? .infinity
                                    return text.opacity(frame.minX >= clear - 0.5 && frame.maxX <= row - clear + 0.5 ? 1 : 0)
                                }
                        }
                    }
                    .fixedSize()
                }
          }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(on ? Theme.selection : Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .fixedSize()
    }

    /// One chip of the window's wrapped row: the chip's look, its name written
    /// whole. Its width is its name's in the lit weight whether it is lit or
    /// not, so a tap changes no chip's width and no line breaks anew.
    private func wholeChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Theme.Font.ui(12.5, .semibold))
                    .lineLimit(1)
                    .hidden()
                    .overlay {
                        Text(title)
                            .font(Theme.Font.ui(12.5, on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(on ? Theme.selection : Theme.card))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .fixedSize()
    }

    /// How far inside the row's edge a word ends to be shown: the drawing's own
    /// measure of a chip that fits (`W - 8`). A chip whole on the page has its
    /// words 12 inside its own edge, so all of them.
    private static let clear: CGFloat = 8

    /// A word with the space after it as one a text keeps at its end: the
    /// words stand as far apart as they do in the name written whole.
    private static func keepingItsSpace(_ word: String) -> String {
        let kept = word.reversed().prefix { $0 == " " }.count
        return kept == 0 ? word : String(word.dropLast(kept)) + String(repeating: "\u{00A0}", count: kept)
    }

    @ViewBuilder private func menu(_ saved: ExportRecipe) -> some View {
        // Only for the recipe the sheet is working from, and only when the sheet has moved from it.
        if saved.id == recipe.id, !saved.sameSettings(as: recipe) {
            Button(L("Save Changes")) {
                store.update(saved.id, with: recipe)
                if let kept = store.recipe(saved.id) { recipe = kept }
            }
        }
        Button(L("Rename…")) {
            name = saved.title ?? ""
            naming = .rename(saved.id)
        }
        Button(L("Delete"), role: .destructive) {
            guard store.remove(saved.id) else { return }
            // The sheet keeps its settings; they are no longer any recipe's.
            if recipe.id == saved.id {
                recipe.id = UUID()
                recipe.title = nil
            }
        }
        .disabled(!store.canRemove)
    }

    private func commit() {
        switch naming {
        case .new:
            recipe = store.add(recipe, named: name)
        case .rename(let id):
            store.rename(id, to: name)
            if recipe.id == id, let kept = store.recipe(id) { recipe.title = kept.title }
        case nil:
            break
        }
        naming = nil
    }
}
