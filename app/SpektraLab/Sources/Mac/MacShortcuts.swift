// MacShortcuts.swift — Capture One's shipped default keys, with the approved Mac conflicts resolved.
// The binding list owns keys; pages own actions. Both the responder chain and UIMenuBuilder read the
// same registrations. A registration belongs to a view, so an outgoing page cannot unregister its
// replacement's key. Plain and shift-only commands use the same path as command-modified commands.
import SwiftUI
import UIKit

enum MacShortcut: String, CaseIterable {
    case browser, column, grid, crop, lightTable, compare, copy, copyChoosing, paste, reset, export
    case selectAll, selectNone, invert, previous, next, first, last, filters
    case libraryTab, filtersTab, infoTab, fit, actualSize, zoomIn, zoomOut, fullScreen
    case tableDrag, tableClick, tableLoupe, tableFit, tableActual, tableZoomIn, tableZoomOut
    case tableRight, tableLeft
    case red, yellow, green

    var bindings: [MacKeySpec] {
        func k(_ input: String, _ flags: UIKeyModifierFlags = []) -> MacKeySpec { MacKeySpec(input: input, flags: flags) }
        switch self {
        case .red: return [k("-")]
        case .yellow: return [k("*")]
        case .green: return [k("+")]
        case .browser: return [k("b", .command), k("b", [.command, .alternate])]
        case .column: return [k("t", .command), k("s", [.command, .control])]
        case .grid: return [k("g")]
        case .crop: return [k("c")]
        case .lightTable: return [k("p")]
        case .compare: return [k("y")]
        // ⌘C and ⌘V are the clipboard's (the owner, 2026-11-05: "cmd + c would enter the current copy
        // settings clipboard, and cmd + v would paste the settings"); ⇧⌘C, which was Copy Settings, now
        // opens the Copy Settings sheet to choose the groups first (in Capture One ⇧⌘C copies at once and
        // its Adjustments Clipboard tool chooses the groups; this app's sheet is that choice), and ⇧⌘V
        // stays Paste's alias.
        case .copy: return [k("c", .command)]
        case .copyChoosing: return [k("c", [.command, .shift])]
        case .paste: return [k("v", .command), k("v", [.command, .shift])]
        case .reset: return [k("r", .command)]
        case .export: return [k("d", [.command, .shift])]
        case .selectAll: return [k("a", .command)]
        case .selectNone: return [k("a", [.command, .shift])]
        case .invert: return [k("i", .command)]
        case .previous: return [k(UIKeyCommand.inputLeftArrow, .command)]
        case .next: return [k(UIKeyCommand.inputRightArrow, .command)]
        case .first: return [k(UIKeyCommand.inputHome, .command)]
        case .last: return [k(UIKeyCommand.inputEnd, .command)]
        case .filters: return [k("f", [.command, .shift])]
        case .libraryTab: return [k("1", [.command, .alternate]), k("1", .command)]
        case .filtersTab: return [k("2", [.command, .alternate]), k("2", .command)]
        case .infoTab: return [k("3", [.command, .alternate]), k("3", .command)]
        case .fit: return [k(",")]
        case .actualSize: return [k(".")]
        case .zoomIn: return [k("+", .command), k("=", .command)]
        case .zoomOut: return [k("-", .command)]
        case .fullScreen: return [k("f")]
        case .tableDrag: return [k("h"), k("d")]
        case .tableClick: return [k("v"), k("c")]
        case .tableLoupe: return [k("p"), k("l")]
        case .tableFit: return [k(","), k("0")]
        case .tableActual: return [k("."), k("1")]
        case .tableZoomIn: return [k("+", .command), k("=", .command), k("="), k("+")]
        case .tableZoomOut: return [k("-", .command), k("-")]
        case .tableRight: return [k("r", [.command, .alternate]), k("r")]
        case .tableLeft: return [k("l", [.command, .alternate]), k("r", .shift)]
        }
    }

    var title: String {
        switch self {
        case .red: L("Red")
        case .yellow: L("Yellow")
        case .green: L("Green")
        case .browser: L("Browser")
        case .column: L("Sidebar")
        case .grid: L("Grid")
        case .crop: L("Crop")
        case .lightTable: L("Light Table")
        case .compare: L("Compare")
        case .copy: L("Copy Settings")
        case .copyChoosing: L("Copy Settings…")
        case .paste: L("Paste Settings")
        case .reset: L("Reset")
        case .export: L("Export")
        case .selectAll: L("Select All")
        case .selectNone: L("Select None")
        case .invert: L("Invert Selection")
        case .previous: L("Previous photo")
        case .next: L("Next photo")
        case .first: L("First Image")
        case .last: L("Last Image")
        case .filters, .filtersTab: L("Filters")
        case .libraryTab: L("Library")
        case .infoTab: L("Info")
        case .fit, .tableFit: L("Fit")
        case .actualSize, .tableActual: L("Actual Size")
        case .zoomIn, .tableZoomIn: L("Zoom In")
        case .zoomOut, .tableZoomOut: L("Zoom Out")
        case .fullScreen: L("Full Screen")
        case .tableDrag: L("Drag")
        case .tableClick: L("Click")
        case .tableLoupe: L("Loupe")
        case .tableRight: L("Rotate Right")
        case .tableLeft: L("Rotate Left")
        }
    }

