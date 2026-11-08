//  Layer2Snapshots.swift — the develop page with Edit's layer on its frame, for the snapshot harness.
//
//  Not drawn (``): today's develop page with a frame that carries
//  Light, Curve and Colour — the live pass in place of the picture, at fit,
//  in the compare split and zoomed; the status line's "· edited". Adjust's own
//  pages (the strip and each tile's) are `WorkspaceSnapshots`' `V5-A-…`, on the same frame.

import SwiftUI

enum Layer2Snapshots {
    @MainActor static var pages: [SnapshotPage] {
        [
            SnapshotPage("C1-edited", "Develop · Film, a frame with an edit") { model in
                DevelopPane(frameID: edited(DarkroomSnapshots.frameID(model), model), opening: .tab(.film))
            },
            SnapshotPage("C1-edited-compare", "Develop · Compare, a frame with an edit") { model in
                DevelopPane(frameID: edited(DarkroomSnapshots.withOriginal(model), model), opening: DevelopOpening(tab: .film, compare: true))
            },
            SnapshotPage("C1-edited-zoomed", "Develop · zoomed, a frame with an edit") { model in
                DevelopPane(frameID: edited(DarkroomSnapshots.frameID(model), model), opening: DevelopOpening(tab: .film, zoom: 2))
            },
        ]
    }

    /// The frame with every Edit tool moved: a warmer scan, the shadows opened, an S curve, a dark corner.
    @MainActor static func edited(_ id: LibraryFrame.ID, _ model: AppServices) -> LibraryFrame.ID {
        model.library.update(id) { f in
            var a = Adjustments()
            a.exposure = 0.2; a.contrast = 14; a.shadows = 35; a.highlights = -25; a.blacks = -6
            a.temperature = 18; a.saturation = 12
            a.colorBalance.shadows = ColourPad.zone(x: -3, y: -2)
            a.colorBalance.highlights = ColourPad.zone(x: 2, y: 2)
            a.curves.rgb.insert(CGPoint(x: 0.25, y: 0.2)); a.curves.rgb.insert(CGPoint(x: 0.75, y: 0.82))
            a.vignette = Vignette(amount: -45, midpoint: 35)
            a.vibrance = 15
            a.hsl.blue = HSLBand(hue: -15, saturation: 20, luminance: -25)
            a.hsl.orange = HSLBand(hue: 0, saturation: -10, luminance: 15)
            a.channelMixer.red = MixerRow(red: 0, green: 6, blue: 0)
            f.edit.adjustments = a
        }
        return id
    }

    /// A frame whose shadows were set on the old round wheel, between two dots: the pad shows it where it is.
    @MainActor static func oldWheel(_ id: LibraryFrame.ID, _ model: AppServices) -> LibraryFrame.ID {
        model.library.update(id) { f in
            var a = Adjustments()
            a.colorBalance.shadows = ColorZone(hue: 200, saturation: 0.3, luminance: 0.1)
            a.colorBalance.master = ColorZone(hue: 40, saturation: 0.05, luminance: 0)
            f.edit.adjustments = a
        }
        return id
    }

    /// What a tile's page shows in its snapshot: a moved colour, channel or zone where the tool has one.
    static func state(for tool: AdjustTool) -> AdjustState {
        var s = AdjustState()
        switch tool {
        case .hsl: s.hue = .blue
        case .wheels: s.zone = .shadows
        default: break
        }
        return s
    }
}
