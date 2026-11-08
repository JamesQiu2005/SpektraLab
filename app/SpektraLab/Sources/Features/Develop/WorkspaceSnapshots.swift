// RFC-038 shell coverage. Links are composition references, not pixel-parity claims:
// material preview cards and final tool panels are RFC-040 work.
import SwiftUI

enum WorkspaceSnapshots {
    @MainActor static var pages: [SnapshotPage] {
        [
            SnapshotPage("V5-paste", "V5 · Paste available") { model in
                let id = DarkroomSnapshots.upright(model)
                model.library.clipboard = SettingsClip(groups: [.light], settings: FrameEdit(), sourceName: "")
                return DevelopPane(frameID: id, opening: DevelopOpening(surface: .edit, editTool: .adjust))
            },
            SnapshotPage("V5-C7-copy", "V5 · Copy") { model in
                CopySettingsDialog(frameID: DarkroomSnapshots.upright(model))
            },
            SnapshotPage("V5-preset-save", "V5 · Save Preset") { model in
                PresetSaveSheet(session: model.session(for: DarkroomSnapshots.upright(model)))
            },
            SnapshotPage("V5-presets", "V5 · Presets") { model in
                PresetSheet(session: model.session(for: DarkroomSnapshots.upright(model)))
            },
            SnapshotPage("V5-X1-adjust", "V5 · Adjust, its strip") { model in
                DevelopPane(frameID: Layer2Snapshots.edited(DarkroomSnapshots.upright(model), model), opening: DevelopOpening(surface: .edit, editTool: .adjust))
            },
        ] + AdjustTool.allCases.map { tool in
            SnapshotPage("V5-A-\(tool.rawValue)", "V5 · Adjust · \(tool.rawValue)") { model in
                DevelopPane(frameID: Layer2Snapshots.edited(DarkroomSnapshots.upright(model), model),
                              opening: DevelopOpening(surface: .edit, editTool: .adjust, adjustTool: tool,
                                                      adjustState: Layer2Snapshots.state(for: tool)))
            }
        } + [
            SnapshotPage("V5-A-tone-points", "V5 · Adjust · Tone, Whites & Blacks") { model in
                DevelopPane(frameID: Layer2Snapshots.edited(DarkroomSnapshots.upright(model), model),
                              opening: DevelopOpening(surface: .edit, editTool: .adjust, adjustTool: .tone,
                                                      adjustState: AdjustState(tone: .whitesBlacks)))
            },
            SnapshotPage("V5-A-curve-parametric", "V5 · Adjust · Curve, parametric") { model in
                DevelopPane(frameID: Layer2Snapshots.edited(DarkroomSnapshots.upright(model), model),
                              opening: DevelopOpening(surface: .edit, editTool: .adjust, adjustTool: .curve,
                                                      adjustState: AdjustState(curveMode: .parametric)))
            },
            SnapshotPage("V5-A-wheels-old", "V5 · Adjust · Colour Wheels, an edit from the old wheel") { model in
                DevelopPane(frameID: Layer2Snapshots.oldWheel(DarkroomSnapshots.upright(model), model),
                              opening: DevelopOpening(surface: .edit, editTool: .adjust, adjustTool: .wheels,
                                                      adjustState: AdjustState(zone: .shadows)))
            },
            SnapshotPage("V5-A-strip-plain", "V5 · Adjust, a frame with no edit") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, editTool: .adjust))
            },
            SnapshotPage("V5-D1", "V5 · Film & Paper") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model))
            },
            SnapshotPage("V5-D2", "V5 · Format") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(step: .format))
            },
            SnapshotPage("V5-X4-darkroom", "V5 · EngineRouter") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, editTool: .darkroom))
            },
            // Not drawn: Decode under Film & Paper (2026-10-24), in place of EngineRouter's Decode tile
            // and Scene Placement — its white balance and its curve on the scene.
            SnapshotPage("V5-D1-decode-wb", "V5 · Film & Paper · Decode · White Balance") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(decodeTool: .whiteBalance))
            },
            SnapshotPage("V5-D1-decode-curve", "V5 · Film & Paper · Decode · Curve") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(decodeTool: .curve))
            },
            // Not drawn: EngineRouter arranged as Adjust (2026-10-22) — Effects' four pills
            // (Grain · Halation · Glare · Couplers).
            SnapshotPage("V5-X4-effects", "V5 · Effects") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, editTool: .darkroom, darkroom: .effects))
            },
            SnapshotPage("V5-X4-effects-couplers", "V5 · Effects · Couplers") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model),
                              opening: DevelopOpening(surface: .edit, editTool: .darkroom, darkroom: .effects, effectsPage: .couplers))
            },
            // Not drawn: the Enlarger stacked under Develop's paper row (2026-10-20), and Pre-flash as its third pill.
            SnapshotPage("V5-X4-enlarger", "V5 · Enlarger") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, editTool: .darkroom, darkroom: .enlarger))
            },
            SnapshotPage("V5-X4-enlarger-preflash", "V5 · Enlarger · Pre-flash") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model),
                              opening: DevelopOpening(surface: .edit, editTool: .darkroom, darkroom: .enlarger, enlargerTool: .preflash))
            },
            SnapshotPage("V5-X5-crop", "V5 · Crop entry") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, editTool: .crop))
            },
            SnapshotPage("V5-X8-folded", "V5 · Folded") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(surface: .edit, panelFolded: true))
            },
            SnapshotPage("V5-D1-slide", "V5 · Slide") { model in
                DevelopPane(frameID: DarkroomSnapshots.slide(model))
            },
            SnapshotPage("V5-D1-bw", "V5 · Silver") { model in
                DevelopPane(frameID: DarkroomSnapshots.silver(model))
            },
            SnapshotPage("V5-D1-rendering", "V5 · Developing") { model in
                DevelopPane(frameID: DarkroomSnapshots.upright(model), opening: DevelopOpening(status: DarkroomSnapshots.status(L("Developing"), 0.58)))
            },
            SnapshotPage("V5-P1-develop", "V5 · Pair") { model in
                DevelopPane(frameID: PairSnapshots.kept(model))
            },
        ]
    }
}
