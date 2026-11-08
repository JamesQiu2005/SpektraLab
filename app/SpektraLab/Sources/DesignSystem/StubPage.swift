//  StubPage.swift — a page that is not built yet, saying which one it is.
//
//  The two halves of the app are built side by side over this foundation. Until
//  a page is built, its route shows this: the page's id on the flow map, its
//  name, and a way back. It should not survive into a finished build.

import SwiftUI

struct StubPage: View {
    let id: String
    let title: String
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(id).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.dim)
            Text(title).font(Theme.Font.sheetTitle).foregroundStyle(Theme.text)
            Text(L("Not built yet")).font(Theme.Font.note).foregroundStyle(Theme.dim)
            if let onClose {
                CapsuleButton(title: L("Back"), primary: false, width: 120, action: onClose).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
