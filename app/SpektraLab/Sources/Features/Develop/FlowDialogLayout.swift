//  FlowDialogLayout.swift — the layout of a full-window cover (Crop, Film Edge, a pair's frame).
//
//  A cover takes the app's window: the stage at the left and the cover's own bars in a 393 pt column at
//  the right, one line between.

import SwiftUI

/// The cover's content for its size (the safe area's room).
struct FlowDialogShape<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content
    @Environment(WindowShape.self) private var window: WindowShape?

    var body: some View {
        #if DEBUG
        // The snapshot harness's window: a cover is presented over the real screen, not inside the
        // harness's root, so here it is drawn in the harness's window, as a cover fills its app's.
        if let size = window?.harnessSize {
            content(CGSize(width: size.width, height: size.height - 44))
                .frame(width: size.width, height: size.height - 44)
                .background(Theme.background)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.28).ignoresSafeArea())
        } else {
            measured
        }
        #else
        measured
        #endif
    }

    private var measured: some View {
        GeometryReader { geo in content(geo.size) }
    }
}

/// A cover on the column: the stage at the left and the column of the cover's bars at the right, one
/// line between. Each is given its width.
struct FlowDialogColumns<Stage: View, Column: View>: View {
    let size: CGSize
    @ViewBuilder let stage: (CGFloat) -> Stage
    @ViewBuilder let column: (CGFloat) -> Column

    var body: some View {
        let wall = WindowLayout.column(width: size.width)
        HStack(spacing: 0) {
            stage(wall.picture).frame(width: wall.picture)
            FlowDialogBackdrop()
            column(wall.columnWidth).frame(width: wall.columnWidth)
            Spacer(minLength: 0)
        }
    }
}

/// The column's wall: one line where the picture side meets the column.
struct FlowDialogBackdrop: View {
    var body: some View { Rectangle().fill(Theme.wall).frame(width: 1) }
}
