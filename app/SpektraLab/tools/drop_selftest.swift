//  drop_selftest.swift — 松手即导入 (Drop to Import): which drags the window answers, and that its note goes
//  however a drag ends (PRD-C, 2026-11-09). Compiled with Sources/Mac/Import/MacDropOffer.swift alone.
//
//      tools/selftest.sh            (runs it)
//      swiftc -parse-as-library Sources/Mac/Import/MacDropOffer.swift tools/drop_selftest.swift -o /tmp/d && /tmp/d
//
//  The type identifiers are what a drag's items register (`NSItemProvider.registeredTypeIdentifiers`):
//  Finder's file URL with the file's own type; a web page's picture as data and its address, no file;
//  another app's file promise; plain text.

import Foundation

final class Checks {
    var failed: [String] = []
    var passed = 0
    func expect(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { failed.append(what) } }
}

let finderDNG = ["public.file-url", "com.adobe.raw-image"]
let finderJPEG = ["public.file-url", "public.jpeg"]
let finderFolder = ["public.file-url", "public.folder"]
let finderCatalog = ["public.file-url", "dyn.ah62d4rv4ge81e5pe"]   // a .spkcatalog: no type the system knows
let fileURLOnly = ["public.file-url"]
let finderPDF = ["public.file-url", "com.adobe.pdf"]
let finderText = ["public.file-url", "public.plain-text"]
let webImage = ["public.png", "public.url"]
let webImageHTML = ["public.jpeg", "public.html", "public.url"]
let safariText = ["public.utf8-plain-text", "public.plain-text"]
let photosPromise = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type", "public.jpeg"]
// What Finder's drag actually registers on Catalyst, read off the app's log on 2026-11-10 (a Nikon RAW): the
// file's own type and Finder's node marker, and **no** public.file-url. The table above was written without one
// such drag and took every real Finder drag for "no file" (2.3.0: Drop to Import gone).
let realFinderNEF = ["com.nikon.raw-image", "com.apple.finder.node"]
let realFinderJPEG = ["public.jpeg", "com.apple.finder.node"]
let realFinderFolder = ["public.folder", "com.apple.finder.node"]
let realFinderPDF = ["com.adobe.pdf", "com.apple.finder.node"]
let promisePDF = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type", "com.adobe.pdf"]

func verdicts(_ c: Checks) {
    func v(_ items: [[String]], local: Bool = false) -> MacDropVerdict { MacDropOffer.verdict(local: local, items: items) }
    c.expect(v([finderDNG]) == .files, "a DNG dragged from Finder is taken (\(v([finderDNG])))")
    c.expect(v([finderJPEG]) == .files, "a JPEG dragged from Finder is taken")
    c.expect(v([finderFolder]) == .files, "a folder dragged from Finder is taken")
    c.expect(v([finderCatalog]) == .files, "a catalog dragged from Finder is taken (its type is the system's guess)")
    c.expect(v([fileURLOnly]) == .files, "a file URL that names no type is taken (what it is decides at the drop)")
    c.expect(v([finderPDF]) == .notImportable, "a PDF dragged from Finder is not (\(v([finderPDF])))")
    c.expect(v([finderText]) == .notImportable, "a text file dragged from Finder is not (\(v([finderText])))")
    c.expect(v([webImage]) == .noFile, "a picture dragged off a web page, with no file, is not (\(v([webImage])))")
    c.expect(v([webImageHTML]) == .noFile, "…nor one with its page's HTML (\(v([webImageHTML])))")
    c.expect(v([safariText]) == .noFile, "text dragged from Safari is not (\(v([safariText])))")
    c.expect(v([photosPromise]) == .files, "another app's promise of a picture file is taken (\(v([photosPromise])))")
    c.expect(v([promisePDF]) == .notImportable, "a promise of a PDF is not (\(v([promisePDF])))")
    c.expect(v([finderDNG], local: true) == .inApp, "a drag that starts in this app is not, whatever it holds (\(v([finderDNG], local: true)))")
    c.expect(v([finderPDF, finderDNG]) == .files, "a drag with one picture among other files is taken")
    c.expect(v([webImage, finderDNG]) == .files, "a drag with one file among web pictures is taken")
    c.expect(v([]) == .empty, "a drag with no items is not")
    c.expect(v([realFinderNEF]) == .files, "a NEF as Finder really drags it (no file URL) is taken (\(v([realFinderNEF])))")
    c.expect(v([realFinderJPEG]) == .files, "a JPEG as Finder really drags it is taken (\(v([realFinderJPEG])))")
    c.expect(v([realFinderFolder]) == .files, "a folder as Finder really drags it is taken (\(v([realFinderFolder])))")
    c.expect(v([realFinderPDF]) == .notImportable, "a PDF as Finder really drags it is not, with the ⊘ (\(v([realFinderPDF])))")
}

func states(_ c: Checks) {
    var s = MacDropNoteState()
    s.entered(.files); c.expect(s.shown, "a Finder drag over the window shows the note")
    s.updated(.files); s.exited(); c.expect(!s.shown, "it leaves the window: the note goes")

    s = MacDropNoteState()
    s.entered(.files); s.ended(); c.expect(!s.shown, "it ends without leaving (dropped elsewhere, Esc): the note goes")

    s = MacDropNoteState()
    s.entered(.files); s.dropped(); c.expect(!s.shown, "dropped: the note goes")
    s.ended(); c.expect(!s.shown, "…and stays gone when the drag then ends")

    s = MacDropNoteState()
    s.entered(.noFile); s.updated(.noFile); c.expect(!s.shown, "a web picture with no file shows no note")
    s.entered(.inApp); s.updated(.inApp); c.expect(!s.shown, "a drag from inside the app shows no note")
    s.entered(.notImportable); c.expect(!s.shown, "a PDF shows no note")

    s = MacDropNoteState()
    s.entered(.files, accepting: false); c.expect(!s.shown, "a drop the window refuses now (another page's sheet, an import running) shows no note")
    s.updated(.files, accepting: true); c.expect(s.shown, "…and shows it once the window takes drops again, the drag still over it")
    s.updated(.files, accepting: false); c.expect(!s.shown, "…and hides it when it stops taking them")

    s = MacDropNoteState()
    s.entered(.files); s.interrupted(); c.expect(!s.shown, "a stuck note goes at the next click, key or loss of focus")
    s.updated(.files); c.expect(!s.shown, "…and a stray update after it does not bring it back")
    s.entered(.files); c.expect(s.shown, "a new drag shows it again")

    s = MacDropNoteState()
    s.exited(); s.ended(); s.interrupted(); c.expect(!s.shown, "an end, an exit or a click with no drag shows nothing")
    s.updated(.files); c.expect(!s.shown, "an update with no drag entered shows nothing")
}

@main
enum Main {
    static func main() {
        let c = Checks()
        verdicts(c)
        states(c)
        for f in c.failed { print("  FAIL: \(f)") }
        print("drop checks: \(c.passed) passed, \(c.failed.count) failed")
        exit(c.failed.isEmpty ? 0 : 1)
    }
}
