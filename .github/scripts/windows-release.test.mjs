import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { test } from 'node:test';
import { checkExistingRelease, releaseInfo } from './windows-release.mjs';

test('independent Windows tag and short title require all application versions to agree', () => {
  const root = mkdtempSync(join(tmpdir(), 'spk-release-'));
  try {
    mkdirSync(join(root, 'desktop/src-tauri'), { recursive: true });
    const version = '1.3.4-beta.3';
    writeFileSync(join(root, 'desktop/package.json'), JSON.stringify({ version }));
    writeFileSync(join(root, 'desktop/package-lock.json'), JSON.stringify({ version, packages: { '': { version } } }));
    writeFileSync(join(root, 'desktop/src-tauri/tauri.conf.json'), JSON.stringify({ version }));
    for (const path of ['Cargo.toml', 'Cargo.lock']) writeFileSync(join(root, 'desktop/src-tauri', path), 'name = "spektralab"\nversion = "' + version + '"\n');
    assert.deepEqual(releaseInfo(root), { version, tag: 'spektralab-windows-v1.3.4-beta.3', title: 'beta.3' });
    writeFileSync(join(root, 'desktop/src-tauri/tauri.conf.json'), '{"version":"1.3.4"}');
    assert.throws(() => releaseInfo(root), /versions disagree/);
    writeFileSync(join(root, 'desktop/package.json'), '{"version":"1.3.4"}');
    assert.throws(() => releaseInfo(root), /explicit Windows prerelease/);
  } finally {
    assert.ok(resolve(root).startsWith(resolve(tmpdir()) + sep + 'spk-release-'));
    rmSync(root, { recursive: true });
  }
});

const commit = 'a'.repeat(40), hash = 'b'.repeat(64);
const hashes = new Map([['app.zip', hash]]);
test('published versions cannot be overwritten', () => {
  assert.throws(() => checkExistingRelease({ draft: false, target_commitish: commit, assets: [] }, commit, hashes), /already public/);
});
test('a draft from another commit cannot be reused', () => {
  assert.throws(() => checkExistingRelease({ draft: true, target_commitish: 'c'.repeat(40), assets: [] }, commit, hashes), /another source commit/);
});
test('resume accepts matching uploads and rejects changed or unexpected files', () => {
  const draft = { draft: true, target_commitish: commit, assets: [{ name: 'app.zip', digest: 'sha256:' + hash }] };
  assert.doesNotThrow(() => checkExistingRelease(draft, commit, hashes));
  assert.throws(() => checkExistingRelease({ ...draft, assets: [{ name: 'app.zip', digest: 'sha256:other' }] }, commit, hashes), /different assets/);
  assert.throws(() => checkExistingRelease({ ...draft, assets: [{ name: 'other.zip', digest: 'sha256:' + hash }] }, commit, hashes), /different assets/);
});

