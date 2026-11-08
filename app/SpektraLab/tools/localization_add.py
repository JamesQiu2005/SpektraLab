#!/usr/bin/env python3
"""localization_add.py -- put translations into the string catalog.

    tools/localization_add.py FILE [--catalog Resources/Localizable.xcstrings]
    tools/localization_add.py --language ja FILE [--catalog Resources/Localizable.xcstrings]

FILE holds one sentence in four lines -- its English exactly as `tools/localization_check.py
--list-missing` prints the key (a JSON string, or the bare text where it has no quote, backslash or
line break in it), its Simplified, its Traditional, its Japanese -- and a blank line between sentences:

    Settings
    设置
    設定
    設定

    "%@ frames"
    %@ 张
    %@ 張
    %@枚

With `--language CODE` each sentence is two lines, its key and that one language's translation, and
the key's other languages are kept as they are: how one language is added to keys that have the others.

`\\n` in a translation is a line break. A key the catalog already has is replaced (with `--language`,
only that language of it). The catalog is written with its keys in order, so a change to it is a
change to the lines it touches.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ORDER = ("zh-Hans", "zh-Hant", "ja")


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> int:
    argv = sys.argv[1:]
    catalog = HERE / "Resources" / "Localizable.xcstrings"
    only = None
    if "--catalog" in argv:
        i = argv.index("--catalog")
        catalog = Path(argv[i + 1])
        del argv[i:i + 2]
    if "--language" in argv:
        i = argv.index("--language")
        only = argv[i + 1]
        del argv[i:i + 2]
    files = [a for a in argv if not a.startswith("--")]
    text = catalog.read_text() if catalog.exists() else ""
    data = json.loads(text) if text else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    want = 2 if only else 1 + len(ORDER)
    added = replaced = 0
    for source in files:
        blocks = [b for b in Path(source).read_text().split("\n\n") if b.strip()]
        for block in blocks:
            lines = [l for l in block.split("\n") if l.strip() and not l.startswith("#")]
            if len(lines) != want:
                raise SystemExit(f"{source}: a sentence is {want} lines, this is {len(lines)}: {block!r}")
            key = json.loads(lines[0]) if lines[0].startswith('"') else lines[0]
            values = [l.replace("\\n", "\n") for l in lines[1:]]
            entry = data["strings"].get(key)
            if entry is not None:
                replaced += 1
            else:
                added += 1
                entry = {"localizations": {}}
            localizations = dict(entry.get("localizations", {})) if only else {}
            for language, value in zip((only,) if only else ORDER, values):
                localizations[language] = unit(value)
            entry["localizations"] = dict(sorted(localizations.items()))
            data["strings"][key] = entry
    data["strings"] = dict(sorted(data["strings"].items()))
    # As Xcode writes a catalog: two spaces, " : ", keys sorted, no escaping of what is not ASCII. A
    # file that ended without a line break (InfoPlist.xcstrings) is left so.
    out = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    catalog.write_text(out + ("\n" if not text or text.endswith("\n") else ""))
    print(f"{catalog.name}: {added} added, {replaced} replaced, {len(data['strings'])} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
