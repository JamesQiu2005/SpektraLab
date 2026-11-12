# Windows releases

Windows has an independent prerelease line. For example:

- App / npm / Tauri / Cargo version: `1.3.4-beta.3`
- GitHub tag: `spektralab-windows-v1.3.4-beta.3`
- Release title: `beta.3`

Keep the title short. Put changes, validation and limitations in
`desktop/docs/releases/beta.3.md`, not in the title. Never attach a new
Windows build to a macOS release just because the numeric version matches.

## Prepare and check

1. Start from reviewed `Windows_Linux` sources. Update the version in
   `desktop/package.json`, both root entries in `package-lock.json`,
   `src-tauri/tauri.conf.json`, `Cargo.toml` and the app entry in `Cargo.lock`.
   Do not alter dependencies merely to bump the app version.
2. Add the notes named for the short prerelease title.
3. Run the relevant local checks. Pushes and pull requests run the CI checks
   and produce artifacts without publishing a public release.
4. Verify the installed app and portable on a real Windows GPU as well.
   Hosted Windows runners have no Vulkan device. Record what was actually
   tested separately from older camera/performance measurements.

## Publish

On the **Desktop (Linux, Windows)** workflow, select **Windows_Linux** and
explicitly enable **publish_windows**. The default is false. The release job
waits for Linux, Windows cross-build, native MSVC, frontend and both package
jobs. It publishes an independent Windows prerelease without changing
GitHub's Latest macOS release.

The Windows package job stages a portable from the same installed app that
passed the install check, checks its host and packages the whole directory.
The publisher checks version agreement and portable source identity, creates
the corresponding source ZIP, SHA-256 file and build manifest, uploads to a
draft, and only makes it public after verifying all uploaded digests.

A published version cannot be replaced. A retry can resume only a draft
whose source commit and existing file digests match exactly. To fix a public
binary, use a new prerelease number. Do not move its tag or use
`gh release upload --clobber`.

Keep beta.2 and older releases available for rollback. Update download links
when publishing a new milestone, rather than silently replacing an old
release's installer.

