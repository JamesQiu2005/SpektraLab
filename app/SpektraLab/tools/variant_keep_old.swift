// variant_keep_old.swift -- 2.3.2 going over a library this tree wrote (tools/variant_keep_old.sh builds it with 2.3.2's
// own library coder, `StoredLibrary` / `StoredFrame` of 88685135, "chore(release): 2.3.2", and its model files).
//
//   variant_keep_old <library.json> <exposure>
//
// What 2.3.2 does at its next save after any change: it reads `library.json` with its coder (a key it does not know,
// such as `variant`, is passed over), every frame's edit is changed here (its exposure set to <exposure>: "2.3.2's own
// change"), and the whole file is written back as 2.3.2's `LibraryPersistence.write` writes it (ISO 8601 dates, sorted
// keys, atomically). `variants.json` beside it is a file 2.3.2 never opens. Prints what it read.
import Foundation

@main
enum VariantKeepOld {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let exposure = Double(args[2]) else { print("usage: variant_keep_old <library.json> <exposure>"); exit(2) }
        let url = URL(fileURLWithPath: args[1])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var library = try? decoder.decode(StoredLibrary.self, from: data) else {
            print("2.3.2: library.json does not read"); exit(1)
        }
        for i in library.frames.indices { library.frames[i].edit.adjustments.exposure = exposure }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let out = try? encoder.encode(library), (try? out.write(to: url, options: .atomic)) != nil else { print("2.3.2: not written"); exit(1) }
        let text = String(decoding: out, as: UTF8.self)
        print("2.3.2: read and rewrote \(library.frames.count) frames, exposure \(exposure); \"variant\" in its file: \(text.contains("\"variant\""))")
    }
}
