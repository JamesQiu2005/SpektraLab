import SwiftUI
import UIKit

// Compile the production registry with minimal page/focus stand-ins; this exercises ownership,
// modifier identity and dispatch guards, independently of the live responder-chain gate.
func L(_ text: String) -> String { text }
@MainActor enum MacKeyFocus {
    static var editingField: UIView? { nil }
    static var commitEditing: (() -> Void)?
    static func endEditing() { MacLibraryBrowser.shared.typing = false }
}
@MainActor final class MacLibraryBrowser {
    static let shared = MacLibraryBrowser()
    var typing = false
}
@MainActor final class AppDelegate: UIResponder {
    @objc func spkShortcut(_ command: UIKeyCommand) {}
}

@main struct ShortcutSelftest {
    @MainActor static func main() async {
        let registry = MacShortcutRegistry()
        var failures: [String] = []
        var hits: [String] = []
        func expect(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        func command(_ input: String, _ flags: UIKeyModifierFlags = []) -> UIKeyCommand {
            UIKeyCommand(title: "Check", action: #selector(AppDelegate.spkShortcut(_:)), input: input, modifierFlags: flags)
        }
        let oldPage = UUID(), newPage = UUID()
        let zero = MacKeySpec(input: "0")
        registry.register(oldPage, entry: .init(specs: [zero], title: "Rating", enabled: true, action: { hits.append("rating") }))
        registry.register(newPage, entry: .init(specs: [zero], title: "Fit", enabled: true, action: { hits.append("fit") }))
        registry.unregister(oldPage)
        registry.perform(command("0"))
        expect(hits == ["fit"], "outgoing page cannot unregister replacement's 0 key")
        registry.unregister(newPage)
        expect(!registry.canPerform(command("0")), "removed page leaves no stale 0 command")
        let rating = UUID(), fit = UUID()
        registry.register(rating, entry: .init(specs: [zero], title: "Rating", enabled: false, action: { hits.append("rating") }))
        registry.register(fit, entry: .init(specs: [zero], title: "Fit", enabled: true, action: { hits.append("fit") }))
        registry.perform(command("0"))
        registry.unregister(fit)
        expect(hits == ["fit", "fit"] && !registry.canPerform(command("0")), "table fit never falls through to disabled shell ratings")
        registry.register(rating, entry: .init(specs: [zero], title: "Rating", enabled: true, action: { hits.append("rating") }))
        registry.perform(command("0"))
        expect(hits.last == "rating", "shell ratings resume after table leaves")
        let lower = UUID(), shifted = UUID(), modified = UUID()
        registry.register(lower, entry: .init(specs: [.init(input: "r")], title: "Right", enabled: true, action: { hits.append("right") }))
        registry.register(shifted, entry: .init(specs: [.init(input: "r", flags: .shift)], title: "Left", enabled: true, action: { hits.append("left") }))
        registry.register(modified, entry: .init(specs: [.init(input: "r", flags: [.command, .alternate])], title: "Modified", enabled: true, action: { hits.append("modified") }))
        registry.perform(command("r")); registry.perform(command("r", .shift)); registry.perform(command("r", [.command, .alternate]))
        expect(Array(hits.suffix(3)) == ["right", "left", "modified"], "plain, shifted and command-option keys remain distinct")
        let count = hits.count
        MacLibraryBrowser.shared.typing = true
        registry.perform(command("0")); registry.perform(command("r", .shift))
        expect(hits.count == count && registry.keyCommands.isEmpty && !registry.canPerform(command("r")), "typing blocks dispatch, command enumeration and menu validation")
        MacLibraryBrowser.shared.typing = false
        registry.register(lower, entry: .init(specs: [.init(input: "r")], title: "Updated", enabled: true, action: { hits.append("updated") }))
        registry.perform(command("r"))
        expect(hits.last == "updated", "existing owner uses latest action after a state update")
        let zoom = UUID()
        registry.register(zoom, entry: .init(specs: MacShortcut.zoomIn.bindings, title: "Zoom", enabled: true, action: { hits.append("zoom") }))
        registry.perform(command("+", .command)); registry.perform(command("=", .command))
        expect(Array(hits.suffix(2)) == ["zoom", "zoom"], "canonical shortcut and keyboard-layout alias dispatch the same action")
        expect(Set(MacShortcut.column.bindings).isDisjoint(with: MacShortcut.browser.bindings), "approved Browser and column bindings do not collide")
        let identities = registry.keyCommands.compactMap { $0.propertyList as? String }
        expect(identities.count == registry.keyCommands.count && Set(identities).count == identities.count,
               "menu commands sharing a selector have unique non-nil identities")
        let page = UUID()
        registry.register(page, entry: .init(specs: [.init(input: UIKeyCommand.inputEscape)], title: "Cancel",
                                            enabled: true, action: { hits.append("cancel") }, allowsDuringTextEditing: true))
        MacLibraryBrowser.shared.typing = true
        expect(registry.canPerform(command(UIKeyCommand.inputEscape)) && !registry.canPerform(command("0")),
               "page Cancel remains available while typing without enabling rating keys")
        registry.perform(command(UIKeyCommand.inputEscape))
        try? await Task.sleep(for: .milliseconds(10))
        expect(hits.last == "cancel" && !MacLibraryBrowser.shared.typing, "Cancel ends field editing before invoking the page action")
        registry.unregister(page)
        // ⌘C and ⌘V are Copy and Paste Settings (2026-11-05), and Edit's Copy and Paste own those keys: the
        // registry answers them by the standard selectors, so a field being edited keeps its own.
        let copy = UUID(), choosing = UUID(), paste = UUID()
        registry.register(copy, entry: .init(specs: MacShortcut.copy.bindings, title: "Copy", enabled: true, action: { hits.append("copy") }))
        registry.register(choosing, entry: .init(specs: MacShortcut.copyChoosing.bindings, title: "Copy…", enabled: true, action: { hits.append("sheet") }))
        registry.register(paste, entry: .init(specs: MacShortcut.paste.bindings, title: "Paste", enabled: true, action: { hits.append("paste") }))
        expect(MacShortcut.copy.bindings == [MacKeySpec(input: "c", flags: .command)]
               && MacShortcut.copyChoosing.bindings == [MacKeySpec(input: "c", flags: [.command, .shift])]
               && MacShortcut.paste.bindings == [MacKeySpec(input: "v", flags: .command), MacKeySpec(input: "v", flags: [.command, .shift])],
               "⌘C copies, ⇧⌘C asks on the sheet, ⌘V and ⇧⌘V paste")
        let copyKey = registry.keyCommands.first { $0.input == "c" && $0.modifierFlags == .command }
        let pasteKey = registry.keyCommands.first { $0.input == "v" && $0.modifierFlags == .command }
        let aliasKey = registry.keyCommands.first { $0.input == "v" && $0.modifierFlags == [.command, .shift] }
        expect(copyKey?.action == #selector(UIResponder.copy(_:)) && copyKey?.propertyList == nil
               && pasteKey?.action == #selector(UIResponder.paste(_:)) && pasteKey?.propertyList == nil,
               "⌘C and ⌘V go by Edit's copy: and paste:, never as items of their own on Edit's keys")
        expect(aliasKey?.action == #selector(AppDelegate.spkShortcut(_:)) && aliasKey?.propertyList as? String != nil,
               "⇧⌘V stays a shortcut of its own")
        registry.performStandard(#selector(UIResponder.copy(_:)))
        registry.performStandard(#selector(UIResponder.paste(_:)))
        registry.perform(command("c", [.command, .shift])); registry.perform(command("v", [.command, .shift]))
        expect(Array(hits.suffix(4)) == ["copy", "paste", "sheet", "paste"], "Edit's Copy and Paste reach the settings; the shifted keys too")
        let before = hits.count
        MacLibraryBrowser.shared.typing = true
        expect(!registry.canPerformStandard(#selector(UIResponder.copy(_:))) && !registry.canPerformStandard(#selector(UIResponder.paste(_:))),
               "while a field is edited Copy and Paste are not the settings'")
        registry.performStandard(#selector(UIResponder.copy(_:))); registry.performStandard(#selector(UIResponder.paste(_:)))
        expect(hits.count == before, "and a field's ⌘C and ⌘V copy and paste nothing of a picture's")
        MacLibraryBrowser.shared.typing = false
        registry.unregister(copy)
        expect(!registry.canPerformStandard(#selector(UIResponder.copy(_:))) && registry.canPerformStandard(#selector(UIResponder.paste(_:))),
               "with no Copy Settings registered Edit's Copy is left alone")
        print("shortcut selftest: \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
