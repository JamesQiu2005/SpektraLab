import SwiftUI

struct PresetSheet: View {
    let session: OpenFrameSession
    @Environment(AppServices.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var renaming: LookPreset?
    @State private var rename = ""
    @State private var missing: String?

    var body: some View {
        NavigationStack {
            List {
                if let missing { Text(missing).foregroundStyle(.red) }
                if let error = model.presets.error { Text(error).foregroundStyle(.red) }
                Section(L("Presets")) {
                    if model.presets.presets.isEmpty { Text(L("No presets yet")).foregroundStyle(Theme.secondaryText) }
                    ForEach(model.presets.presets) { preset in
                        HStack {
                            Button(preset.name) { apply(preset) }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            Menu {
                                Button(L("Rename")) { renaming = preset; rename = preset.name }
                                Button(L("Delete"), role: .destructive) { model.presets.delete(preset.id) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .accessibilityLabel(preset.name + ", " + L("Presets"))
                        }
                    }
                    if model.presets.canRestore { Button(L("Undo Delete")) { model.presets.restoreDeleted() } }
                }
                Section {
                    Button(L("Save Preset")) { saving = true }
                        .disabled(!model.presets.canWrite)
                }
            }
            .navigationTitle(L("Presets")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
            .sheet(isPresented: $saving) { PresetSaveSheet(session: session).appEnvironment(model) }
            .alert(L("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L("Name"), text: $rename)
                Button(L("Save")) { if let p = renaming { _ = model.presets.rename(p.id, to: rename) }; renaming = nil }
                Button(L("Cancel"), role: .cancel) { renaming = nil }
            }
        }
        .macPageActions(confirmEnabled: !saving && renaming == nil,
                        cancelEnabled: !saving && renaming == nil,
                        confirm: { dismiss() }, cancel: { dismiss() })
    }
    private func apply(_ preset: LookPreset) {
        if let line = preset.clip.missingMaterialsLine { missing = line; return }
        model.applyLook(preset.clip, to: session)
        dismiss()
    }
}

struct PresetSaveSheet: View {
    let session: OpenFrameSession
    @Environment(AppServices.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked = ClipboardGroup.defaultSelection

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Name"), text: $name).submitLabel(.done)
                    .onSubmit { save() }
                SettingsGroupPicker(picked: $picked, edit: session.transferableSettings)
                if let error = model.presets.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L("Save Preset")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save")) { save() }.disabled(!canSave) }
            }
        }
        .macPageActions(confirmTitle: L("Save"), confirmEnabled: canSave, confirm: save, cancel: { dismiss() })
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !picked.isEmpty && model.presets.canWrite
    }
    private func save() {
        guard canSave else { return }
        if model.presets.save(name: name, clip: session.clip(groups: picked, sourceName: "")) {
            dismiss()
        }
    }

}

/// Eight V5 rows; EngineRouter expands to independent canonical leaves.
struct SettingsGroupPicker: View {
    @Binding var picked: Set<ClipboardGroup>
    let edit: FrameEdit
    // Decode is Film & Paper's since 2026-10-24 (the white balance and the curve); Scene Placement
    // has no control left to set it.
    private let top: [ClipboardGroup] = [.filmAndPaper, .filmExposure, .decode, .format, .filmEdgeAndDateBack]
    private let darkroom: [ClipboardGroup] = [.enlarger, .couplers, .preflash]
    var body: some View {
        ForEach(top.filter { ClipboardGroup.offered.contains($0) }) { row($0) }
        DisclosureGroup(L("Darkroom")) { ForEach(darkroom) { row($0) } }
        ForEach([ClipboardGroup.light, .curve, .colour]) { row($0) }
    }
    private func row(_ group: ClipboardGroup) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(group) }, set: { on in
            if on { picked.insert(group) } else { picked.remove(group) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                Text(group.summary(of: edit)).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
        }.tint(Theme.accent).frame(minHeight: 44)
    }
}
