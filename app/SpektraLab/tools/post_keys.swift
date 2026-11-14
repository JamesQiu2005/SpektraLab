// post_keys.swift -- key presses posted to one process, as the keyboard would send them (`tools/variant_check.sh --keys`,
// `tools/masks_check.sh`):
//
//   post_keys <pid> <key> [<key> ...]
//
// A key is a virtual key code, alone (a function key: sent with Fn, as below) or after the modifiers it is pressed
// with: `k:46` (M, no modifier), `s:33` (⇧[), `a:46` (⌥M), `sa:…` both. Each key down and up through
// `CGEvent.postToPid`, half a second apart. F2 is 120, F3 is 99. With no modifier: a Mac set to "use F1, F2, etc. keys as
// standard function keys" sends these; one that is not sends them with Fn held, and the hardware's own media keys
// otherwise -- this posts the function key itself, which is what reaches an app.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage: post_keys <pid> <key>..."); exit(2) }
let source = CGEventSource(stateID: .hidSystemState)
for token in args.dropFirst(2) {
    var flags: CGEventFlags = .maskSecondaryFn   // what the keyboard sets on a function key
    var codeText = token
    if let colon = token.firstIndex(of: ":") {
        let mods = token[..<colon]
        codeText = String(token[token.index(after: colon)...])
        flags = []
        if mods.contains("s") { flags.insert(.maskShift) }
        if mods.contains("a") { flags.insert(.maskAlternate) }
    }
    guard let code = CGKeyCode(codeText) else { print("not a key: \(token)"); exit(2) }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { print("no event"); exit(1) }
        e.flags = flags
        e.postToPid(pid)
        usleep(60_000)
    }
    print("posted key \(token) to \(pid)")
    usleep(500_000)
}
