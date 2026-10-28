// A user-initiated release check, never an installer. The Mac release number
// alone says nothing about an available Windows build.
const REPO = 'https://github.com/JamesQiu2005/SpektraLab';
export const RELEASE_API = 'https://api.github.com/repos/JamesQiu2005/SpektraLab/releases?per_page=30';
export type UpdateStatus = { kind: 'available' | 'current'; version: string; url: string; asset: string }
  | { kind: 'unavailable' | 'failed'; reason: string };

function version(text: unknown): number[] | null {
  if (typeof text !== 'string') return null;
  const m = /^(?:spektralab-v|v)?(\d+)\.(\d+)\.(\d+)(?:[-_]windows(?:[-_]x64)?)?$/i.exec(text);
  if (!m) return null;
  const values = m.slice(1, 4).map(Number);
  return values.every(Number.isSafeInteger) ? values : null;
}
function compare(a: number[], b: number[]) { return a[0]! - b[0]! || a[1]! - b[1]! || a[2]! - b[2]!; }
function officialUrl(value: unknown, prefix: string) {
  if (typeof value !== 'string' || !value.startsWith(prefix)) return false;
  try { const u = new URL(value); return !u.username && !u.password && !u.search && !u.hash && u.origin === 'https://github.com'; }
  catch { return false; }
}
export function selectWindowsRelease(body: unknown, currentVersion: string): UpdateStatus {
  const installed = version(currentVersion);
  if (!installed) return { kind: 'failed', reason: 'This build has no comparable release version.' };
  if (!Array.isArray(body)) return { kind: 'failed', reason: 'GitHub returned an invalid release list.' };
  const matches: { version: number[]; url: string; asset: string }[] = [];
  for (const r of body) {
    if (!r || r.draft !== false || r.prerelease !== false || !Array.isArray(r.assets)) continue;
    const v = version(r.tag_name);
    if (!v || !officialUrl(r.html_url, REPO + '/releases/tag/')) continue;
    const asset = r.assets.find((a: { name?: unknown; browser_download_url?: unknown; size?: unknown; state?: unknown }) => {
      if (typeof a?.name !== 'string' || typeof a.size !== 'number' || a.size <= 0 || a.state !== 'uploaded') return false;
      const n = a.name.toLowerCase();
      return n.includes('spektralab') && /(?:^|[-_. ])(?:windows|win64|win32|win)(?:[-_. ]|$)/.test(n)
        && /(?:^|[-_. ])(?:x64|amd64|win64)(?:[-_. ]|$)/.test(n)
        && !/(?:darwin|macos|arm64|aarch64|source|symbols|debug)/.test(n)
        && /\.(?:zip|7z|exe|msi)$/.test(n) && officialUrl(a.browser_download_url, REPO + '/releases/download/');
    });
    if (asset) matches.push({ version: v, url: r.html_url, asset: asset.name });
  }
  matches.sort((a, b) => compare(b.version, a.version));
  if (!matches.length) return { kind: 'unavailable', reason: 'No matching Windows x64 package was found in the latest 30 releases.' };
  const latest = matches[0]!;
  return { kind: compare(latest.version, installed) > 0 ? 'available' : 'current',
    version: latest.version.join('.'), url: latest.url, asset: latest.asset };
}

export async function checkWindowsUpdate(currentVersion: string, transport: typeof fetch = fetch): Promise<UpdateStatus> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);
  try {
    const r = await transport(RELEASE_API, { signal: controller.signal, credentials: 'omit', cache: 'no-store',
      referrerPolicy: 'no-referrer', headers: { Accept: 'application/vnd.github+json' } });
    if (!r.ok) return { kind: 'failed', reason: r.status === 403 && r.headers.get('x-ratelimit-remaining') === '0'
      ? 'GitHub rate limit reached. Please try again later.' : `GitHub returned HTTP ${r.status}.` };
    return selectWindowsRelease(await r.json(), currentVersion);
  } catch (e) {
    return { kind: 'failed', reason: controller.signal.aborted ? 'GitHub did not answer within five seconds.' : String(e) };
  } finally { clearTimeout(timer); }
}