    // The scene owns Import; ⌘I now belongs to Invert Selection.
    static let importKey: KeyEquivalent = "i"
    static let importModifiers: EventModifiers = [.command, .shift]
}

struct MacShortcutButton: View {
    let shortcut: MacShortcut
    var enabled = true
    let action: () -> Void
    init(_ shortcut: MacShortcut, enabled: Bool = true, action: @escaping () -> Void) {
        self.shortcut = shortcut; self.enabled = enabled; self.action = action
    }
    var body: some View {
        MacKeyRegistration(specs: shortcut.bindings, title: shortcut.title, enabled: enabled, action: action)
            .frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Includes every modifier, not just Shift: ⌘← and ← are different commands.
struct MacKeySpec: Hashable {
    let input: String
    let flags: UIKeyModifierFlags
    init(input: String, flags: UIKeyModifierFlags = []) { self.input = input; self.flags = flags }
    init(_ key: KeyEquivalent, modifiers: EventModifiers) {
        switch key {
        case .upArrow: input = UIKeyCommand.inputUpArrow
        case .downArrow: input = UIKeyCommand.inputDownArrow
        case .leftArrow: input = UIKeyCommand.inputLeftArrow
        case .rightArrow: input = UIKeyCommand.inputRightArrow
        case .delete: input = UIKeyCommand.inputDelete
        case .escape: input = UIKeyCommand.inputEscape
        default: input = String(key.character)
        }
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        self.flags = flags
    }
    init?(_ command: UIKeyCommand) {
        guard let input = command.input else { return nil }
        self.input = input
        flags = command.modifierFlags.intersection([.command, .alternate, .control, .shift])
    }
    func hash(into h: inout Hasher) { h.combine(input); h.combine(flags.rawValue) }

    /// The keys the Edit menu owns — Select All, Copy, Paste — and the selector it stands for on each.
    /// A registration on one of them goes by that selector, never as a second menu item on the same key:
    /// the Edit menu's item takes the key first, and gives it to the registration only when no field has
    /// the keys (`MacEditCommands.edit`); a field being edited has its own copy: and paste: as before.
    static let standard: [MacKeySpec: Selector] = [
        MacKeySpec(input: "a", flags: .command): #selector(UIResponder.selectAll(_:)),
        MacKeySpec(input: "c", flags: .command): #selector(UIResponder.copy(_:)),
        MacKeySpec(input: "v", flags: .command): #selector(UIResponder.paste(_:)),
    ]
    /// The spec a standard edit action stands for (`MacKeyAnchor.copy(_:)`'s way into the registry).
    static func standard(for action: Selector) -> MacKeySpec? { standard.first { $0.value == action }?.key }
}

@MainActor
final class MacShortcutRegistry {
    static let shared = MacShortcutRegistry()
    struct Entry {
        var specs: [MacKeySpec]
        var title: String
        var enabled: Bool
        var action: () -> Void
        var allowsDuringTextEditing = false
    }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var pendingRebuild = false

    func register(_ owner: UUID, entry: Entry) {
        let previous = entries[owner]
        if previous == nil { order.append(owner) }
        entries[owner] = entry
        #if DEBUG
        if previous == nil, CommandLine.arguments.contains("--key-trace") {
            NSLog("[key-registry] registered %@ enabled %d count %d", entry.title, entry.enabled, entries.count)
        }
        #endif
        if previous?.specs != entry.specs || previous?.title != entry.title || previous?.enabled != entry.enabled { rebuild() }
    }
    func unregister(_ owner: UUID) {
        entries[owner] = nil
        order.removeAll { $0 == owner }
        rebuild()
    }
    private func rebuild() {
        guard !pendingRebuild else { return }
        pendingRebuild = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingRebuild = false
            UIMenuSystem.main.setNeedsRebuild()
        }
    }
    private func entry(for spec: MacKeySpec) -> Entry? {
        order.reversed().compactMap { entries[$0] }.first { $0.enabled && $0.specs.contains(spec) }
    }
    var typing: Bool { MacKeyFocus.commitEditing != nil || MacKeyFocus.editingField != nil || MacLibraryBrowser.shared.typing }
    func canPerform(_ command: UIKeyCommand) -> Bool {
        guard let spec = MacKeySpec(command), let entry = entry(for: spec) else { return false }
        if typing, ["\r", "\u{3}"].contains(spec.input), MacKeyFocus.editingField is UITextView { return false }
        return !typing || entry.allowsDuringTextEditing
    }
    /// An Edit-menu action (`MacKeySpec.standard`) — its key or its menu item — as the registration on
    /// that key: what the Edit menu (`MacEditCommands`) and the window's anchor ask for copy:, paste: and
    /// selectAll:. False while a field has the keys, which keeps its own.
    func canPerformStandard(_ action: Selector) -> Bool {
        guard let spec = MacKeySpec.standard(for: action) else { return false }
        return canPerform(UIKeyCommand(title: "", action: action, input: spec.input, modifierFlags: spec.flags))
    }
    func performStandard(_ action: Selector) {
        guard let spec = MacKeySpec.standard(for: action) else { return }
        perform(UIKeyCommand(title: "", action: action, input: spec.input, modifierFlags: spec.flags))
    }
    func perform(_ command: UIKeyCommand) {
        guard let spec = MacKeySpec(command), let entry = entry(for: spec), !typing || entry.allowsDuringTextEditing else { return }
        #if DEBUG
        NSLog("[shortcut] %@ · input %@ · modifiers %lu", entry.title, spec.input, spec.flags.rawValue)
        #endif
        if entry.allowsDuringTextEditing {
            MacKeyFocus.endEditing()
            DispatchQueue.main.async { entry.action() }
        } else { entry.action() }
    }
    private func command(_ spec: MacKeySpec, title: String) -> UIKeyCommand {
        // UIMenuBuilder identifies commands by selector + propertyList, not by input. Reusing a
        // selector with nil propertyList makes every item a duplicate and rejects the entire menu.
        let standard = MacKeySpec.standard[spec]
        let command = UIKeyCommand(title: title, image: nil, action: standard ?? #selector(AppDelegate.spkShortcut(_:)),
                                   input: spec.input, modifierFlags: spec.flags,
                                   propertyList: standard != nil ? nil : spec.input + ":" + String(spec.flags.rawValue), alternates: [],
                                   discoverabilityTitle: title, attributes: [], state: .off)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
    var keyCommands: [UIKeyCommand] {
        var seen: Set<MacKeySpec> = []
        return order.reversed().compactMap { entries[$0] }.filter { $0.enabled && (!typing || $0.allowsDuringTextEditing) }.flatMap { entry in
            entry.specs.filter { seen.insert($0).inserted }.map { command($0, title: entry.title) }
        }
    }
    func buildMenu(_ builder: UIMenuBuilder) {
        // Canonical key per registration; aliases remain reachable through the same responder commands.
        // Edit already owns Select All, Copy and Paste: their standard selectors reach the anchor or the
        // focused field, so a registration shows its first key Edit does not own (Paste Settings: ⇧⌘V),
        // or none (Select All, Copy Settings' ⌘C).
        var seen: Set<MacKeySpec> = []
        let items = order.reversed().compactMap { entries[$0] }.compactMap { entry -> UIKeyCommand? in
            guard let key = entry.specs.first(where: { MacKeySpec.standard[$0] == nil }), seen.insert(key).inserted else { return nil }
            let c = command(key, title: entry.title)
            if !entry.enabled { c.attributes = .disabled }
            return c
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        builder.remove(menu: UIMenu.Identifier("com.spektralab.shortcuts"))
        builder.insertSibling(UIMenu(title: L("Keyboard Shortcuts"), identifier: UIMenu.Identifier("com.spektralab.shortcuts"),
                                     children: items), afterMenu: builder.menu(for: .view) == nil ? .edit : .view)
    }
}

/// A mounted view owns one registration for all of its aliases, and updates actions with the page's state.
struct MacKeyRegistration: UIViewRepresentable {
    var specs: [MacKeySpec]
    var title: String
    var enabled: Bool
    var action: () -> Void
    var allowsDuringTextEditing = false
    final class Token: UIView {
        let owner = UUID()
        var entry: MacShortcutRegistry.Entry?
        func update(_ entry: MacShortcutRegistry.Entry) {
            self.entry = entry
            if window != nil { MacShortcutRegistry.shared.register(owner, entry: entry) }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let entry { MacShortcutRegistry.shared.register(owner, entry: entry) }
            else { MacShortcutRegistry.shared.unregister(owner) }
        }
    }
    func makeUIView(context: Context) -> Token { Token(frame: .zero) }
    func updateUIView(_ view: Token, context: Context) {
        view.update(.init(specs: specs, title: title, enabled: enabled, action: action, allowsDuringTextEditing: allowsDuringTextEditing))
    }
    static func dismantleUIView(_ view: Token, coordinator: ()) { MacShortcutRegistry.shared.unregister(view.owner) }
}
