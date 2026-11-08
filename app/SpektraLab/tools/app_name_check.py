#!/usr/bin/env python3
"""Verify the installed/exported app's names, not source keys.

Since 2026-10-22 the name is SpektraLab in every language (the owner: "The initial name is unified
as SpektraLab for all languages as this is the only trademark we hold")."""
import plistlib
import sys
from pathlib import Path

NAME = "SpektraLab"
app = Path(sys.argv[1]).resolve()
bundles = [app]
problems = []
for bundle in bundles:
    try:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        if info.get("CFBundleDisplayName") != NAME:
            problems.append(f"{bundle.name}: fallback display name is not {NAME}")
        if info.get("CFBundleDevelopmentRegion") != "en":
            problems.append(f"{bundle.name}: unsupported languages do not have the English fallback")
        for language in ("en", "zh-Hans", "zh-Hant", "ja"):
            table = plistlib.loads((bundle / f"{language}.lproj/InfoPlist.strings").read_bytes())
            if table.get("CFBundleDisplayName") != NAME:
                problems.append(f"{bundle.name}: {language} display name is not {NAME}")
            for key, value in table.items():
                if "Spek " in value or value.startswith("Spek") and not value.startswith(NAME):
                    problems.append(f"{bundle.name}: {language} {key} still says Spek")
    except (OSError, ValueError) as error:
        problems.append(f"{bundle.name}: incomplete localized metadata ({type(error).__name__})")
if problems:
    sys.exit("FAIL: " + "\n".join(problems))
print(f"PASS: {' and '.join(b.name for b in bundles)} are {NAME} in all bundled languages")
