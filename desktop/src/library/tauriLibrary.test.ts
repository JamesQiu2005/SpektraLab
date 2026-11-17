// The app's Library door: library_call / library_state through Tauri (src-tauri/src/library.rs), the
// helper's errors as LibraryError, the README's state shape; and a folder's library kept in the
// helper's store, never in the person's folder.

import { describe, expect, it, vi } from 'vitest';
import { LibraryError, type LibraryClient, type LibraryState } from './client';
import { TauriLibrary, type Invoke } from './tauriLibrary';

vi.mock('../platform', () => ({ platform: () => ({ listImages: async () => [{ path: 'D:/Photos/Roll/a.NEF' }], pickFolder: async () => null, appPaths: async () => ({}) }) }));

describe('TauriLibrary', () => {
  it('calls library_call with the method and params, and hands back the reply', async () => {
    const sent: unknown[] = [];
    const call: Invoke = async <T,>(cmd: string, args?: Record<string, unknown>) => { sent.push([cmd, args]); return { library: 'L1' } as T; };
    expect(await new TauriLibrary(call).call('library.open', { path: 'D:/x.spkcatalog' })).toEqual({ library: 'L1' });
    expect(sent).toEqual([['library_call', { method: 'library.open', params: { path: 'D:/x.spkcatalog' } }]]);
  });
  it('turns the helper’s error object into a LibraryError with its code and data', async () => {
    const call: Invoke = async () => { throw { code: 'conflict', message: 'edited elsewhere', data: { revision: 7 } }; };
    const e = await new TauriLibrary(call).call('edit.put', {}).catch((x: unknown) => x);
    expect(e).toBeInstanceOf(LibraryError);
    expect(e).toMatchObject({ code: 'conflict', message: 'edited elsewhere', data: { revision: 7 } });
    const plain: Invoke = async () => { throw 'the helper went away'; };
    expect(await new TauriLibrary(plain).call('host.ping').catch((x: unknown) => x)).toMatchObject({ code: 'internal', message: 'the helper went away' });
  });
  it('reads library_state in the README’s shape', async () => {
    const st: LibraryState = { running: true, version: '0.4.0+85d52813e2e8', launches: 1, store: 'C:/Users/me/AppData/Local/SpektraLab/Libraries', executable: 'C:/Program Files/SpektraLab/spklib-host.exe', origin: 'beside the engine host' };
    const call: Invoke = async <T,>(cmd: string) => (cmd === 'library_state' ? st : null) as T;
    expect(Object.keys(await new TauriLibrary(call).state()).sort()).toEqual(['executable', 'launches', 'origin', 'running', 'store', 'version']);
  });
});

describe('a folder source', () => {
  it('keeps its library in the helper’s store, and opens the one it already has the second time', async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const made = new Set<string>();
    const client: LibraryClient = {
      async state() { return { running: true, version: '0.4.0', launches: 1, store: 'C:/Store', executable: null }; },
      async call<T>(method: string, params: Record<string, unknown> = {}) {
        calls.push([method, params]);
        const info = { uuid: 'u', kind: 'catalog', name: 'Roll', path: String(params.path ?? ''), origin: null, counts: { images: 1 } };
        if (method === 'library.create') {
          if (made.has(String(params.path))) throw new LibraryError('exists', 'already there');
          made.add(String(params.path));
          return { library: 'L1', info } as T;
        }
        if (method === 'library.open') return { library: 'L2', info } as T;
        if (method === 'collections.list') return { collections: [] } as T;
        if (method === 'folders.list') return { folders: [] } as T;
        if (method === 'images.list') return { total: 1, offset: 0, images: [] } as T;
        return {} as T;
      },
    };
    const store = await import('./store');
    store.setLibraryClient(client);
    await store.addFolder('D:/Photos/Roll');
    await store.addFolder('D:/Photos/Roll');
    const creates = calls.filter(([m]) => m === 'library.create').map(([, p]) => String(p.path));
    expect(creates).toHaveLength(2);
    expect(creates[0]).toMatch(/^C:\/Store\/Folders\/Roll-[0-9a-f]{8}\.spkcatalog$/);
    expect(creates.every((p) => !p.startsWith('D:/Photos/Roll'))).toBe(true);
    expect(calls.filter(([m]) => m === 'library.open').map(([, p]) => p.path)).toEqual([creates[0]]);
  });
});
