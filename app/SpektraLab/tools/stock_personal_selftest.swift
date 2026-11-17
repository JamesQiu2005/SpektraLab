//  stock_personal_selftest.swift — the user's favourites (收藏): the store, and what it owes a record it did not write.
//
//      tools/selftest.sh                # the checks
//      tools/selftest.sh --self-test    # each broken rule below must be caught
//
//  Favourites only: an entry's display name and edge name are kept, never read. What it holds:
//
//  - **the record's shape**: `{"schema":1,"stocks":{"<id>":{"favourite":true}}}` under `stocks.personal`;
//  - **with nothing starred nothing is written**: reading creates no key, a star put on and taken off again leaves
//    no key, and a library from 2.4.0 reads and writes back the same (the plan's rule 7);
//  - **a record it did not write is not lost** (a build that read a newer schema and wrote back only what it knew
//    would wipe it on its next save): an entry's other fields (`displayName`, `edgeName`, any a later build wrote),
//    another stock's entry, a top-level field and a newer schema number all survive a star put on and taken off;
//  - bad JSON reads as nothing starred and is written over by the first star (it is no record to keep);
//  - a push card follows its film's star, and what is no stock (the DI, No Paper) cannot be starred;
//  - the store reads and writes from many threads.
//
//  The defaults are an injected suite, never `UserDefaults.standard` (trap 24).

import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

struct Checker {
    var passed = 0
    var failed: [String] = []
    let quiet: Bool
    mutating func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAIL  \(what)") } }
    }
}

enum Broken: String, CaseIterable {
    case none
    /// An entry rewritten as the store knew it: its other fields gone.
    case dropsUnknownFields = "an entry's other fields are dropped on a write"
    /// The record rewritten as schema 1 whatever it said.
    case downgradesSchema = "a newer schema number is written back as 1"
    /// A key written the moment the store is read, or left once the last star is off.
    case writesNothingStarred = "a record is kept with nothing starred"
    /// A push card its own star.
    case pushIsApart = "a push card is starred apart from its film"
}

