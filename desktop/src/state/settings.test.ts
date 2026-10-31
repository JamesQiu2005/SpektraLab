// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import { createSettingsStore, loadSettings, RECENT_FOLDERS_MAX, withRecentFolder } from './settings';

function memory(seed: Record<string, string> = {}) {
  const m = new Map(Object.entries(seed));
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
}

describe('recent folders', () => {
  it('puts the newest folder first, once, and keeps the list short', () => {
    let recent: string[] = [];
    for (let i = 0; i < RECENT_FOLDERS_MAX + 3; i++) recent = withRecentFolder(recent, `/photos/roll ${i}`);
    expect(recent).toHaveLength(RECENT_FOLDERS_MAX);
    expect(recent[0]).toBe(`/photos/roll ${RECENT_FOLDERS_MAX + 2}`);
    expect(withRecentFolder(recent, '/photos/roll 5')[0]).toBe('/photos/roll 5');
    expect(withRecentFolder(recent, '/photos/roll 5').filter((p) => p === '/photos/roll 5')).toHaveLength(1);
  });
  it('treats slashes, a trailing separator and Windows letter case as the same folder', () => {
    expect(withRecentFolder(['D:\\Photos\\Roll'], 'd:/photos/roll/')).toEqual(['d:/photos/roll/']);
    expect(withRecentFolder(['/home/me/Roll'], '/home/me/roll')).toEqual(['/home/me/roll', '/home/me/Roll']);
  });
  it('loads only non-empty strings from storage and caps the list', () => {
    const stored = { recentFolders: ['D:/a', 3, '', null, ...Array.from({ length: 20 }, (_, i) => `D:/r${i}`)] };
    const s = loadSettings(memory({ 'ui2.settings': JSON.stringify(stored) }));
    expect(s.recentFolders).toHaveLength(RECENT_FOLDERS_MAX);
    expect(s.recentFolders.slice(0, 2)).toEqual(['D:/a', 'D:/r0']);
    expect(loadSettings(memory({ 'ui2.settings': JSON.stringify({ recentFolders: 'D:/a' }) })).recentFolders).toEqual([]);
  });
  it('persists through the store', async () => {
    const storage = memory();
    const store = createSettingsStore(storage);
    store.getState().set('recentFolders', ['D:/a']);
    await Promise.resolve();
    expect(JSON.parse(storage.getItem('ui2.settings')!).recentFolders).toEqual(['D:/a']);
    expect(loadSettings(storage).recentFolders).toEqual(['D:/a']);
  });
});

describe('the module store', () => {
  it('loads what is stored when the module initialises', async () => {
    window.localStorage.setItem('ui2.settings', JSON.stringify({ interfaceScale: 130, recentFolders: ['D:/a'] }));
    vi.resetModules();
    const fresh = await import('./settings');
    expect(fresh.settingsStore.getState().interfaceScale).toBe(130);
    expect(fresh.settingsStore.getState().recentFolders).toEqual(['D:/a']);
    window.localStorage.removeItem('ui2.settings');
  });
});
