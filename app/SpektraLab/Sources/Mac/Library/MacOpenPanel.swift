// A native picker for pictures, folders and library documents. UIKit's image-only fileImporter
// greys out Capture One packages; unregistered .spkcatalog directories must also remain selectable.
import UIKit
import ObjectiveC

@MainActor
enum MacOpenPanel {
    static func choose(multiple: Bool) async -> [URL]? {
        guard let cls = NSClassFromString("NSOpenPanel") as? NSObject.Type,
              let panel = cls.perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject else { return nil }
        panel.setValue(true, forKey: "canChooseFiles")
        panel.setValue(true, forKey: "canChooseDirectories")
        panel.setValue(multiple, forKey: "allowsMultipleSelection")
        panel.setValue(false, forKey: "treatsFilePackagesAsDirectories")
        panel.setValue(L("Open"), forKey: "prompt")
        // No content-type filter: source classification owns acceptance. This also works before the
        // system has registered SpektraLab's document types, instead of silently greying a library out.
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL]?, Never>) in
            typealias Handler = @convention(block) (Int) -> Void
            let handler: Handler = { response in
                continuation.resume(returning: response == 1 ? panel.value(forKey: "URLs") as? [URL] : nil)
            }
            let sheet = NSSelectorFromString("beginSheetModalForWindow:completionHandler:")
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow,
               let native = MacDisplay.nsWindow(for: window), panel.responds(to: sheet) {
                typealias Begin = @convention(c) (NSObject, Selector, NSObject, @escaping Handler) -> Void
                unsafeBitCast(panel.method(for: sheet), to: Begin.self)(panel, sheet, native, handler)
            } else {
                let begin = NSSelectorFromString("beginWithCompletionHandler:")
                typealias Begin = @convention(c) (NSObject, Selector, @escaping Handler) -> Void
                unsafeBitCast(panel.method(for: begin), to: Begin.self)(panel, begin, handler)
            }
        }
    }
}
