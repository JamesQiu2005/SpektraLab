# vendor/spklib -- the library helper, built elsewhere

`spklib-host` is SpektraLab's library helper (API-SPEC-library-helper.md). Its source is the
SpektraLab_library repository (MIT, `LICENSE` here), not this one: this folder carries only the built
binary, its SHA-256 and a note of what it was built from. There is no source copy here, on purpose.

| folder | binary | from |
|---|---|---|
| `windows-x64/` | `spklib-host.exe`, `spklib-host.exe.sha256`, `VERSION` | SpektraLab_library branch `windows/cross-compile-2026-11-17-on-0.4.0` @ `85d52813e2e8` (0.4.0 + Windows) |
| `macos/` (on the Mac line, `origin/main`) | `spklib-host`, `spklib-host.sha256` | SpektraLab_library tag `v0.4.0` (`f4aced8`) |

Both are spklib 0.4.0 (schema 3, ABI 1): the Windows branch is the published `main` @ `f4aced84` with
the Windows work re-applied on it. A library made on either platform opens on the other.

## Rebuilding the Windows helper

On a Mac (or Linux) with llvm-mingw (UCRT):

```sh
git clone <SpektraLab_library> spklib && cd spklib
git checkout windows/cross-compile-2026-11-17-on-0.4.0   # 85d52813e2e8
LLVM_MINGW=/path/to/llvm-mingw-20261020-ucrt-macos-universal ./build.sh windows-x64-release
cp build/release-windows-x64/spklib-host.exe build/release-windows-x64/spklib-host.exe.sha256 \
   <SpektraLab>/vendor/spklib/windows-x64/
```

`windows-x64-release` refuses uncommitted sources, writes the commit into the version
(`0.4.0+85d52813e2e8`), builds without debug info, links with `-static` and
`-Wl,--no-insert-timestamp`, and strips. It is reproducible: the same commit and toolchain give the
same bytes, so `spklib-host.exe.sha256` can be checked by rebuilding (the crate's `gate.sh` does).
Then update `VERSION` and `API-SPEC-library-helper.md`'s header in the same commit.

Building and testing the SDK itself, the Windows path rules and the checklist for a Windows machine:
the repository's `docs/WINDOWS.md`. The Rust client that starts this binary is
`desktop/crates/spk-library` (its `README.md` is the app's contract).

## Status

The original build was inspected on macOS (PE32+ x86-64, system DLL imports). The vendored helper has
since run on Windows with SpektraLab. Installation verifies the executable hash, packaged version
notice and the version, ABI and schema reported by the running helper. Local library tests use
SpektraLab catalogs and synthetic Capture One fixtures. A real Capture One 16.9.1.3943 Pro
Windows catalog with managed and referenced RAWs passed read-only browsing, external relinking, and reopening.

The public SDK checkout at f4aced84 still contains the macOS build script. The Windows branch and
85d52813e2e8 were unavailable in the public repository when checked on 2026-11-21. Independent
reproduction requires access to that exact source and the pinned llvm-mingw toolchain. The 670 checks
reported for the original Windows port were run on macOS.
