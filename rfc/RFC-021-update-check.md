# RFC-021 — Telling the user a newer build exists

| | |
|---|---|
| **Status** | **Implemented 2026-09-21.** |
| **Date** | 2026-09-20 |
| **Author** | At the user's request, from a release cadence of three versions in one day |
| **Supersedes** | **This number was reserved for something else.** See §0. |
| **Scope** | One button in Settings, one request to GitHub's releases API, one comparison, one link out. |
| **Out of scope** | Self-updating, background checks, Sparkle, telemetry of any kind. §3 says why each is out. |

---

## 0. This number was reserved for something else, and that thing is dead

RFC-020 §7 is titled "What RFC-021 needs from this one" and describes an RFC
that chooses the striped render's strip height from free memory at runtime.
**That RFC will not be written, because the thing it would have tuned turned
out to save nothing.**

Measured 2026-09-20 at 101.9 MP on a clean machine, after RFC-020's class R
removed the blur's transposes: the striped render's peak is **9,914 MB against
the whole render's 9,571 MB**, and its buffer high-water **5,977 MB against
5,831 MB**. The mode is *worse*. At 45.7 MP it saves 87 MB of peak and costs
66 MB of high-water. On the pre-R engine the same mode saved 1,024 MB at
102 MP, so this is not a measurement artefact: **class R took the mode's
saving.** RFC-020 §4.4's model assumed the micrometre-specified blurs could be
banded; at the pixel pitch this work exists for they are all past the
FIR/IIR crossover and run whole-plane, and after R they run whole-plane
without transposes, so there is nothing left for striping to take. Checked
across every film format the wire reaches — 4 mm to 200 mm at 102 MP — and no
stage flips: halation's *bounce* sigma is 65 µm, still 3.8 px at 200 mm, and
the coupler tail is 32 px there.

So RFC-020 §7's contract has no counterparty. The striped executor stays on
the `class-i` branch, unshipped, as the basis for a separate iOS port; it is
not deleted and it is not merged.

This file keeps the number so that RFC-020's references resolve to an
explanation rather than to nothing.

---

## 1. Why a button

Three releases shipped in one day. A user who installed 1.0.1 has no way to
learn that 1.0.3 exists: there is no update mechanism, no mailing list, and
the app never contacts anything. The gap is not "the app cannot update
itself" — it is that **the app cannot say a newer build exists**, which is a
much smaller problem and has a much smaller answer.

## 2. What it does

One row in Settings ▸ This session: **Check for updates**, and beside it
whatever the last check concluded.

1. `GET https://api.github.com/repos/JamesQiu2005/SpektraLab/releases/latest`,
   unauthenticated.
2. Read `tag_name`, which is `spektralab-vX.Y.Z` by this project's convention,
   and compare its `X.Y.Z` against `CFBundleShortVersionString` numerically,
   field by field — not as strings, because `1.0.10` must beat `1.0.9`.
3. Say one of: **a newer version is available (1.0.4)**, with a button that
   opens the release page in the browser; **this is the newest release**; or
   **could not check** with the reason.

That is the whole feature.

## 3. What it deliberately is not

**Not a self-updater, and this is a licensing fact rather than a preference.**
The app is ad-hoc signed and not notarised, by the user's standing decision
not to pay for a Developer ID. A build downloaded by the app would carry the
quarantine attribute and macOS would refuse it exactly as it refuses the zip
today — so an in-app updater would have to talk the user through
`xattr -d -r com.apple.quarantine` regardless, at which point it has saved
them nothing over a link. Sparkle is out for the same reason, not because of
its EdDSA signing, which would work fine.

**Not automatic, and not at launch.** Every release note this project has
published says *"the app asks for no network access at any point"*. That
sentence is true today and an automatic check would silently make it false.
A button is a request the user made; a background check is one they did not.
**When this ships, that sentence in the release notes changes** to say the app
makes no network request unless the button is pressed — and the sentence has
to change in the same release, not afterwards.

**Not telemetry.** The request carries no identifier and no version; it is a
public, unauthenticated read of a public endpoint. What GitHub learns is an IP
address asking about a public repository, which is what a browser visiting the
releases page would tell it. The caption under the button says that, because a
network request in an app that otherwise makes none deserves a sentence.

## 4. The failure modes, which are most of the work

A check that cannot succeed must not look like a check that succeeded. The
failure mode to design against is **"could not reach GitHub" rendering as
"you are up to date"**, which is this repository's recurring shape: a guard
that reports the safe answer when it has learned nothing.

- **Offline / DNS failure / timeout.** Say *could not check*, with the reason.
  A short timeout (5 s) so the button does not hang the page.
- **Rate limited.** Unauthenticated GitHub allows 60 requests an hour per IP.
  A user pressing a button cannot reach that alone, but a shared address can.
  `403` with `X-RateLimit-Remaining: 0` gets its own message, because "try
  again later" is actionable and "could not check" is not.
- **No releases, or a tag that does not parse.** Both mean *could not check*,
  not *up to date*. A tag naming convention is a convention, and this project
  has already had one tag sorted wrongly by `tail -1`.
- **A newer tag that is a prerelease.** `releases/latest` excludes prereleases
  by GitHub's own definition, which is the behaviour wanted: `spektralab-v0.3.1`
  is marked prerelease and must never be offered to a 1.0.3 user.

Each failure path must be reachable in a test. The rate-limit and unparseable
-tag cases are reachable by injecting the response, and the test that matters
is that **none of them ever produces the "newest release" string**.

## 5. What it costs

One `URLSession` call behind a button, a version comparator, four strings, and
an `NSWorkspace.open`. No new dependency, no background task, no persisted
state beyond the last result for the current session.

## 6. Open question

**Whether the button should also appear in the About panel**, which is where a
user looking for a version number already is. Settings ▸ This session already
shows the app and engine versions, so the button belongs beside them; the
About panel is where somebody who has never opened Settings would look. Cheap
either way; not decided here.
