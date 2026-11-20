import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export function verifiedWindowsRuntimeNotices(repo, version) {
  const sha256 = (data) => createHash('sha256').update(data).digest('hex');
  const pin = JSON.parse(readFileSync(join(repo, 'license/windows-v2-runtime-notices.json'), 'utf8'));
  for (const [path, expected] of Object.entries(pin.locks)) {
    const text = readFileSync(join(repo, path), 'utf8').replaceAll('\r\n', '\n').replaceAll(version, pin.baseline_version);
    if (sha256(text) !== expected) throw Error('Dependency notices need an audit: ' + path);
  }
  const archive = join(repo, 'license/windows-v2-runtime-notices.zip');
  if (sha256(readFileSync(archive)) !== pin.archive_sha256) throw Error('Dependency notice archive changed');
  return archive;
}
