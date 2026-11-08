//  ResetAlert.swift — the one way the app asks before a reset.
//
//  A testers' screenshot of 2026-10-18: a confirmation dialog shown on the operating system 26
//  from a button low on the page is a popover, which drops its Cancel and
//  leaves the title and the one button saying the same "还原 胶片曝光". The
//  system's alert always shows both: Cancel beside Reset, the question above.

import SwiftUI

extension View {
    /// Asks "Reset <what>?" with Cancel and a destructive Reset. `what` is the
    /// page or tool's own title; nil asks about nothing and shows no alert.
    func resetAlert(_ what: String?, isPresented: Binding<Bool>, perform: @escaping () -> Void) -> some View {
        alert(L("Reset \(what ?? "")?"), isPresented: Binding(get: { isPresented.wrappedValue && what != nil },
                                                             set: { isPresented.wrappedValue = $0 })) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Reset"), role: .destructive, action: perform)
        }
    }
}
