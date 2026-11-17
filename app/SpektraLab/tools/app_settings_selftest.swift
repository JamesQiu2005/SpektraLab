//  app_settings_selftest.swift — what a setting of `AppSettings` owes: its default, its key, and that it rests silently.
//
//      tools/selftest.sh                # with the other checks
//
//  Compiled with `Services/AppSettings.swift` and what it stands on. Held here today: 2.4.1's No Paper card is no
//  setting (the owner, 2026-11-16: "We use B", always shown, first), so **nothing is read or written for it**:
//
//  - `settings.offersNoPaper` was never released (2.4.1 only): a defaults that carries it is read without a change,
//    and AppSettings neither reads it nor writes it back (it is left as it was);
//  - reading what was kept (or nothing), and changing another setting, never creates the key
//    (`LensEdge.swift`'s header is the rule).

import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

@main
struct AppSettingsSelfTest {
    @MainActor static func main() {
        var passed = 0
        var failed: [String] = []
        func expect(_ ok: Bool, _ what: String) {
            if ok { passed += 1 } else { failed.append(what); print("  FAIL  \(what)") }
        }
        func suite(_ name: String) -> UserDefaults {
            let d = UserDefaults(suiteName: "app_settings_selftest.\(name)")!
            d.removePersistentDomain(forName: "app_settings_selftest.\(name)")
            return d
        }
        let key = "settings.offersNoPaper"

        // Where nothing was kept: reading wrote nothing.
        let fresh = suite("fresh")
        _ = AppSettings(defaults: fresh)
        expect(fresh.object(forKey: key) == nil, "no paper: reading nothing writes no key")

        // A library kept by 2.4.0: its other settings, no such key.
        let older = suite("older")
        older.set(true, forKey: "settings.cropRemapsFrame")
        older.set(true, forKey: "settings.hdrByDefault")
        let kept = AppSettings(defaults: older)
        expect(kept.cropRemapsFrame && kept.hdrByDefault, "no paper: a 2.4.0 library's kept settings read as they were")
        expect(older.object(forKey: key) == nil, "no paper: a 2.4.0 library is read without the key being made")
        kept.cropRemapsFrame = false
        expect(older.object(forKey: key) == nil, "no paper: another setting's change writes no such key")

        // A 2.4.1 development build's leftover key: not read, not rewritten, not removed.
        let dev = suite("dev")
        dev.set(true, forKey: key)
        let devSettings = AppSettings(defaults: dev)
        devSettings.hdrByDefault = true
        expect(dev.bool(forKey: key) && dev.bool(forKey: "settings.hdrByDefault"), "no paper: a leftover development key is left as it was")

        // Enable EDR by Default and Enable HDR by Default (the owner, 2026-11-16): never both, the last switched on wins.
        let both = suite("both")
        let x = AppSettings(defaults: both)
        expect(!x.edrByDefault && !FilmParams.edrByDefault, "edr: off where nothing was kept")
        x.hdrByDefault = true
        x.edrByDefault = true
        expect(x.edrByDefault && !x.hdrByDefault && FilmParams.edrByDefault && !FrameEdit.hdrByDefault,
               "edr: switched on after HDR, EDR's is the default and HDR's goes off")
        expect(both.bool(forKey: "settings.edrByDefault") && !both.bool(forKey: "settings.hdrByDefault"), "edr: and both are kept so")
        x.hdrByDefault = true
        expect(x.hdrByDefault && !x.edrByDefault && !FilmParams.edrByDefault, "edr: HDR switched on after it turns EDR's off")
        x.hdrByDefault = false
        expect(!x.hdrByDefault && !x.edrByDefault, "edr: switched off, a default turns only itself off")
        x.edrByDefault = true; x.edrByDefault = false
        expect(!x.edrByDefault && !x.hdrByDefault, "edr: EDR switched off leaves HDR's as it was")
        x.edrByDefault = true
        let relaunched = AppSettings(defaults: both)
        expect(relaunched.edrByDefault && !relaunched.hdrByDefault && FilmParams.edrByDefault, "edr: kept across a relaunch")
        both.set(true, forKey: "settings.hdrByDefault")
        let handWritten = AppSettings(defaults: both)
        expect(handWritten.hdrByDefault && !handWritten.edrByDefault, "edr: a store that says both reads as HDR's alone")

        for name in ["fresh", "older", "dev", "both"] { UserDefaults(suiteName: "app_settings_selftest.\(name)")?.removePersistentDomain(forName: "app_settings_selftest.\(name)") }
        print("app settings checks: \(passed) passed, \(failed.count) failed")
        exit(failed.isEmpty ? 0 : 1)
    }
}
