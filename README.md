# SpektraLab for Windows

**English** · [简体中文](README.zh-CN.md) · [macOS project](https://github.com/JamesQiu2005/SpektraLab/tree/main)

SpektraLab simulates film and photographic paper. The Windows v2 app uses a native Vulkan engine and has Library, Develop and Edit workspaces. A separate library helper stores catalogs and edits.

Windows v2 is under development. The published Windows 1.x installer and portable ZIP are available from the [Windows beta.3 release](https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-windows-v1.3.4-beta.3). The v2 test installer and portable app use their own application identity and do not change RAW/TIFF associations. Windows x64, WebView2 and a Vulkan driver are required for real rendering.

- `desktop/` contains the Tauri application, the scheduler and the library client. Run `npm ci`, `npm run check` and `npm run build:web` there.
- `engine/` contains the Vulkan host and image pipeline. See [Windows engine build](engine/WINDOWS.md) and [RAW support](RAW-SUPPORT-20261117.md).
- [Installer instructions](desktop/docs/WINDOWS-INSTALLER.md) cover Windows x64 packaging. Pushes and pull requests targeting `Windows_Linux_v2` run the Windows checks. The manual packaging workflow produces test artifacts without publishing a release.
- [Windows first run checklist](desktop/docs/WINDOWS-V2-CHECKLIST.md), [Windows design](desktop/design/windows/README.md), and [library helper protocol](API-SPEC-library-helper.md) describe the implementation and acceptance tests.

## Credits and licence

The film process model, its 28 measured color profiles and the print LUTs are
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato;
4 new measured B&W profiles are by Hanze Qiu;
SpektraLab for Windows runs that model in its native C++ Vulkan engine.

| | |
|---|---|
| app and engine | GPL-3.0-or-later |
| film and paper profiles, print LUTs | CC BY-SA 4.0 |

Project and profile notices appear in **About SpektraLab**. Runtime dependency
notices also ship with the packaged files.
