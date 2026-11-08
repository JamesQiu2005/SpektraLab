#!/usr/bin/env python3
"""Compile the production Catalyst shortcut registry; exercise ownership, aliases and typing guards.
--negative-controls also requires the same checks to reject three deliberate regressions.
"""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
source = (root / 'Sources/Mac/MacShortcuts.swift').read_text()
variants = [('production', source, 0)]
if '--negative-controls' in sys.argv:
    remove = '        entries[owner] = nil\n        order.removeAll { $0 == owner }'
    assert remove in source
    broken = '''        if let removed = entries[owner] {
            for id in order where entries[id]?.specs.contains(where: removed.specs.contains) == true { entries[id] = nil }
        }
        entries[owner] = nil
        order.removeAll { $0 == owner }'''
    variants.append(('broken-unregister-by-key', source.replace(remove, broken), 1))
    modifiers = 'flags = command.modifierFlags.intersection([.command, .alternate, .control, .shift])'
    assert modifiers in source
    variants.append(('broken-modifier-identity', source.replace(modifiers, 'flags = command.modifierFlags.intersection([.shift])'), 1))
    identity = 'propertyList: standard != nil ? nil : spec.input + ":" + String(spec.flags.rawValue)'
    assert identity in source
    variants.append(('broken-menu-identity', source.replace(identity, 'propertyList: nil'), 1))
    # ⌘C as a menu item of its own beside Edit's Copy: a field's ⌘C would be the settings' (2026-11-05).
    standard = '        MacKeySpec(input: "c", flags: .command): #selector(UIResponder.copy(_:)),\n'
    assert standard in source
    variants.append(('broken-copy-not-standard', source.replace(standard, ''), 1))
with tempfile.TemporaryDirectory(prefix='spk-shortcut-check-') as temporary:
    folder = Path(temporary)
    for name, swift, expected in variants:
        implementation = folder / 'MacShortcuts.swift'
        implementation.write_text(swift)
        binary = folder / name
        subprocess.run(['xcrun', 'swiftc', '-target', platform.machine() + '-apple-ios18.0-macabi', '-sdk', sdk,
                        '-F', sdk + '/System/iOSSupport/System/Library/Frameworks', str(implementation),
                        str(root / 'tools/mac_shortcuts_selftest.swift'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        print(name + ':\n' + result.stdout, flush=True)
        if result.returncode != expected:
            sys.stderr.write(result.stderr)
            raise SystemExit(f'{name}: exit {result.returncode}, expected {expected}')
