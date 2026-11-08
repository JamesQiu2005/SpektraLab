//  Indicators.swift — state: what is developing, what is chosen, what is on.
//
//  The accent is reserved for actions and state, and these are the state half:
//  the develop ring on a tile, the bar on the picture's bottom edge, the dot
//  on the status line, a switch that is on, a ticked box.

import SwiftUI

/// The develop ring: an accent arc over a faint track. On a library tile
/// (radius 13), on the import banner (9).
struct ProgressRing: View {
    /// 0…1; nil is a frame that is queued and has not started — the track alone.
    var progress: Double?
    var diameter: CGFloat = 26
    var lineWidth: CGFloat = 2.5
    var track: Color = Color.white.opacity(0.25)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let progress {
                Circle().trim(from: 0, to: progress.clamped(to: 0...1))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(progress.map { L("Developing, \(Int($0 * 100)) percent") } ?? L("Waiting to develop"))
    }
}

/// Develop on commit: an accent bar on the picture's bottom edge while the
/// newer develop is under way. The picture above it is always the last
/// finished one — never blank, never half drawn (RFC-036 §3.5).
struct DevelopProgressBar: View {
    /// 0…1; nil hides the bar.
    var progress: Double?
    var body: some View {
        GeometryReader { geo in
            if let progress {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.5))
                    Rectangle().fill(Theme.accent).frame(width: geo.size.width * progress.clamped(to: 0...1))
                }
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// `status_line`: a dot and a sentence. Accent while something is under way,
/// quiet when it is done.
struct StatusLine: View {
    let text: String
    var busy = true
    var body: some View {
        // A wait's reason, or a frame's own line with two long stock names, can be
        // long: it is set smaller first — the drawing's 12 pt, then 11, then 10 —
        // and only then onto a second line, before any of it is cut. (A scale
        // factor alone wraps before it shrinks.)
        HStack(alignment: .firstTextBaseline, spacing: 6.5) {
            Circle().fill(busy ? Theme.accent : Theme.secondaryText).frame(width: 7, height: 7)
                // status_line(): the dot's centre is 4 above the baseline.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 0.5 }
            ViewThatFits(in: .horizontal) {
                line(12).fixedSize()
                line(11).fixedSize()
                line(10).fixedSize()
                line(10, lines: 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ size: CGFloat, lines: Int = 1) -> some View {
        Text(text).font(Theme.Font.ui(size)).foregroundStyle(Theme.secondaryText).lineLimit(lines)
    }
}

/// `toggle`: an the operating system switch in the app's accent. Drawn rather than tinted, so
/// its off track and its size are the drawing's on every system.
struct SpkToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.accent : Theme.toggleOff)
            Circle().fill(Color.white).frame(width: 27, height: 27).padding(2)
        }
        .frame(width: 51, height: 31)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("On") : L("Off"))
    }
}

/// `tick_box`: the desktop's checkbox at a finger's size. Accent when on (it
/// is state), an outline when off.
struct TickBox: View {
    let on: Bool
    var side: CGFloat = 20
    var body: some View {
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: side * 0.24).fill(Theme.accent)
                Icon(.tick, size: 22 * side / 20, color: Theme.onSelection)
            } else {
                RoundedRectangle(cornerRadius: side * 0.22).strokeBorder(Theme.dim, lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
    }
}

/// `pick_circle`: selection on a tile, in Select.
struct PickCircle: View {
    let on: Bool
    var diameter: CGFloat = 22
    var body: some View {
        ZStack {
            if on {
                Circle().fill(Theme.selection).overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                Icon(.check, size: diameter, color: Theme.onSelection)
            } else {
                Circle().fill(Color.black.opacity(0.25)).overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
