//  DevelopRevision.swift — one state of a frame's edit history: what an Undo puts back.
//
//  Moved here from OpenFrameSession.swift unchanged (2026-11-13, PRD-F): the history store (`EditHistoryStore`)
//  keeps revisions off the main actor, and its self-test is compiled without UIKit. What is added below is how a
//  revision is kept (`Codable`) and how two are told apart as a person's edit (`isSameEdit`).

import Foundation

/// A page revision includes source-owned decode changes made from a pair.
struct DevelopRevision: Equatable, Sendable {
    var edit: FrameEdit
    var pair: HalfFramePair?
    var sourceDecodes: [UUID: DecodeSettings]
    /// A double exposure's piece (RFC-050 §3): undone with the look, its photographs' decodes in
    /// `sourceDecodes`. Nil for a photograph and a pair.
    var double: DoubleExposure? = nil

    /// Meter and As Shot readback are observations, not undoable controls.
    /// Pair meter keys still gate reuse if a restored exposure intent differs.
    func keepingReports(from current: DevelopRevision) -> DevelopRevision {
        var copy = self
        func decode(_ saved: DecodeSettings, _ now: DecodeSettings) -> DecodeSettings {
            var value = saved
            if saved.whiteBalance == .asShot, now.whiteBalance == .asShot {
                value.temperature = now.temperature; value.tint = now.tint
            }
            return value
        }
        copy.edit.solvedEV = current.edit.solvedEV
        copy.edit.decode = decode(copy.edit.decode, current.edit.decode)
        for side in HalfFramePair.Side.allCases {
            if var saved = copy.pair?[side], let now = current.pair?[side], saved.frame == now.frame {
                saved.meteredEV = now.meteredEV; saved.meteredFor = now.meteredFor
                saved.decode = decode(saved.decode, now.decode)
                copy.pair?[side] = saved
            }
        }
        // A double's meter readings are observations too: kept as they are now, by exposure.
        for position in DoubleExposure.Position.allCases {
            if var saved = copy.double?[position], let now = current.double?[position], saved.frame == now.frame {
                saved.meterReadings = now.meterReadings
                saved.decode = decode(saved.decode, now.decode)
                copy.double?[position] = saved
            }
        }
        for (id, saved) in copy.sourceDecodes {
            if let now = current.sourceDecodes[id] { copy.sourceDecodes[id] = decode(saved, now) }
        }
        return copy
    }
}


// MARK: kept

/// A revision as the history store keeps it: JSON through the same `Codable` as the library's, every key read
/// if present (PRD-F §3.5), so a state written before a field existed reads with that field neutral — which is
/// what the edit was then. A member's decode is keyed by its id's string: JSON has no other kind of key.
extension DevelopRevision: Codable {
    private enum CodingKeys: String, CodingKey { case edit, pair, sourceDecodes, double }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edit = try c.decodeIfPresent(FrameEdit.self, forKey: .edit) ?? .default
        pair = try c.decodeIfPresent(HalfFramePair.self, forKey: .pair)
        double = try c.decodeIfPresent(DoubleExposure.self, forKey: .double)
        let decodes = try c.decodeIfPresent([String: DecodeSettings].self, forKey: .sourceDecodes) ?? [:]
        sourceDecodes = Dictionary(decodes.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edit, forKey: .edit)
        try c.encodeIfPresent(pair, forKey: .pair)
        try c.encodeIfPresent(double, forKey: .double)
        if !sourceDecodes.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: sourceDecodes.map { ($0.key.uuidString, $0.value) }), forKey: .sourceDecodes)
        }
    }
}

// MARK: told apart

extension DevelopRevision {
    /// Whether `other` is this revision as far as a person's edit goes (PRD-F §3.2, the reconciliation guard): the
    /// same once its observations are taken as this one's (`keepingReports`, as `acceptKeptEdit` compares), and
    /// two more things no person sets left aside — the RAW decode's provenance (`rawExposureFacts`, "readback, not
    /// a hand edit", `OpenFrameSession.readRawExposure`) and a placement still owed its Fit (`placementNeedsFit`,
    /// set by the page when it opens on pull-backs an engine never solved).
    func isSameEdit(as other: DevelopRevision) -> Bool {
        var theirs = other.keepingReports(from: self)
        theirs.edit.rawExposureFacts = edit.rawExposureFacts
        theirs.edit.placementNeedsFit = edit.placementNeedsFit
        return theirs == self
    }
}
