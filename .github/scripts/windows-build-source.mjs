import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function windowsBuildSource(repo) {
  const git = (args, env = process.env) => execFileSync('git', args, {
    cwd: repo, encoding: 'utf8', env, windowsHide: true,
  }).trim();
  const commit = git(['rev-parse', 'HEAD']);
  const committedTree = git(['rev-parse', commit + '^{tree}']);
  const directory = mkdtempSync(join(tmpdir(), 'spk-source-'));
  const index = join(directory, 'index');
  const env = { ...process.env, GIT_INDEX_FILE: index };
  try {
    git(['read-tree', commit], env);
    git(['add', '-A', '--', '.'], env);
    const sourceTree = git(['write-tree'], env);
    return { commit, sourceTree, dirty: sourceTree !== committedTree };
  } finally {
    rmSync(index, { force: true });
    rmSync(index + '.lock', { force: true });
    rmdirSync(directory);
  }
}

export const hostSha256 = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');

export function verifyWindowsBuild(record, source, version, host) {
  if (!record || record.schema !== 1 || record.version !== version ||
      record.commit !== source.commit || record.sourceTree !== source.sourceTree || record.dirty !== source.dirty) {
    throw Error('Installed build source does not match this checkout and version');
  }
  if (record.hostSha256 !== hostSha256(host)) throw Error('Installed render host does not match its build record');
}
