import { describe, expect, it, vi } from 'vitest';
import { checkWindowsUpdate, RELEASE_API, selectWindowsRelease } from './updateCheck';
const root = 'https://github.com/JamesQiu2005/SpektraLab/releases';
const release = (tag = 'spektralab-v1.3.3', name = 'SpektraLab-windows-x64.zip') => ({ tag_name: tag,
  html_url: `${root}/tag/${tag}`, draft: false, prerelease: false,
  assets: [{ name, browser_download_url: `${root}/download/${tag}/${name}`, size: 1234, state: 'uploaded' }] });

describe('Windows release identification', () => {
  it('does not turn a Mac release or an unsupported architecture into a Windows update', () => {
    for (const name of ['SpektraLab-1.3.3.dmg', 'SpektraLab-macos-arm64.zip', 'SpektraLab-windows-arm64.zip',
      'SpektraLab-windows.zip', 'SpektraLab-windows-x64-source.zip', 'source.zip'])
      expect(selectWindowsRelease([release(undefined, name)], '1.3.1').kind).toBe('unavailable');
  });
  it('chooses the highest published Windows version, ignoring prerelease and draft assets', () => {
    const result = selectWindowsRelease([release(), release('spektralab-v1.4.0-windows'),
      { ...release('spektralab-v5.0.0'), prerelease: true }, { ...release('spektralab-v6.0.0'), draft: true }], '1.3.1');
    expect(result).toMatchObject({ kind: 'available', version: '1.4.0' });
    expect(selectWindowsRelease([release()], '1.4.0').kind).toBe('current');
  });
  it('rejects untrusted release/asset links and unknown version syntax', () => {
    const bad = release(); bad.assets[0]!.browser_download_url = 'https://example.org/update.exe';
    expect(selectWindowsRelease([bad], '1.3.1').kind).toBe('unavailable');
    expect(selectWindowsRelease([{ ...release(), html_url: 'https://github.com.evil.org/releases/tag/v2.0.0' }], '1.3.1').kind).toBe('unavailable');
    expect(selectWindowsRelease([release('nightly')], '1.3.1').kind).toBe('unavailable');
    expect(selectWindowsRelease([], 'broken').kind).toBe('failed');
  });
  it('uses a bounded, cookie-free explicit request and never reports a transport failure as current', async () => {
    const request = vi.fn().mockResolvedValue(new Response(JSON.stringify([release()]), { status: 200 }));
    expect((await checkWindowsUpdate('1.3.1', request)).kind).toBe('available');
    expect(request).toHaveBeenCalledWith(RELEASE_API, expect.objectContaining({ credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer' }));
    expect((await checkWindowsUpdate('1.3.1', vi.fn().mockRejectedValue(new Error('offline')))).kind).toBe('failed');
    expect(await checkWindowsUpdate('1.3.1', vi.fn().mockResolvedValue(new Response('', { status: 403, headers: { 'x-ratelimit-remaining': '0' } })))).toMatchObject({ kind: 'failed', reason: expect.stringContaining('rate limit') });
  });
});
