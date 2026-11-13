// Publish only an explicitly requested, complete and immutable Windows release.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function releaseInfo(root) {
  const json = (path) => JSON.parse(readFileSync(join(root, path), 'utf8'));
  const version = json('desktop/package.json').version;
  if (!/^\d+\.\d+\.\d+-(?:alpha|beta|rc)\.\d+$/.test(version)) throw Error('Expected an explicit Windows prerelease version');
  const lock = json('desktop/package-lock.json');
  const versions = [json('desktop/src-tauri/tauri.conf.json').version, lock.version, lock.packages[''].version];
  for (const path of ['Cargo.toml', 'Cargo.lock']) {
    const text = readFileSync(join(root, 'desktop/src-tauri', path), 'utf8');
    const match = text.match(/(?:^|\n)name = "spektralab"\r?\nversion = "([^"]+)"/);
    if (!match) throw Error('Cannot read application version from ' + path);
    versions.push(match[1]);
  }
  if (versions.some((value) => value !== version)) throw Error('Application and lockfile versions disagree');
  return { version, tag: 'spektralab-windows-v' + version, title: version.split('-')[1] };
}

export function checkExistingRelease(release, commit, hashes) {
  if (!release.draft) throw Error('Release is already public; publish a new version instead of replacing it');
  if (release.target_commitish !== commit) throw Error('Draft belongs to another source commit');
  for (const asset of release.assets) {
    if (!hashes.has(asset.name) || asset.digest !== 'sha256:' + hashes.get(asset.name)) {
      throw Error('Existing draft has different assets: ' + asset.name);
    }
  }
}

export function findRelease(releases, tag) {
  const matches = releases.filter((release) => release.tag_name === tag);
  if (matches.length > 1) throw Error('Multiple releases use the requested tag');
  return matches[0] || null;
}

