# vendor/spklib -- the library helper, built elsewhere

`spklib-host` is SpektraLab's library helper (API-SPEC-library-helper.md). Its source is the
SpektraLab_library repository (MIT, `LICENSE` here), not this one: this folder carries only the built
binary, its SHA-256 and a note of what it was built from. There is no source copy here, on purpose.

| folder | binary | from |
|---|---|---|
| `windows-x64/` | `spklib-host.exe`, `spklib-host.exe.sha256`, `VERSION` | SpektraLab_library branch `windows/cross-compile-2026-11-17` @ `e3c3f1275f5c` (0.3.1 + Windows) |
| `macos/` (on the Mac line, `origin/main`) | `spklib-host`, `spklib-host.sha256` | SpektraLab_library tag `v0.4.0` (`f4aced8`) |

The two are not the same version: the Mac app ships 0.4.0 (`variant.delete`, variant-level filter
keys), the Windows helper is 0.3.1, the newest the Windows work was carried onto. A 0.4.0 call answers
`unknown_method` on Windows until the Windows branch is merged forward again (0.4.0 is additions only:
schema 3, ABI 1, so the libraries are the same).

## Rebuilding the Windows helper

On a Mac (or Linux) with llvm-mingw (UCRT):

```sh
git clone <SpektraLab_library> spklib && cd spklib
git checkout windows/cross-compile-2026-11-17          # e3c3f1275f5c
LLVM_MINGW=/path/to/llvm-mingw-20261020-ucrt-macos-universal ./build.sh windows-x64-release
cp build/release-windows-x64/spklib-host.exe build/release-windows-x64/spklib-host.exe.sha256 \
   <SpektraLab>/vendor/spklib/windows-x64/
```

`windows-x64-release` refuses uncommitted sources, writes the commit into the version
(`0.3.1+e3c3f1275f5c`), builds without debug info, links with `-static` and
`-Wl,--no-insert-timestamp`, and strips. It is reproducible: the same commit and toolchain give the
same bytes, so `spklib-host.exe.sha256` can be checked by rebuilding (the crate's `gate.sh` does).
Then update `VERSION` and `API-SPEC-library-helper.md`'s header in the same commit.

Building and testing the SDK itself, the Windows path rules and the checklist for a Windows machine:
the repository's `docs/WINDOWS.md`. The Rust client that starts this binary is
`desktop/crates/spk-library` (its `README.md` is the app's contract).

## Status

Built and inspected here (PE32+ x86-64, imports system DLLs only, the version string carries the
commit). **Never run**: no Windows, Wine or Windows VM was used, and no Capture One for Windows catalog
has been read by it. The same sources, built for macOS, pass the SDK's 560 checks and the Rust client's
tests.
