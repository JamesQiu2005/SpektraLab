import AppKit
import SwiftUI
import XCTest

/// The refined (V5) system's control behaviour, as arithmetic and as rules:
/// the relative drag, the rest mark and fill, the value ink at rest, the
/// held Original, and the page-local reset with its scope written down.
///
/// Feel is not here — a test process has no pointer and no display link (see
/// AGENTS.md, "an in-process test … cannot see a stall"). What is here is
/// every promise the controls make that is a function of their inputs.
@MainActor
final class DesignSystemV5Tests: XCTestCase {

    // MARK: - the scrub

    /// Contact moves nothing: a drag that has not travelled is where the
    /// value was, whatever the track's length. The old slider jumped to the
    /// click point first, so the first click of a double-click reset moved
    /// the value before the reset could put it back.
    func testADragThatHasNotTravelledLeavesTheValueAlone() {
        for travel in [40.0, 150.0, 400.0] as [CGFloat] {
            for start in [-2.5, 0, 0.3, 3.9] {
                XCTAssertEqual(ScrubDrag.value(from: start, translation: 0, travel: travel, range: -4...4),
                               start, accuracy: 1e-12, "a press moved \(start) on a \(travel) pt track")
            }
        }
    }

    /// Travel, not position: half the track's travel is half the range from
    /// wherever the value began, clamped at the ends.
    func testADragMovesByItsTravel() {
        let r = -4.0...4.0
        XCTAssertEqual(ScrubDrag.value(from: 1, translation: 50, travel: 100, range: r), 5.0.clamped(to: r))
        XCTAssertEqual(ScrubDrag.value(from: -1, translation: 25, travel: 100, range: r), 1, accuracy: 1e-12)
        XCTAssertEqual(ScrubDrag.value(from: 0, translation: -1000, travel: 100, range: r), -4)
        // ⌥ is a quarter of the speed; ⇧ lands on the snap.
        XCTAssertEqual(ScrubDrag.value(from: 0, translation: 50, travel: 100, range: r, fine: true), 1, accuracy: 1e-12)
        XCTAssertEqual(ScrubDrag.value(from: 0, translation: 13, travel: 100, range: r, snap: 0.5), 1)
    }

