//  DiagnosticsPage.swift — the log's words that more than one place says: what is never in it
//  (Settings › Diagnostics, `MacSettingsDiagnostics`) and the ask to share it (`RootView`).

import SwiftUI

enum DiagnosticsPage {
    static var never: String { L("Your pictures. Their file names. Where they were taken. When a photograph in your library was taken. "
        + "Your name. Your Apple Account.") }

    #if SPK_LOG_UPLOAD
    /// The ask, in three lines (`RootView`'s alert). A build with the sending's alone.
    static var askTitle: String { L("Share the log with SpektraLab?") }
    static var ask: String {
        L("This build keeps a log of how it runs on this Mac: its model and macOS, how long each develop and export "
                      + "took and the memory it used, which films and settings you used, and what went wrong. "
                      + "Never a picture, a file name or a place. Settings has the switch, the full list and the privacy policy.")
    }
    #endif
}
