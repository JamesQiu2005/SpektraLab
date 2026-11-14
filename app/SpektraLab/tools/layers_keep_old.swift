//  layers_keep_old.swift — the 2.3.x side of `tools/layers_keep_check.sh`: compiled with **2.3.1's own** `FrameEdit`
//  and its model (`git show spektralab-v2.3.1:…`), never with this tree's.
//
//  What 2.3.x does to a library it opens and writes back, as far as an edit goes: `library.json` is read whole, each
//  frame's `edit` through its `FrameEdit` coder (which reads the keys it knows and writes only those), a change is
//  made, and the file is written again. `layers.json` it does not know, and never opens.
//
//      layers_keep_old <library.json>     reads, moves Film Exposure by +0.5 on every frame, writes it back
//      layers_keep_old --bytes <edit.json> <out.json>   an edit read and written again (sorted keys), as 2.3.1 writes it

import Foundation

@main struct LayersKeepOld {
    static func main() throws {
        if CommandLine.arguments[1] == "--bytes" {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let src = CommandLine.arguments[2]
            let edit = src == "-" ? FrameEdit() : try JSONDecoder().decode(FrameEdit.self, from: Data(contentsOf: URL(fileURLWithPath: src)))
            try enc.encode(edit).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var frames = root["frames"] as! [[String: Any]]
        for i in frames.indices {
            let data = try JSONSerialization.data(withJSONObject: frames[i]["edit"]!)
            var edit = try JSONDecoder().decode(FrameEdit.self, from: data)
            edit.params.exposureCompensationEV += 0.5
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            frames[i]["edit"] = try JSONSerialization.jsonObject(with: enc.encode(edit))
        }
        root["frames"] = frames
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url, options: .atomic)
        print("2.3.1 coder: \(frames.count) frames read, changed and written back to \(url.lastPathComponent)")
    }
}