func run(_ broken: Broken, catalog: StockCatalog, quiet: Bool) -> Checker {
    var c = Checker(quiet: quiet)
    let name = "stock_personal_selftest"
    let key = StockPersonal.storedKey
    func fresh() -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    func json(_ d: UserDefaults) -> [String: Any]? {
        d.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b, let x = try? JSONSerialization.data(withJSONObject: a, options: .sortedKeys),
              let y = try? JSONSerialization.data(withJSONObject: b, options: .sortedKeys) else { return false }
        return x == y
    }
    /// What a lossy build would have done after the real write: the pre-fix behaviour, as the check must see it.
    func lossy(_ d: UserDefaults) {
        guard let root = json(d), let stocks = root["stocks"] as? [String: [String: Any]] else { return }
        var kept: [String: Any] = [:]
        for (id, entry) in stocks { if entry["favourite"] as? Bool == true { kept[id] = ["favourite": true] } }
        let out: [String: Any] = ["schema": broken == .downgradesSchema ? 1 : root["schema"] as? Int ?? 1, "stocks": kept]
        d.set(try? JSONSerialization.data(withJSONObject: out, options: .sortedKeys), forKey: key)
    }
    func after(_ d: UserDefaults) {
        if broken == .dropsUnknownFields || broken == .downgradesSchema { lossy(d) }
        if broken == .writesNothingStarred, d.object(forKey: key) == nil { d.set(Data(#"{"schema":1,"stocks":{}}"#.utf8), forKey: key) }
    }
    func star(_ s: StockPersonal, _ id: String, _ on: Bool, _ d: UserDefaults) {
        if broken == .pushIsApart { s.setFavourite(id, on) } else { catalog.setFavourite(id, on, s) }
        after(d)
    }
    func isStarred(_ s: StockPersonal, _ id: String) -> Bool {
        broken == .pushIsApart ? s.isFavourite(id) : catalog.isFavourite(id, s)
    }

    // MARK: nothing starred writes nothing
    let d0 = fresh()
    let s0 = StockPersonal(defaults: d0)
    c.expect(!s0.isFavourite("kodak_portra_400"), "nothing kept: nothing is starred")
    c.expect(d0.object(forKey: key) == nil, "reading nothing creates no key")
    star(s0, "kodak_portra_400", true, d0)
    c.expect(isStarred(s0, "kodak_portra_400") && isStarred(StockPersonal(defaults: d0), "kodak_portra_400"), "a star is kept and read back")
    let written = json(d0)
    c.expect(same(written, ["schema": 1, "stocks": ["kodak_portra_400": ["favourite": true]]]),
             "the record's shape: schema 1, the stock's id, favourite true")
    star(s0, "kodak_portra_400", false, d0)
    c.expect(d0.object(forKey: key) == nil, "the last star off leaves no key: 2.4.0's defaults again")
    c.expect(!StockPersonal(defaults: d0).isFavourite("kodak_portra_400"), "and nothing is starred")
    let revision = s0.revision
    star(s0, "kodak_portra_400", false, d0)
    c.expect(s0.revision == revision && d0.object(forKey: key) == nil, "unstarring what is not starred moves and writes nothing")

    // MARK: a record this build did not write
    let d1 = fresh()
    let foreign = #"{"schema":1,"stocks":{"kodak_gold_200":{"displayName":"Gold","edgeName":"GOLD 200","favourite":false,"later":{"n":[1,2,{"x":null}]}},"kodak_ektar_100":{"edgeName":"EKTAR"}},"note":"kept"}"#
    d1.set(Data(foreign.utf8), forKey: key)
    let s1 = StockPersonal(defaults: d1)
    c.expect(d1.data(forKey: key) == Data(foreign.utf8), "a record read is not rewritten")
    star(s1, "kodak_gold_200", true, d1)
    star(s1, "kodak_portra_400", true, d1)
    let on = json(d1)
    let gold = (on?["stocks"] as? [String: Any])?["kodak_gold_200"] as? [String: Any]
    c.expect(gold?["favourite"] as? Bool == true && gold?["displayName"] as? String == "Gold" && gold?["edgeName"] as? String == "GOLD 200"
             && same(gold?["later"], ["n": [1, 2, ["x": NSNull()]] as [Any]]), "a starred entry keeps its names and a field a later build wrote")
    c.expect(same((on?["stocks"] as? [String: Any])?["kodak_ektar_100"], ["edgeName": "EKTAR"]), "another stock's entry is as it was")
    c.expect(on?["note"] as? String == "kept", "a top-level field is kept")
    star(s1, "kodak_gold_200", false, d1)
    star(s1, "kodak_portra_400", false, d1)
    let off = json(d1)
    let goldOff = (off?["stocks"] as? [String: Any])?["kodak_gold_200"] as? [String: Any]
    c.expect(goldOff?["displayName"] as? String == "Gold" && goldOff?["favourite"] as? Bool != true && goldOff?["later"] != nil,
             "unstarred, an entry keeps what was not the star")
    c.expect((off?["stocks"] as? [String: Any])?["kodak_portra_400"] == nil, "an entry that was only a star goes with it")
    c.expect(off?["note"] as? String == "kept" && off?["schema"] as? Int == 1, "the rest of the record is as it came")

    // A newer schema: the number and every field stay.
    let d2 = fresh()
    d2.set(Data(#"{"schema":2,"stocks":{"kodak_gold_200":{"favourite":true,"tags":["a"]}},"groups":{"g":1}}"#.utf8), forKey: key)
    let s2 = StockPersonal(defaults: d2)
    c.expect(s2.isFavourite("kodak_gold_200"), "a newer schema's favourite field is read")
    star(s2, "kodak_portra_400", true, d2)
    star(s2, "kodak_gold_200", false, d2)
    star(s2, "kodak_portra_400", false, d2)
    let later = json(d2)
    c.expect(later?["schema"] as? Int == 2, "a newer schema number is written back as it was, never 1")
    c.expect(same(later?["groups"], ["g": 1]) && same(((later?["stocks"] as? [String: Any])?["kodak_gold_200"]), ["tags": ["a"]]),
             "and its other fields, whatever the stars did")
    c.expect(d2.object(forKey: key) != nil, "a record that was not ours is never removed with the last star")

    // Not a record: read as nothing, written over by a star.
    let d3 = fresh()
    d3.set(Data("not json".utf8), forKey: key)
    let s3 = StockPersonal(defaults: d3)
    c.expect(!s3.isFavourite("kodak_portra_400") && d3.data(forKey: key) == Data("not json".utf8), "bad JSON is nothing starred and is left alone until a star")
    s3.setFavourite("kodak_portra_400", true)
    c.expect(StockPersonal(defaults: d3).isFavourite("kodak_portra_400"), "a star is then kept")
    d3.set(Data(#"{"stocks":{"kodak_portra_400":{"favourite":true}}}"#.utf8), forKey: key)
    c.expect(!StockPersonal(defaults: d3).isFavourite("kodak_portra_400"), "a record with no schema number is not read")

    // MARK: a push follows its film; no stock, no star
    let d4 = fresh()
    let s4 = StockPersonal(defaults: d4)
    let base = "kodak_portra_800", push1 = "kodak_portra_800_push1", push2 = "kodak_portra_800_push2"
    c.expect(catalog.stock(base) != nil && catalog.stock(push1) != nil && catalog.stock(push2) != nil, "the catalogue has Portra 800 and both pushes")
    star(s4, push1, true, d4)
    c.expect(isStarred(s4, base) && isStarred(s4, push1) && isStarred(s4, push2), "starring a push card stars its film, and so every card of it")
    star(s4, base, false, d4)
    c.expect(!isStarred(s4, push1) && !isStarred(s4, push2) && d4.object(forKey: key) == nil, "and unstarring the film takes the pushes with it")
    catalog.setFavourite(StockPreviewCard.digitalIntermediate, true, s4)
    catalog.setFavourite(StockPreviewCard.noPaper, true, s4)
    catalog.setFavourite("no_such_stock", true, s4)
    c.expect(d4.object(forKey: key) == nil && !s4.isFavourite(StockPreviewCard.noPaper), "the DI, No Paper and an unknown id cannot be starred")
    c.expect(catalog.favouriteID(of: "kodak_gold_200") == "kodak_gold_200" && catalog.favouriteID(of: "x_push1") == "x_push1", "an id of no push film is its own")

    // MARK: many threads
    let d5 = fresh()
    let s5 = StockPersonal(defaults: d5)
    let ids = catalog.films.prefix(6).map(\.id)
    nonisolated(unsafe) var strays = 0
    let countLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 3000) { i in
        if i % 5 == 0 { s5.setFavourite(ids[i % ids.count], i % 2 == 0) }
        let v = s5.isFavourite(ids[i % ids.count])
        if v != true && v != false { countLock.lock(); strays += 1; countLock.unlock() }
    }
    let end = json(d5)
    c.expect(strays == 0 && (end == nil || end?["schema"] as? Int == 1), "3,000 reads and writes from many threads leave a whole record")
    d5.removePersistentDomain(forName: name)
    for d in [d0, d1, d2, d3, d4] { d.removePersistentDomain(forName: name) }
    return c
}

@main
struct StockPersonalSelfTest {
    static func main() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let catalog = StockCatalog(contentsOf: root.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("stock personal checks: no catalogue at Resources/StockCatalog.json")
            exit(1)
        }
        let result = run(.none, catalog: catalog, quiet: false)
        print("stock personal checks: \(result.passed) passed, \(result.failed.count) failed")
        var status: Int32 = result.failed.isEmpty ? 0 : 1
        if CommandLine.arguments.contains("--self-test") {
            let broken = Broken.allCases.filter { $0 != .none }
            var caught = 0
            for b in broken {
                let r = run(b, catalog: catalog, quiet: true)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(b.rawValue)") } else {
                    caught += 1
                    print("  caught  \(b.rawValue): \(r.failed.count) check(s) failed, e.g. \(r.failed[0])")
                }
            }
            print("stock personal self-test: \(caught) of \(broken.count) broken rules caught")
            if caught != broken.count { status = 1 }
        }
        exit(status)
    }
}
