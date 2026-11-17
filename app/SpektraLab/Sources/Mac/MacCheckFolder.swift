//  MacCheckFolder.swift — the folder an in-app check writes to, as `--<name>-check <dir>` gives it (2026-11-14).
//
//  The checks took only an absolute folder, and a relative one made them return without a word: the app launched,
//  started no check and sat idle, and the script waited for ever (33 minutes lost in the 2.4.0 round). The scripts now
//  make the folder absolute (`tools/*_check.sh`), and a check given a relative one says so and exits.

import Foundation

enum MacCheckFolder {
    /// Where `flag` is among `arguments` with an absolute folder after it: its index. Nil where the flag is not given.
    /// Given with no folder, or a relative one: a line saying so, and the app exits 2.
    static func index(of flag: String, in arguments: [String]) -> Int? {
        guard let i = arguments.firstIndex(of: flag) else { return nil }
        guard i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else {
            setvbuf(stdout, nil, _IOLBF, 0)
            print("\(flag.dropFirst(2)): FAIL \(flag) takes an absolute folder; got \(i + 1 < arguments.count ? arguments[i + 1] : "nothing")")
            exit(2)
        }
        return i
    }
}