async function main() {
  if (process.env.GITHUB_EVENT_NAME !== 'workflow_dispatch' || process.env.GITHUB_REF !== 'refs/heads/Windows_Linux') {
    throw Error('Publishing requires an explicit dispatch from Windows_Linux');
  }
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const { version, tag, title } = releaseInfo(root);
  const repository = process.env.GITHUB_REPOSITORY;
  const commit = process.env.GITHUB_SHA;
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || '') || !/^[0-9a-f]{40}$/.test(commit || '')) throw Error('Missing source identity');
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  if (git('rev-parse', 'HEAD') !== commit || git('status', '--porcelain', '--untracked-files=no')) throw Error('Source is dirty or not the requested commit');
  const option = process.argv.indexOf('--artifacts');
  if (option < 0 || !process.argv[option + 1]) throw Error('--artifacts is required');
  const artifacts = resolve(process.argv[option + 1]);
  const files = readdirSync(artifacts);
  const installers = files.filter((file) => file.endsWith('-setup.exe'));
  const portables = files.filter((file) => file === 'SpektraLab-' + version + '-windows-x64-portable.zip');
  if (installers.length !== 1 || portables.length !== 1) throw Error('Expected exactly one installer and the versioned portable ZIP');
  const portableName = portables[0].slice(0, -4);
  const portableManifest = JSON.parse(execFileSync('unzip', ['-p', join(artifacts, portables[0]), portableName + '/BUILD-MANIFEST.json'], { encoding: 'utf8' }));
  if (portableManifest.commit !== commit || portableManifest.version !== version) throw Error('Portable ZIP belongs to another build');
  for (const path of ['spektralab.exe', 'spektralab-host.exe']) {
    const expected = portableManifest.files.find((file) => file.path.toLowerCase() === path);
    const bytes = execFileSync('unzip', ['-p', join(artifacts, portables[0]), portableName + '/' + expected?.path], { maxBuffer: 128 * 1024 * 1024 });
    if (!expected || createHash('sha256').update(bytes).digest('hex') !== expected.sha256) throw Error('Portable executable differs from its manifest');
  }
  const notesSource = join(root, 'desktop/docs/releases', title + '.md');
  if (!existsSync(notesSource)) throw Error('Release notes are missing');
  const out = join(root, 'build/windows-release', version);
  if (existsSync(out)) throw Error('Release staging already exists');
  mkdirSync(out, { recursive: true });
  const installer = 'SpektraLab-' + version + '-windows-x64-setup.exe';
  cpSync(join(artifacts, installers[0]), join(out, installer));
  cpSync(join(artifacts, portables[0]), join(out, portables[0]));
  const source = 'SpektraLab-' + version + '-source.zip';
  execFileSync('git', ['archive', '--format=zip', '--prefix=SpektraLab/', '--output=' + join(out, source), commit], { cwd: root });
  const hashes = new Map();
  for (const name of [installer, portables[0], source]) hashes.set(name, createHash('sha256').update(readFileSync(join(out, name))).digest('hex'));
  const run = 'https://github.com/' + repository + '/actions/runs/' + process.env.GITHUB_RUN_ID;
  const manifest = 'SpektraLab-' + version + '-BUILD.json';
  writeFileSync(join(out, manifest), JSON.stringify({ version, tag, title, commit, run, assets: Object.fromEntries(hashes) }, null, 2) + '\n');
  hashes.set(manifest, createHash('sha256').update(readFileSync(join(out, manifest))).digest('hex'));
  const sums = 'SpektraLab-' + version + '-SHA256SUMS.txt';
  writeFileSync(join(out, sums), [...hashes].map(([name, hash]) => hash + '  ' + name).join('\n') + '\n');
  hashes.set(sums, createHash('sha256').update(readFileSync(join(out, sums))).digest('hex'));
  const notes = join(out, 'notes.md');
  writeFileSync(notes, readFileSync(notesSource, 'utf8') + '\n\nSource: [' + commit.slice(0, 8) + '](https://github.com/' + repository + '/commit/' + commit + ') · [Build and checks](' + run + ').\n');
  const gh = (...args) => execFileSync('gh', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const api = (path) => JSON.parse(gh('api', 'repos/' + repository + path));
  function optional(path) {
    const result = spawnSync('gh', ['api', 'repos/' + repository + path], { cwd: root, encoding: 'utf8' });
    if (result.status === 0) return JSON.parse(result.stdout);
    if (result.stderr.includes('HTTP 404')) return null;
    throw Error('GitHub read failed: ' + result.stderr);
  }
  const ref = optional('/git/ref/tags/' + tag);
  if (ref) {
    let object = ref.object;
    while (object.type === 'tag') object = api('/git/tags/' + object.sha).object;
    if (object.type !== 'commit' || object.sha !== commit) throw Error('Version tag points to different source');
  }
  // The by-tag endpoint returns published releases only. Drafts are looked up
  // in the authenticated list and all subsequent operations use their ID.
  let release = findRelease(api('/releases?per_page=100'), tag);
  if (release) checkExistingRelease(release, commit, hashes);
  else {
    const create = join(out, 'create-release.json');
    writeFileSync(create, JSON.stringify({ tag_name: tag, target_commitish: commit, name: title,
      body: readFileSync(notes, 'utf8'), draft: true, prerelease: true, make_latest: 'false' }));
    release = JSON.parse(gh('api', 'repos/' + repository + '/releases', '--method', 'POST', '--input', create));
    checkExistingRelease(release, commit, hashes);
  }
  if (release.name !== title || !Number.isSafeInteger(release.id)) throw Error('Unexpected draft identity');
  const releasePath = '/releases/' + release.id;
  const upload = new URL(release.upload_url.split('{')[0]);
  if (upload.origin !== 'https://uploads.github.com' || upload.pathname !== '/repos/' + repository + releasePath + '/assets') throw Error('Unexpected upload URL');
  if (!process.env.GH_TOKEN) throw Error('Missing release credential');
  for (const [name] of hashes) {
    if (release.assets.some((asset) => asset.name === name)) continue;
    upload.searchParams.set('name', name);
    const response = await fetch(upload, { method: 'POST', body: readFileSync(join(out, name)),
      headers: { Authorization: 'Bearer ' + process.env.GH_TOKEN, Accept: 'application/vnd.github+json', 'Content-Type': 'application/octet-stream' },
      signal: AbortSignal.timeout(240000) });
    if (!response.ok) throw Error('Upload failed with HTTP ' + response.status);
    const asset = await response.json();
    if (asset.digest !== 'sha256:' + hashes.get(name)) throw Error('Uploaded asset digest mismatch');
  }
  const uploaded = api(releasePath);
  checkExistingRelease(uploaded, commit, hashes);
  if (uploaded.assets.length !== hashes.size) throw Error('Incomplete upload; leaving the release as a draft');
  const publish = join(out, 'publish-release.json');
  writeFileSync(publish, JSON.stringify({ draft: false, prerelease: true, make_latest: 'false' }));
  gh('api', 'repos/' + repository + releasePath, '--method', 'PATCH', '--input', publish);
  const published = api(releasePath);
  if (published.draft || !published.prerelease || published.name !== title) throw Error('Published release identity is incorrect');
  console.log(published.html_url);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error); process.exitCode = 1; });
}