    /// The fill runs from the rest mark to the knob, either side of it, and
    /// is not drawn at all at rest.
    func testTheFillRunsFromTheRestToTheKnob() throws {
        let r = -100.0...100.0
        XCTAssertNil(ScrubDrag.fill(value: 0, rest: 0, range: r, width: 200))
        // Under half a point of track: not a sliver.
        XCTAssertNil(ScrubDrag.fill(value: 0.2, rest: 0, range: r, width: 200))
        let up = try XCTUnwrap(ScrubDrag.fill(value: 50, rest: 0, range: r, width: 200))
        XCTAssertEqual(up.lowerBound, 0.5, accuracy: 1e-9)
        XCTAssertEqual(up.upperBound, 0.75, accuracy: 1e-9)
        let down = try XCTUnwrap(ScrubDrag.fill(value: -100, rest: 0, range: r, width: 200))
        XCTAssertEqual(down.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(down.upperBound, 0.5, accuracy: 1e-9)
        // A rest at an end (Pre-flash) fills from that end.
        let end = try XCTUnwrap(ScrubDrag.fill(value: 1.5, rest: 0, range: 0...3, width: 200))
        XCTAssertEqual(end.lowerBound, 0, accuracy: 1e-9)
    }

    /// VoiceOver's step is the slider's own ⇧ snap.
    func testAVoiceOverStepIsTheSnap() {
        XCTAssertEqual(ScrubDrag.accessibilityStep(snap: 5, range: -100...100), 5)
        XCTAssertEqual(ScrubDrag.accessibilityStep(snap: 0, range: -100...100), 2)
    }

    /// A value that says what the rest says is metadata ink; a moved one is
    /// primary.
    func testAValueAtRestIsQuiet() {
        XCTAssertEqual(Theme.Ink.value(atRest: true), Theme.Ink.tertiary)
        XCTAssertEqual(Theme.Ink.value(atRest: false), Theme.Ink.primary)
    }

    /// The detent slider's drag is relative too: a press stays on its stop,
    /// one pitch of travel is one stop, and the ends hold.
    func testADetentDragStepsFromWhereItBegan() {
        let range = 2...10, width: CGFloat = 200
        let pitch = (width - Theme.Metric.knobSize.width) / CGFloat(range.count - 1)
        XCTAssertEqual(DetentSlider.stepped(from: 5, translation: 0, width: width, range: range), 5)
        XCTAssertEqual(DetentSlider.stepped(from: 5, translation: pitch * 0.4, width: width, range: range), 5)
        XCTAssertEqual(DetentSlider.stepped(from: 5, translation: pitch * 2, width: width, range: range), 7)
        XCTAssertEqual(DetentSlider.stepped(from: 5, translation: -pitch * 9, width: width, range: range), 2)
        XCTAssertEqual(DetentSlider.stepped(from: 9, translation: pitch * 5, width: width, range: range), 10)
    }

    // MARK: - the Original, held

    /// A hold shows the original only while held; a click latches and a
    /// second click unlatches, as the pill always did.
    func testAHoldReturnsAndAClickLatches() {
        let t = OriginalHold.holdThreshold
        XCTAssertFalse(OriginalHold.afterRelease(wasShowing: false, held: t + 0.2), "a hold left the original up")
        XCTAssertTrue(OriginalHold.afterRelease(wasShowing: true, held: t + 0.2), "a hold took a latched original down")
        XCTAssertTrue(OriginalHold.afterRelease(wasShowing: false, held: 0.05), "a click did not latch")
        XCTAssertFalse(OriginalHold.afterRelease(wasShowing: true, held: 0.05), "a second click did not unlatch")
    }

    /// The key is `\` alone: a ⌘, ⌃ or ⌥ combination is somebody else's.
    func testTheHoldKeyIsABareBackslash() {
        XCTAssertTrue(OriginalHoldKey.isHoldKey(characters: "\\", modifiers: []))
        XCTAssertTrue(OriginalHoldKey.isHoldKey(characters: "\\", modifiers: [.capsLock]))
        XCTAssertFalse(OriginalHoldKey.isHoldKey(characters: "\\", modifiers: [.command]))
        XCTAssertFalse(OriginalHoldKey.isHoldKey(characters: "\\", modifiers: [.option]))
        XCTAssertFalse(OriginalHoldKey.isHoldKey(characters: "|", modifiers: [.shift]))
        XCTAssertFalse(OriginalHoldKey.isHoldKey(characters: " ", modifiers: []))
    }

    /// With no frame open, a press of the key shows nothing and leaves
    /// nothing held for its release to take down.
    func testTheKeyHoldsNothingWithoutAFrame() {
        let s = Session()
        OriginalHoldKey.press(s)
        XCTAssertFalse(s.showingOriginal)
        XCTAssertFalse(OriginalHoldKey.holding)
        OriginalHoldKey.release(s)
        XCTAssertFalse(s.showingOriginal)
    }

    // MARK: - page-local reset

    /// At a fresh frame's values every scope is silent: nothing to reset, and
    /// performing it changes nothing and leaves no undo step.
    func testEveryResetIsSilentAtRest() {
        for scope in SectionReset.allCases {
            let s = Session()
            let before = Snapshot(s)
            XCTAssertFalse(scope.hasChanges(in: s), "\(scope) has changes on a fresh frame")
            scope.perform(in: s)
            XCTAssertEqual(Snapshot(s), before, "\(scope) changed a fresh frame")
            XCTAssertFalse(s.canUndo, "\(scope) left an undo step for a reset that did nothing")
        }
    }

    /// Each scope resets its own fields and **only** those: every field is
    /// moved off its default first, the scope runs, and the fields of every
    /// other part are where they were.
    func testEachResetLeavesItsNeighboursAlone() {
        for scope in SectionReset.allCases {
            let s = Session()
            Self.moveEverything(s)
            let moved = Snapshot(s)
            // Every part sees its sentinel, or a scope that "left it alone"
            // would be checking a part with nothing to leave.
            for part in SectionReset.allCases where part.parts == [part] {
                XCTAssertTrue(part.hasChanges(in: s), "\(part) did not see the sentinel values")
            }
            scope.perform(in: s)
            let after = Snapshot(s)
            for part in SectionReset.allCases where part.parts == [part] {
                let mine = scope.parts.contains(part)
                // Its own fields are at rest; everyone else's are untouched.
                XCTAssertEqual(part.hasChanges(in: s), !mine,
                               "\(scope) → \(part): \(mine ? "not reset" : "reset by a neighbour")")
                if !mine {
                    XCTAssertEqual(after.fields(of: part), moved.fields(of: part),
                                   "\(scope) moved \(part)'s fields")
                }
            }
        }
    }

    /// Film Edge holds the frame: Format's reset leaves the user's own frame
    /// as it is under the edge rather than quietly rewriting it.
    func testFormatDoesNotRewriteAFrameFilmEdgeHolds() {
        let s = Session()
        if let frame = FilmFrame.all.first(where: { $0.id != SectionReset.defaultFrame }) { s.setFilmFrame(frame) }
        var p = s.params
        p.filmEdge.active = true
        s.params = p
        // Not a guard: a test that returned here would pass having checked
        // nothing (trap 16).
        XCTAssertTrue(s.filmEdgeHoldsFrame, "the film edge does not hold the frame")
        let frame = s.params.filmFrame
        XCTAssertNotEqual(frame, SectionReset.defaultFrame)
        XCTAssertFalse(SectionReset.format.hasChanges(in: s))
        SectionReset.format.perform(in: s)
        XCTAssertEqual(s.params.filmFrame, frame)
    }

    /// Every scope has a name in both languages, and the name is "Reset" and
    /// the section's own title.
    func testEveryResetIsNamedInBothLanguages() {
        let language = Localization.shared.language
        defer { Localization.shared.language = language }
        Localization.shared.language = .english
        for scope in SectionReset.allCases {
            XCTAssertTrue(scope.title.hasPrefix("Reset "), scope.title)
            XCTAssertGreaterThan(scope.title.count, "Reset ".count + 2, scope.title)
        }
        XCTAssertEqual(SectionReset.enlarger.title, "Reset Enlarger")
        Localization.shared.language = .simplifiedChinese
        for scope in SectionReset.allCases {
            XCTAssertTrue(scope.title.hasPrefix("重置"), scope.title)
            XCTAssertNil(scope.title.range(of: "Reset"), scope.title)
        }
    }

    // MARK: - helpers

    /// Every field a scope can write, moved off its default.
    static func moveEverything(_ s: Session) {
        var p = s.params
        p.filmStock = "kodak_gold_200"
        p.grainActive = false; p.halationActive = false; p.glareActive = false
        p.effects.grain = 1.5; p.effects.halation = 2; p.effects.scatter = 0.5
        p.effects.highlightBoost = 1; p.effects.glare = 3; p.effects.antihalationRemoved = true
        p.effects.couplersActive = false; p.effects.couplers = 0.5
        p.sceneLatitude.active = true
        p.printBrightnessStops = 0.5; p.yFilterShift = 0.1; p.mFilterShift = -0.1
        p.preflashExposure = 0.01
        s.params = p
        s.aeMethod = AEMethod.offered.first { $0 != SectionReset.defaultMetering } ?? .custom
        s.filmExposure = 1
        if let frame = FilmFrame.all.first(where: { $0.id != SectionReset.defaultFrame }) { s.setFilmFrame(frame) }
        s.setFilmSide(.long)
        s.setWhiteBalance(.tungsten)
        s.setLensCorrection(true)
        var a = s.adjustments; a.vignette.amount = -20; s.adjustments = a
        var g = s.geometry; g.quarterTurns = 1; s.geometry = g
    }

    /// The fields the scopes own, in one comparable value.
    struct Snapshot: Equatable {
        let params: FilmParams
        let decode: DecodeSettings
        let vignette: Double
        let geometry: Geometry
        let metering: AEMethod
        let exposure: Double

        @MainActor init(_ s: Session) {
            params = s.params; decode = s.decode; vignette = s.adjustments.vignette.amount
            geometry = s.geometry; metering = s.aeMethod; exposure = s.filmExposure
        }

        /// The fields of one part scope, as text so any two compare.
        func fields(of part: SectionReset) -> String {
            let p = params, e = params.effects
            switch part {
            case .film: return p.filmStock
            case .filmExposure: return "\(metering) \(exposure) \(p.autoExposure) \(p.exposureCompensationEV)"
            case .decode: return "\(decode.whiteBalance) \(decode.lensCorrection) \(vignette)"
            case .format: return "\(p.filmFrame) \(p.filmSide) \(p.sideLengthMM)"
            case .grainAndHalation:
                return "\(p.grainActive) \(p.halationActive) \(p.glareActive) \(e.grain) \(e.grainLayered) "
                    + "\(e.halation) \(e.antihalationRemoved) \(e.highlightBoost) \(e.scatter) \(e.glare)"
            case .couplers: return "\(e.couplersActive) \(e.couplers)"
            case .scenePlacement: return "\(p.sceneLatitude.active)"
            case .enlargerHead: return "\(p.printBrightnessStops) \(p.yFilterShift) \(p.mFilterShift)"
            case .preflash: return "\(p.preflashExposure)"
            case .crop: return "\(geometry)"
            case .camera, .filmFormat, .enlarger: return ""
            }
        }
    }
}
