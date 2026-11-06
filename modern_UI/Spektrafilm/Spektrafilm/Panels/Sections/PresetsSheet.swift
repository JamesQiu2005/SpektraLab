//  PresetsSheet.swift — the settings clipboard's saved presets (1.3.6).
//
//  A sheet over the editor: the title with Done at the right, the saved
//  presets one row each with a menu, and a Save Preset row that turns into a
//  name field. Clicking a row applies the preset where a paste would go and
//  closes the sheet, so the result is what the user sees next.
//
//  Built from the app's own parts: the rail's card ground, ground-coloured
//  rows, the accent for what can be clicked, Theme's type. Text wraps and is
//  never cut (the 2026-09-28 rules); only the menu's glyph is an ellipsis.

import SwiftUI

struct PresetsSheet: View {
    @Bindable var session: Session
    @Bindable var store: SettingsPresetStore
    let dismiss: () -> Void

    /// Non-nil while the Save Preset row is a name field.
    @State private var newName: String?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var fieldFocused: Bool

    private var factor: CGFloat { InterfaceScaleStore.shared.scale.factor }
    private var editing: Bool { newName != nil || renaming != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.rule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 8 * factor) {
                    Text(L("Presets", zh: "预设"))
                        .font(Theme.Font.groupHeader)
                        .foregroundStyle(Theme.dim)
                    if store.presets.isEmpty {
                        Text(L("No presets yet. Tick the groups in the Settings Clipboard, then save the open photo's settings as a preset.",
                               zh: "还没有预设。在“设置剪贴板”中勾选项目，然后将当前照片的设置保存为预设。"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(store.presets) { preset in row(preset) }
                    saveRow.padding(.top, 8 * factor)
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16 * factor)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 380 * factor)
        .frame(minHeight: 240 * factor, idealHeight: 340 * factor, maxHeight: 560 * factor)
        .background(Theme.card)
    }

    // MARK: header

    private var header: some View {
        ZStack {
            Text(L("Presets", zh: "预设"))
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.text)
            HStack {
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Text(L("Done", zh: "完成"))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.onSelection)
                        .padding(.horizontal, 14 * factor)
                        .frame(height: Theme.Metric.controlHeight + 6 * factor)
                        .background(Theme.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(editing ? nil : .cancelAction)
            }
        }
        .padding(.horizontal, 16 * factor)
        .padding(.vertical, 10 * factor)
    }

    // MARK: a preset

    private func row(_ preset: SettingsPreset) -> some View {
        HStack(alignment: .center, spacing: 8 * factor) {
            VStack(alignment: .leading, spacing: 3 * factor) {
                if renaming == preset.id {
                    field($renameText, commit: {
                        store.rename(preset.id, to: renameText)
                        renaming = nil
                    }, cancel: { renaming = nil })
                } else {
                    Text(preset.name)
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(preset.orderedGroups.map(\.title).joined(separator: " · "))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Menu {
                Button(L("Rename", zh: "重命名")) {
                    renameText = preset.name
                    renaming = preset.id
                    fieldFocused = true
                }
                Button(L("Update from Open Photo", zh: "用当前照片更新")) {
                    if let p = session.presetFromOpenFrame(name: preset.name) {
                        store.replace(preset.id, with: p)
                    }
                }
                .disabled(!session.canSavePreset)
                Divider()
                Button(L("Delete", zh: "删除"), role: .destructive) { store.remove(preset.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24 * factor, height: 24 * factor)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .help(L("Rename, update or delete this preset", zh: "重命名、更新或删除此预设"))
        }
        .padding(.horizontal, 12 * factor)
        .padding(.vertical, 10 * factor)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 8 * factor))
        .contentShape(RoundedRectangle(cornerRadius: 8 * factor))
        .onTapGesture {
            guard renaming != preset.id, session.canApplyPreset else { return }
            session.applyPreset(preset)
            dismiss()
        }
        .opacity(session.canApplyPreset ? 1 : Theme.disabledOpacity)
        .help(session.canApplyPreset
              ? L("Apply to the photos a paste would change", zh: "应用到粘贴会改动的照片")
              : L("Open a photo to apply a preset", zh: "打开一张照片后才能应用预设"))
    }

    // MARK: save

    @ViewBuilder private var saveRow: some View {
        if newName != nil {
            HStack(spacing: 8 * factor) {
                field(Binding(get: { newName ?? "" }, set: { newName = $0 }),
                      commit: commitNew, cancel: { newName = nil })
                Spacer(minLength: 0)
                Button(action: commitNew) {
                    Text(L("Save", zh: "保存"))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12 * factor)
            .padding(.vertical, 10 * factor)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 8 * factor))
        } else {
            Button {
                newName = store.nextName()
                fieldFocused = true
            } label: {
                Text(L("Save Preset", zh: "保存预设"))
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12 * factor)
                    .padding(.vertical, 10 * factor)
                    .background(Theme.ground, in: RoundedRectangle(cornerRadius: 8 * factor))
                    .contentShape(RoundedRectangle(cornerRadius: 8 * factor))
            }
            .buttonStyle(.plain)
            .rowEnabled(session.canSavePreset)
            .help(L("Save the open photo's settings in the ticked groups",
                    zh: "保存当前照片中勾选项目的设置"))
        }
    }

    private func commitNew() {
        let name = (newName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = name.isEmpty ? store.nextName() : name
        if let p = session.presetFromOpenFrame(name: chosen) { store.add(p) }
        newName = nil
    }

    /// Why Save is off, and a file problem, in words rather than only a dim row.
    private var notes: [String] {
        var out: [String] = []
        if !session.canSavePreset {
            out.append(session.selection == nil
                ? L("Open a photo to save its settings as a preset.", zh: "打开一张照片后才能保存其设置为预设。")
                : L("Tick at least one group in the Settings Clipboard to save a preset.",
                    zh: "请在“设置剪贴板”中至少勾选一个项目，才能保存预设。"))
        }
        if let problem = store.problem { out.append(problem) }
        return out
    }

    private func field(_ text: Binding<String>, commit: @escaping () -> Void,
                       cancel: @escaping () -> Void) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(Theme.Font.label)
            .foregroundStyle(Theme.text)
            .focused($fieldFocused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
    }
}
