//  FeatureFlags.swift — what is built and deliberately not offered.
//
//  The desktop's rule (`FeatureFlags.swift` there): a control for settings that
//  cannot be seen or changed is a control that lies, so a feature that is held
//  back is held back whole — its pages, its rows, and every line that
//  advertises it — while its settings stay in the model, so nothing has to be
//  migrated when it comes back.

import Foundation

enum FeatureFlags {
    /// **Film Edge** (overscan): the film around the picture — rebate, holes,
    /// edge print (design ids D2-D6, RFC-032). **On** since 2026-10-04, when
    /// the owner lifted the hold of 2026-10-03.
    ///
    /// With it: the Film Edge row on the Frame tab and its four-step flow, the
    /// seventh clipboard group, the Body row in Settings, and a frame shown in its film wherever its
    /// picture is shown. Off, all of those go and `FilmEdgeSettings` stays in
    /// every edit.
    static let filmEdge = true

    /// The **Date Back**: a date exposed onto the negative (RFC-031). On with
    /// Film Edge; it also works alone, in the bare frame.
    static let dateBack = true

    /// The **half-frame pair**: two half frames on one strip of 135
    /// (`overscan_pair`). In the engine, and held back on the host from
    /// 2026-10-04 ("we haven't decided its appearance yet") until the owner
    /// decided it on 2026-10-09: the desktop's way of pairing and its design,
    /// brought to the host (`Model/HalfFramePair.swift`, `Features/Pair`,
    /// `design/pair`). **On since the night of 2026-10-09**: a pair is a
    /// library item the engine develops and exports (`Engine/PairDevelop.swift`,
    /// `tools/pair_check.sh`), reached from Select's *Pair*, from a half
    /// frame's Film Edge and from its own develop page. The owner has not
    /// seen its pages yet: turning this off takes the three ways in away and
    /// leaves every frame as it was (a pair already made stays an item of the
    /// library, and still develops).
    static let halfFramePair = true

    /// **Finishing in the background**: an export that keeps developing after
    /// the app leaves the screen, with its progress shown outside the app
    /// (design/flow: the notes on E1 and E2, and the switch in Settings).
    ///
    /// Off because it is not built. the operating system refuses GPU work to an app that is not
    /// in front — the bench was refused the same way — so the scheduler holds
    /// every job until the app is back (RFC-036 §6.7); carrying on needs a
    /// continued-processing task around a real engine. While it is off the two
    /// export notes say to keep the app open, which is true, and the Settings
    /// switch is shown off and cannot be turned on. The drawings' own words
    /// come back with the flag.
    static let backgroundFinish = false
}
