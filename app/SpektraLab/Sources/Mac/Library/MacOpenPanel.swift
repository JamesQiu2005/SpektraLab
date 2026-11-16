// A native picker for pictures, folders and library documents. UIKit's image-only fileImporter
// greys out Capture One packages; unregistered .spkcatalog directories must also remain selectable.
import UIKit
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
enum MacOpenPanel {
    #if DEBUG
    /// A check's answer instead of the panel, for Import's sources (`MacLibraryBrowser.askImport`): the panel
    /// is AppKit's, served from outside the process, and a check in the background cannot press it. `nil`
    /// (none set) shows the real panel; `.some(nil)` is Cancel; `.some(urls)` is those picked. Taken once.
    static var debugAnswer: [URL]??
    /// The answer comes after this long, as a person's would.
    static var debugAnswerAfter: Duration = .zero
    #endif

    /// Folders, pictures and library documents for Import, several (`MacLibraryBrowser.askImport`).
    static func chooseSources() async -> [URL]? {
        #if DEBUG
        if let answer = debugAnswer {
            debugAnswer = nil
            try? await Task.sleep(for: debugAnswerAfter)
            return answer
        }
        #endif
        return await choose(multiple: true)
    }

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

    /// One Adobe lens profile (`.lcp`) for 镜头校正's Add .lcp File… and Settings' Add .lcp…: files only, filtered to
    /// the extension (Adobe registers no type for it, so it is matched by name).
    static func chooseLensProfile() async -> URL? {
        guard let cls = NSClassFromString("NSOpenPanel") as? NSObject.Type,
              let panel = cls.perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject else { return nil }
        panel.setValue(true, forKey: "canChooseFiles")
        panel.setValue(false, forKey: "canChooseDirectories")
        panel.setValue(false, forKey: "allowsMultipleSelection")
        panel.setValue(L("Add"), forKey: "prompt")
        let lcp = UTType(filenameExtension: "lcp") ?? UTType(exportedAs: "com.adobe.lens-profile", conformingTo: .xml)
        panel.setValue([lcp], forKey: "allowedContentTypes")
        return await present(panel)?.first
    }

    /// PNG files for Settings › Watermarks' Add…: files only, several at once, filtered to PNG. The filter is the panel's
    /// courtesy; the library checks every file by its content (`WatermarkStore.validate`).
    static func choosePNGs() async -> [URL]? {
        guard let cls = NSClassFromString("NSOpenPanel") as? NSObject.Type,
              let panel = cls.perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject else { return nil }
        panel.setValue(true, forKey: "canChooseFiles")
        panel.setValue(false, forKey: "canChooseDirectories")
        panel.setValue(true, forKey: "allowsMultipleSelection")
        panel.setValue(L("Add"), forKey: "prompt")
        panel.setValue([UTType.png], forKey: "allowedContentTypes")
        return await present(panel)
    }

    private static func present(_ panel: NSObject) async -> [URL]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[URL]?, Never>) in
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
