import XCTest

/// 1.3.4: CineStill 800T in the catalogue, and the one setting it adds.
final class CineStillTests: XCTestCase {
    /// The stock is offered as a still film on 135 and 120, and it is the only
    /// stock made without an anti-halation layer -- the flag the Film section
    /// keys the fixed switch and the headroom slider on.
    func testCineStillIsAStillFilmWithNoAntihalationLayer() throws {
        let catalog = StockCatalog.shared
        let cs = try XCTUnwrap(catalog.stock("cinestill_800t"))
        XCTAssertTrue(cs.isFilm)
        XCTAssertEqual(cs.name, "CineStill 800T")
        XCTAssertEqual(cs.use, "still")
        XCTAssertEqual(cs.formats ?? [], ["135", "120"])
        XCTAssertTrue(cs.hasNoAntihalationLayer)
        XCTAssertEqual(catalog.stocks.filter(\.hasNoAntihalationLayer).map(\.id), ["cinestill_800t"])
        XCTAssertTrue(catalog.filmsForPicker.contains { $0.id == "cinestill_800t" })
    }

    /// The headroom is on the wire at the engine's own default, and a frame
    /// saved before 1.3.4 decodes to it -- so a 1.3.3 sidecar sends exactly
    /// the engine's default, which every film but CineStill ignores.
    func testTheHeadroomDefaultsToTheEnginesAndLegacyFramesDecode() throws {
        let wire = Dictionary(uniqueKeysWithValues: FilmParams.default.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(wire["halation_headroom_ev"], .double(4))

        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(FilmParams.default.effects)) as! [String: Any]
        legacy.removeValue(forKey: "highlightHeadroom")
        let decoded = try JSONDecoder().decode(EffectStrengths.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.highlightHeadroom, 4)
        XCTAssertTrue(decoded.isDefault)

        var p = FilmParams.default
        p.effects.highlightHeadroom = 99
        let clamped = Dictionary(uniqueKeysWithValues: p.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(clamped["halation_headroom_ev"], .double(EffectStrengths.highlightHeadroomRange.upperBound))
    }
}
