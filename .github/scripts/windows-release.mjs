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

function main() {
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
  let release = optional('/releases/tags/' + tag);
  if (release) checkExistingRelease(release, commit, hashes);
  else {
    gh('release', 'create', tag, '--repo', repository, '--target', commit, '--title', title, '--notes-file', notes, '--draft', '--prerelease', '--latest=false');
    release = api('/releases/tags/' + tag);
    checkExistingRelease(release, commit, hashes);
  }
  for (const [name] of hashes) {
    if (!release.assets.some((asset) => asset.name === name)) gh('release', 'upload', tag, join(out, name), '--repo', repository);
  }
  const uploaded = api('/releases/tags/' + tag);
  checkExistingRelease(uploaded, commit, hashes);
  if (uploaded.assets.length !== hashes.size) throw Error('Incomplete upload; leaving the release as a draft');
  gh('release', 'edit', tag, '--repo', repository, '--draft=false', '--prerelease', '--latest=false');
  const published = api('/releases/tags/' + tag);
  if (published.draft || !published.prerelease || published.name !== title) throw Error('Published release identity is incorrect');
  console.log(published.html_url);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

