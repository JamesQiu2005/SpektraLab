#!/usr/bin/env python3
"""gen_project.py -- write SpektraLab.xcodeproj (and its shared scheme) from this file.

    gen_project.py [--team TEAMID] [--bundle-id ID] [--no-engine] [--version 2.2.2] [--build N]
                   [--mac-idiom pad|mac] [--unhardened]

The project is generated rather than kept, so what it builds is readable here and
adding a source file needs no project edit:

  * one Mac Catalyst app target, every `Sources/**/*.swift`, and the bridging header
    `Sources/Support/SpektraLab-Bridging-Header.h` (the engine's C ABI);
  * `Resources/Assets.xcassets`, the Icon Composer document `Resources/SpektraLab.icon`
    (the desktop app's own logo: `actool` compiles it, and
    `ASSETCATALOG_COMPILER_APPICON_NAME` selects it by name), `Resources/StockCatalog.json`,
    `Resources/Supporters.json` (Settings' Supporters);
  * `build/SampleFrames`, the demo library's pictures, copied here from
    `SampleSources/` (the owner's own photographs, already in the repository).

Mac Catalyst is the only destination: the engine is linked for `macosx` alone,
so a build for any other platform does not compile. The default uses scaled
Catalyst metrics; --mac-idiom mac selects native Mac metrics instead.

Without `--team` the app is signed to run locally, which is what `run.sh`,
`tools/snapshot.sh` and an unsigned Release archive need. With `--team` it is
signed automatically with that development team. The app has no entitlements.

**The log's sending** (opt-in, Settings › Diagnostics; `Diagnostics.swift`,
`LogShipping.swift`) is compiled under `SPK_LOG_UPLOAD`: for the debug
configuration always (the log's stand-in server: `tools/logs_receiver.py`),
and for the release one only where this checkout holds `logs.local` beside this
file (ignored by git; two lines, `SPK_LOGS_URL=...` and `SPK_LOGS_KEY=...`).
Where the log is sent is never in the repository: the address and its key are
read from that file alone, and go into the app's Info.plist (`SPKLogsURL`,
`SPKLogsKey`, in `build/Info-logs.plist`, which is `Info.plist` with those two
keys). Without the file no build has an address or a key, and Settings' *Export
Log Zip* is the log's only way out. A debug build may still be pointed at a
stand-in server by its launch (`--logs-endpoint`, `tools/logs_receiver.py`).
`SPKCommit` is empty unless the build supplies a public revision through
`SPK_SOURCE_REVISION`. A private checkout revision is never embedded automatically.

The engine is linked where it has been built: `tools/build_engine_mac.sh`
leaves a static library and an `EngineResources` folder under
`build/engine-macosx/`, and where they are found this target links the library,
sets `SPK_ENGINE` (which compiles `SpkEngine.swift` and the app's engine host)
and copies the folder into the app. Where they are not -- a clean checkout, CI
-- the target is the interface and the scheduler over `SimulatedEngine`;
`--no-engine` builds that on purpose. The kernels are never compiled by Xcode
(AGENTS.md, engine trap 2), so no `.metal` file may be added to this target.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
APP = "SpektraLab"

# The demo library's pictures: (name in the bundle, source under design/src).
# t1 and t4 take the larger plain renders of the same photographs.
SAMPLES = [
    ("feed.jpg", "scene_raw_srgb.jpg"),
    ("bund.jpg", "overscan/plain_bund.jpg"),
    ("street.jpg", "overscan/plain_street.jpg"),
] + [(f"t{i}.jpg", f"thumbs/t{i}.jpg") for i in range(1, 9)]


def oid(name: str) -> str:
    """A stable 24-hex object id per name, so regenerating changes nothing."""
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def prepare_samples() -> None:
    out = HERE / "build" / "SampleFrames"
    out.mkdir(parents=True, exist_ok=True)
    for name, src in SAMPLES:
        # The demo library's pictures, kept beside this file in SampleSources/.
        s = HERE / "SampleSources" / src
        if not s.exists():
            raise SystemExit(f"missing sample picture: {s}")
        d = out / name
        if not d.exists() or d.stat().st_mtime < s.stat().st_mtime:
            shutil.copyfile(s, d)


def logs_endpoint() -> tuple[str, str]:
    """Where this build's log goes, and the key: from `logs.local` beside this file, and from nowhere
    else. Empty, both, where there is no such file: the build sends nothing."""
    kept = {}
    local = HERE / "logs.local"
    if local.exists():
        for line in local.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                kept[k.strip()] = v.strip()
    url, key = kept.get("SPK_LOGS_URL", ""), kept.get("SPK_LOGS_KEY", "")
    if bool(url) != bool(key):
        raise SystemExit("logs.local needs both an address and a key (SPK_LOGS_URL, SPK_LOGS_KEY): one is missing")
    if any(c in url + key for c in '"\\$ \t'):
        raise SystemExit("the log's address and key may hold no quote, backslash, dollar or space")
    return url, key


def logs_info_plist(logs: bool) -> str:
    """The Info.plist this build reads: `Info.plist` itself, or where the build has a log server
    `build/Info-logs.plist`, the same with the log's address and key (the build settings
    `SPK_LOGS_URL`, `SPK_LOGS_KEY`) added."""
    if not logs:
        return "Info.plist"
    text = (HERE / "Info.plist").read_text()
    end = text.rstrip().rfind("</dict>")
    if end < 0:
        raise SystemExit("Info.plist has no closing </dict>")
    keys = ("\t<!-- Where the log is sent, and the key that server asks for (logs.local). -->\n"
            "\t<key>SPKLogsURL</key>\n\t<string>$(SPK_LOGS_URL)</string>\n"
            "\t<key>SPKLogsKey</key>\n\t<string>$(SPK_LOGS_KEY)</string>\n")
    out = HERE / "build" / "Info-logs.plist"
    out.parent.mkdir(parents=True, exist_ok=True)
    made = text[:end] + keys + text[end:]
    if not out.exists() or out.read_text() != made:
        out.write_text(made)
    return "build/Info-logs.plist"


def commit() -> str:
    """An explicitly supplied public revision; private checkout history is never embedded by default."""
    revision = os.environ.get("SPK_SOURCE_REVISION", "")
    if revision and not all(c.isalnum() or c in ".-_+" for c in revision):
        raise SystemExit("SPK_SOURCE_REVISION contains an invalid character")
    return revision


def q(s: str) -> str:
    """Quote a pbxproj string when it needs it."""
    ok = s and all(c.isalnum() or c in "._/" for c in s)
    return s if ok else '"' + s.replace('"', '\\"') + '"'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--team", default=None, help="development team id; omit to sign to run locally")
    ap.add_argument("--bundle-id", default=None)
    ap.add_argument("--no-engine", action="store_true",
                    help="do not link the engine even where tools/build_engine_mac.sh has built it")
    ap.add_argument("--version", default="2.2.2", help="the app's version (CFBundleShortVersionString)")
    ap.add_argument("--build", default="1", help="the build's number (CFBundleVersion): higher for every release")
    ap.add_argument("--update-feed", default="https://spektralab.app/updates/mac.json",
                    help="where Check for Updates reads the latest Mac release's manifest (Info.plist SPKUpdateFeedURL)")
    ap.add_argument("--mac-idiom", choices=("pad", "mac"), default="pad",
                    help="pad (default): scaled Catalyst metrics, the interface at the size it was "
                         "drawn, scaled for the Mac. mac: \"Optimize for Mac\", the Mac idiom, which changes the "
                         "controls' metrics")
    ap.add_argument("--unhardened", action="store_true",
                    help="the diagnosing Release build: do NOT strip the executable's symbol table, so the engine "
                         "and scheduler can be read and debugged. The shipped build (default) strips it. See "
                         "tools/harden.sh")
    args = ap.parse_args()
    logs_url, logs_key = logs_endpoint()
    # The engine, where `tools/build_engine_mac.sh` has left one (`build/engine-macosx`).
    def engine_built() -> bool:
        base = HERE / "build" / "engine-macosx"
        if not (base / "libspektralab_engine.a").exists():
            return False
        # The kernels: engine/build.sh's spektralab.metallib, built with safe math.
        return (base / "EngineResources" / "spektralab.metallib").exists()
    engine = not args.no_engine and engine_built()
    # The Mac app's own id (app/SpektraLab): not the 1.x desktop app's com.hanze.filmify,
    # so neither its preferences nor its library are shared.
    bundle = args.bundle_id or ("com.spektralab.mac." + args.team.lower() if args.team else "com.spektralab.mac.local")

    prepare_samples()

    kinds = {".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h"}
    sources = sorted(p.relative_to(HERE) for p in (HERE / "Sources").rglob("*") if p.suffix in kinds)
    if not any(p.suffix == ".swift" for p in sources):
        raise SystemExit("no Swift sources under Sources/")
    resources = [  # (path relative to HERE, lastKnownFileType)
        ("Resources/Assets.xcassets", "folder.assetcatalog"),
        ("Resources/SpektraLab.icon", "folder.iconcomposer.icon"),
        ("Resources/StockCatalog.json", "text.json"),
        # The people Settings › General › About › Supporters thanks (Model/Supporters.swift).
        ("Resources/Supporters.json", "text.json"),
        # The Digital Intermediate's view: 1.x's Cineon -> ProPhoto 3D LUT, read by Engine/CineonView.swift.
        ("Resources/DIView-Cineon-to-ProPhoto.cube", "text"),
        # What the app reads of the system that Apple asks a reason for.
        ("Resources/PrivacyInfo.xcprivacy", "text.xml"),
        # The app's words in Simplified and Traditional Chinese and Japanese (English is the key),
        # and its name in each: Xcode compiles each catalog into the `.lproj` folders
        # `Localization.swift` and the system read (LOCALIZATION.md).
        ("Resources/Localizable.xcstrings", "text.json.xcstrings"),
        ("Resources/InfoPlist.xcstrings", "text.json.xcstrings"),
        ("build/SampleFrames", "folder"),
    ]
    resources = [(p, k) for p, k in resources if (HERE / p).exists()]

    objects = []   # (id, comment, body)

    def add(key: str, comment: str, body: str) -> str:
        i = oid(key)
        objects.append((i, comment, body))
        return i

    # ---- file references and the group tree ---------------------------------
    build_src, build_res = [], []
    tree: dict = {}
    for p in sources:
        node = tree
        for part in p.parts[:-1]:
            node = node.setdefault(part, {})
        ref = add(f"ref:{p}", p.name,
                  f"{{isa = PBXFileReference; lastKnownFileType = {kinds[p.suffix]}; path = {q(p.name)}; sourceTree = \"<group>\"; }}")
        node[p.name] = ref
        if p.suffix != ".h":   # a header is in the project, not in the compile phase
            build_src.append((add(f"build:{p}", f"{p.name} in Sources", f"{{isa = PBXBuildFile; fileRef = {ref} /* {p.name} */; }}"), p.name))

    def group(name: str, node: dict, path: str, key: str) -> str:
        children = []
        for k in sorted(node, key=lambda s: (not isinstance(node[s], dict), s.lower())):
            v = node[k]
            children.append((group(k, v, k, f"{key}/{k}"), k) if isinstance(v, dict) else (v, k))
        body = ("{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
                + "".join(f"\t\t\t\t{i} /* {n} */,\n" for i, n in children)
                + f"\t\t\t);\n\t\t\tpath = {q(path)};\n\t\t\tsourceTree = \"<group>\";\n\t\t}}")
        return add(f"group:{key}", name, body)

    src_group = group("Sources", tree["Sources"], "Sources", "Sources")

    res_children = []
    for p, kind in resources:
        name = Path(p).name
        ref = add(f"ref:{p}", name,
                  f"{{isa = PBXFileReference; lastKnownFileType = {kind}; name = {q(name)}; path = {q(p)}; sourceTree = \"<group>\"; }}")
        res_children.append((ref, name))
        build_res.append((add(f"build:{p}", f"{name} in Resources", f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}"), name))
    info_ref = add("ref:Info.plist", "Info.plist",
                   "{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }")
    app_ref = add("app", f"{APP}.app",
                  f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }}")
    products = add("products", "Products",
                   f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_ref} /* {APP}.app */,\n"
                   + "\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}")
    main_children = ([(src_group, "Sources")] + res_children
                     + [(info_ref, "Info.plist"), (products, "Products")])
    main_group = add("main", "main",
                     "{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
                     + "".join(f"\t\t\t\t{i} /* {n} */,\n" for i, n in main_children)
                     + "\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}")

    # ---- build phases --------------------------------------------------------
    def phase(key: str, isa: str, files) -> str:
        return add(key, isa.replace("PBX", "").replace("BuildPhase", ""),
                   f"{{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
                   + "".join(f"\t\t\t\t{i} /* {n} */,\n" for i, n in files)
                   + "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}")

    ph_src = phase("phase_sources", "PBXSourcesBuildPhase", build_src)
    ph_fw = phase("phase_frameworks", "PBXFrameworksBuildPhase", [])
    ph_res = phase("phase_resources", "PBXResourcesBuildPhase", build_res)
    # The engine's resources are the build's own (`build/engine-$PLATFORM_NAME`, macosx for a Mac
    # Catalyst build), so they are copied by a script that reads `PLATFORM_NAME`, not listed as a folder.
    ph_engine = None
    if engine:
        script = ('src=\\"$PROJECT_DIR/build/engine-$PLATFORM_NAME/EngineResources\\"\\n'
                  'dst=\\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/EngineResources\\"\\n'
                  'if [ -d \\"$src\\" ]; then mkdir -p \\"$dst\\" && rsync -a --delete \\"$src/\\" \\"$dst/\\"; '
                  'else rm -rf \\"$dst\\"; fi\\n'
                  # The Mac: the 2.0 library helper (vendor/spklib, API-SPEC-library-helper.md) in
                  # Contents/Helpers, signed with the app's identity and the hardened runtime before the
                  # app is sealed (modern_UI's Tools/sign-library-helper.sh says why).
                  'if [ \\"$PLATFORM_NAME\\" = macosx ]; then h=\\"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers\\"; '
                  'mkdir -p \\"$h\\" && cp -f \\"$PROJECT_DIR/../../vendor/spklib/macos/spklib-host\\" \\"$h/\\" && '
                  'codesign --force --options runtime --timestamp=none --sign \\"${EXPANDED_CODE_SIGN_IDENTITY:--}\\" \\"$h/spklib-host\\"; fi\\n')
        ph_engine = add("phase_engine", "Engine resources",
                        "{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n"
                        "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
                        "\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n"
                        "\t\t\tname = \"Engine resources\";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n"
                        "\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
                        "\t\t\tshellPath = /bin/sh;\n"
                        f"\t\t\tshellScript = \"{script}\";\n\t\t}}")

    # ---- settings ------------------------------------------------------------
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "CLANG_ENABLE_OBJC_ARC": "YES",
    }
    proj_debug = dict(common, ONLY_ACTIVE_ARCH="YES", SWIFT_OPTIMIZATION_LEVEL='"-Onone"',
                      DEBUG_INFORMATION_FORMAT="dwarf", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG",
                      ENABLE_TESTABILITY="YES")
    proj_release = dict(common, SWIFT_OPTIMIZATION_LEVEL='"-O"', SWIFT_COMPILATION_MODE="wholemodule",
                        DEBUG_INFORMATION_FORMAT='"dwarf-with-dsym"', VALIDATE_PRODUCT="YES")
    if not args.unhardened:
        # Hardened Release (the default, the shipped build): strip the final executable's whole symbol
        # table at build time, so it carries no engine C++/ABI name and no scheduler Swift name. The
        # dSYM is generated first (DEBUG_INFORMATION_FORMAT above) and kept, so crash reports still
        # symbolicate from it (tools/harden.sh). `--unhardened` keeps the symbols so
        # the engine and scheduler can be read while diagnosing. Debug builds are never stripped.
        proj_release.update(
            DEPLOYMENT_POSTPROCESSING="YES",
            STRIP_INSTALLED_PRODUCT="YES",
            STRIP_STYLE="all",
            DEAD_CODE_STRIPPING="YES",
            COPY_PHASE_STRIP="NO",
        )
    target = {
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "PRODUCT_BUNDLE_IDENTIFIER": bundle,
        # Mac Catalyst is the one destination. The device family is what a Catalyst target is made
        # from; on the Mac, 2 alone is "scaled Catalyst mode" and 2,6 "Optimize for Mac".
        "TARGETED_DEVICE_FAMILY": "2",
        '"TARGETED_DEVICE_FAMILY[sdk=macosx*]"': '"2,6"' if args.mac_idiom == "mac" else "2",
        # The desktop app's floor (macOS 15), which the engine's metallib is stamped for.
        '"IPHONEOS_DEPLOYMENT_TARGET[sdk=macosx*]"': "18.0",
        "SUPPORTS_MACCATALYST": "YES",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        # A build with a log server has the log's two keys besides (`logs_info_plist`).
        "INFOPLIST_FILE": logs_info_plist(bool(logs_url)),
        # One name in every language (the owner, 2026-10-22: "The initial name is unified as
        # SpektraLab for all languages as this is the only trademark we hold"); InfoPlist.xcstrings
        # says it again per language, and tools/app_name_check.py holds both.
        "INFOPLIST_KEY_CFBundleDisplayName": "SpektraLab",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        # The Mac window is resizable; no device-orientation metadata is needed.
        "INFOPLIST_KEY_UIUserInterfaceStyle": "Dark",
        "INFOPLIST_KEY_UIStatusBarStyle": "UIStatusBarStyleLightContent",
        "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": APP,
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CURRENT_PROJECT_VERSION": args.build,
        "MARKETING_VERSION": args.version,
        # The app has no cryptography of its own. A build with a log server sends its log over the
        # system's HTTPS (exempt). NO in every build.
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        # Read by Info.plist: the commit this build is of.
        "SPK_COMMIT": q(commit()) or '""',
        "SPK_UPDATE_FEED_URL": q(args.update_feed),
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
        "ENABLE_PREVIEWS": "NO",
        "SWIFT_OBJC_BRIDGING_HEADER": '"Sources/Support/SpektraLab-Bridging-Header.h"',
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        # The engine's C header (engine/include/spektralab/spk_engine.h), which the bridging header
        # includes in every build: a declaration costs nothing where the library is not linked, and
        # nothing calls it there.
        "HEADER_SEARCH_PATHS": '("$(PROJECT_DIR)/../../engine/include")',
    }
    if logs_url:
        # Read by build/Info-logs.plist: where the log goes (logs.local). No other build has them.
        target["SPK_LOGS_URL"] = q(logs_url)
        target["SPK_LOGS_KEY"] = q(logs_key)
    if engine:
        # The archive, the C++ runtime, and the frameworks the engine calls (the film edge sets its
        # type through CoreText). Under `sdk=macosx` alone: no other platform links an engine.
        target['"OTHER_LDFLAGS[sdk=macosx*]"'] = (
            '("$(inherited)", "$(PROJECT_DIR)/build/engine-macosx/libspektralab_engine.a", "-lc++", '
            '"-framework", Metal, "-framework", QuartzCore, "-framework", CoreText, "-framework", CoreGraphics, '
            '"-framework", Accelerate)')
        target['"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]"'] = '"$(inherited) SPK_ENGINE"'
    conditions = []
    # The log's sending (`Diagnostics.swift`, `LogShipping.swift`): a debug build's, for its checks, and
    # a release build's only where it has a log server (logs.local). Set per configuration below.
    release_conditions = conditions + (["SPK_LOG_UPLOAD"] if logs_url else [])
    debug_conditions = conditions + ["SPK_LOG_UPLOAD"]
    if release_conditions:
        target["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"$(inherited) ' + " ".join(release_conditions) + '"'
    if args.team:
        target["DEVELOPMENT_TEAM"] = args.team
        target["CODE_SIGN_STYLE"] = "Automatic"
    else:
        target["CODE_SIGN_STYLE"] = "Manual"
        target["CODE_SIGN_IDENTITY"] = '"-"'

    def settings(d: dict) -> str:
        return "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(d.items()))

    def cfg(key: str, name: str, d: dict) -> str:
        return add(key, name, f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(d)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}}")

    pd, pr = cfg("proj_debug", "Debug", proj_debug), cfg("proj_release", "Release", proj_release)
    target_debug = dict(target)
    target_debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"$(inherited) ' + " ".join(debug_conditions) + '"'
    td, tr = cfg("tgt_debug", "Debug", target_debug), cfg("tgt_release", "Release", target)

    def cfg_list(key: str, what: str, a: str, b: str) -> str:
        return add(key, f"Build configuration list for {what}",
                   f"{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{a} /* Debug */,\n\t\t\t\t{b} /* Release */,\n\t\t\t);\n"
                   "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}")

    cl_proj = cfg_list("cfg_project", f'PBXProject "{APP}"', pd, pr)
    cl_tgt = cfg_list("cfg_target", f'PBXNativeTarget "{APP}"', td, tr)

    tgt = add("target", APP,
              f"{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {cl_tgt};\n\t\t\tbuildPhases = (\n"
              f"\t\t\t\t{ph_src} /* Sources */,\n\t\t\t\t{ph_fw} /* Frameworks */,\n\t\t\t\t{ph_res} /* Resources */,\n"
              + (f"\t\t\t\t{ph_engine} /* Engine resources */,\n" if ph_engine else "")
              + "\t\t\t);\n"
              f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n"
              + f"\t\t\t);\n\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n"
              f"\t\t\tproductReference = {app_ref} /* {APP}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}}")
    proj = add("project", "Project object",
               "{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
               "\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t};\n"
               f"\t\t\tbuildConfigurationList = {cl_proj};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
               "\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\t\"zh-Hans\",\n\t\t\t\t\"zh-Hant\",\n\t\t\t\tja,\n\t\t\t);\n"
               f"\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products} /* Products */;\n"
               f"\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{tgt} /* {APP} */,\n"
               + "\t\t\t);\n\t\t}")

    body = "".join(f"\t\t{i} /* {c} */ = {b};\n" for i, c, b in sorted(objects, key=lambda o: o[0]))
    pbx = ("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"
           + body + f"\t}};\n\trootObject = {proj} /* Project object */;\n}}\n")

    out = HERE / f"{APP}.xcodeproj"
    out.mkdir(exist_ok=True)
    (out / "project.pbxproj").write_text(pbx)

    scheme_dir = out / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    ref = (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{tgt}" '
           f'BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj">'
           f'</BuildableReference>')
    (scheme_dir / f"{APP}.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")
    host = (logs_url.split("//", 1)[-1].split("/", 1)[0] if logs_url
            else "none: no logs.local, so the release build has no sending compiled (only a debug build's checks do)")
    print(f"wrote {out} ({len(sources)} sources, bundle id {bundle}, team {args.team or 'none: signed to run locally'}, "
          f"engine {'macosx' if engine else 'not linked'}, version {args.version} ({args.build}), log server {host})")


if __name__ == "__main__":
    main()
