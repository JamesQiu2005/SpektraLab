// Return and Escape belong to the visible page's real primary and cancel actions.
import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func macPageActions(confirmTitle: String = L("Done"), confirmEnabled: Bool = true, cancelEnabled: Bool = true,
                        confirm: (() -> Void)? = nil, cancel: @escaping () -> Void) -> some View {
        background {
            MacKeyRegistration(specs: [.init(input: UIKeyCommand.inputEscape)], title: L("Cancel"),
                               enabled: cancelEnabled, action: cancel, allowsDuringTextEditing: true)
                .frame(width: 0, height: 0).accessibilityHidden(true)
            if let confirm {
                MacKeyRegistration(specs: [.init(input: "\r"), .init(input: "\u{3}")], title: confirmTitle,
                                   enabled: confirmEnabled, action: confirm, allowsDuringTextEditing: true)
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }
}
