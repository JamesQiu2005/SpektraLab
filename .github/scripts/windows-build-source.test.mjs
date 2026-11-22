import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { hostSha256, verifyWindowsBuild, windowsBuildSource } from './windows-build-source.mjs';
import { verifyWindowsHostArtifact, writeWindowsHostArtifact } from './windows-host-artifact.mjs';

test('Windows build records pin current source and host without changing the Git index', () => {
  const repo = mkdtempSync(join(tmpdir(), 'spk-source-test-'));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', windowsHide: true }).trim();
  try {
    git('init', '--quiet');
    writeFileSync(join(repo, '.gitignore'), 'ignored.exe\n');
    const source = join(repo, 'camera.txt');
    writeFileSync(source, 'original\n');
    git('add', '--', '.');
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'fixture');
    const clean = windowsBuildSource(repo);
    assert.equal(clean.sourceTree, git('rev-parse', 'HEAD^{tree}'));
    assert.equal(clean.dirty, false);
    writeFileSync(source, 'staged\n');
    git('add', source);
    writeFileSync(source, 'built\n');
    writeFileSync(join(repo, 'new-source.txt'), 'new code\n');
    const host = join(repo, 'ignored.exe');
    writeFileSync(host, 'built host');
    const index = readFileSync(join(repo, '.git/index'));
    const captured = windowsBuildSource(repo);
    assert.equal(captured.commit, clean.commit);
    assert.equal(captured.dirty, true);
    assert.notEqual(captured.sourceTree, clean.sourceTree);
    assert.deepEqual(readFileSync(join(repo, '.git/index')), index);
    const record = { schema: 1, version: '2.0.0-alpha.1', ...captured, hostSha256: hostSha256(host) };
    verifyWindowsBuild(record, captured, record.version, host);
    assert.throws(() => verifyWindowsBuild(record, clean, record.version, host), /build source/);
    writeFileSync(host, 'different host');
    assert.equal(windowsBuildSource(repo).sourceTree, captured.sourceTree);
    assert.throws(() => verifyWindowsBuild(record, captured, record.version, host), /render host/);
    writeFileSync(source, 'edited since build\n');
    assert.notEqual(windowsBuildSource(repo).sourceTree, captured.sourceTree);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test('a staged Windows host must come from the same commit with the same file set and bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'spk-host-artifact-test-'));
  const commit = 'a'.repeat(40);
  try {
    mkdirSync(join(root, 'engine'));
    const host = join(root, 'spektralab-host.exe');
    const icc = join(root, 'engine', 'sRGB.icc');
    writeFileSync(host, 'test executable');
    writeFileSync(icc, 'test profile');
    assert.throws(() => verifyWindowsHostArtifact(root, commit), /missing its artifact record/);
    writeWindowsHostArtifact(root, commit);
    verifyWindowsHostArtifact(root, commit);
    assert.throws(() => verifyWindowsHostArtifact(root, 'b'.repeat(40)), /not from this checkout/);
    writeFileSync(host, 'different executable');
    assert.throws(() => verifyWindowsHostArtifact(root, commit), /differs at spektralab-host.exe/);
    writeFileSync(host, 'test executable');
    writeFileSync(icc, 'different profile');
    assert.throws(() => verifyWindowsHostArtifact(root, commit), /differs at engine\/sRGB.icc/);
    rmSync(icc);
    assert.throws(() => verifyWindowsHostArtifact(root, commit), /differs at engine\/sRGB.icc/);
    writeFileSync(icc, 'test profile');
    writeFileSync(join(root, 'engine', 'extra.bin'), 'extra resource');
    assert.throws(() => verifyWindowsHostArtifact(root, commit), /differs at engine\/extra.bin/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
