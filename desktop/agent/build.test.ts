import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const catalogPath = 'modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

describe('standalone CLI build', () => {
  it.each(['missing', 'stale'])('uses the tracked catalog with %s web assets', (assets) => {
    // Keep the fixture beneath desktop so the real esbuild dependency resolves,
    // without changing or relying on the checkout's generated public/assets.
    const root = mkdtempSync(join(desktop, '.agent-build-test-'));
    try {
      const fixture = join(root, 'desktop');
      mkdirSync(join(fixture, 'scripts'), { recursive: true });
      for (const path of ['agent', 'src', 'tsconfig.base.json', 'scripts/build-agent.mjs']) {
        cpSync(join(desktop, path), join(fixture, path), { recursive: true });
      }
      const catalog = join(root, catalogPath);
      mkdirSync(dirname(catalog), { recursive: true });
      cpSync(resolve(desktop, '..', catalogPath), catalog);
      if (assets === 'stale') {
        mkdirSync(join(fixture, 'public/assets'), { recursive: true });
        writeFileSync(join(fixture, 'public/assets/StockCatalog.json'), '{"stocks":[]}');
      }
      const output = join(root, 'CLI 输出');
      const result = spawnSync(process.execPath, [join(fixture, 'scripts/build-agent.mjs'), output], {
        cwd: root, encoding: 'utf8', windowsHide: true,
      });
      expect(result.status, result.error?.message ?? result.stderr).toBe(0);
      expect(readFileSync(join(output, 'agents/StockCatalog.json')).equals(readFileSync(catalog)),
        'the bundled catalog must match the tracked source byte for byte').toBe(true);
      expect(execFileSync(process.execPath, [join(output, 'agents/agent.mjs'), '--help'], {
        encoding: 'utf8', windowsHide: true,
      })).toContain('SpektraLab CLI:');
      if (assets === 'missing') expect(existsSync(join(fixture, 'public/assets'))).toBe(false);
    } finally {
      // root is the unique fixture directory created above, never a source path.
      rmSync(root, { recursive: true, force: true });
    }
  });
});
