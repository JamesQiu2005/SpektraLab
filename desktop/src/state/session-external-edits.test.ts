import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import type { HelloResult } from '@shared/protocol';
import type * as SessionModule from './session';
const fake = vi.hoisted(() => ({ changes: vi.fn(), load: vi.fn(), save: vi.fn(), open: vi.fn(), close: vi.fn(), confirm: vi.fn(), invalidate: vi.fn() }));
vi.mock('../platform', () => ({ platform: () => ({ agentChanges: fake.changes, sidecarLoad: fake.load, sidecarSave: fake.save,
  confirm: fake.confirm, log: vi.fn(), setTitle: vi.fn() }), baseName: (p: string) => p.split('/').pop(), dirName: () => '/owned' }));
vi.mock('./thumbs', () => ({ thumbs: { invalidate: fake.invalidate, setPrint: vi.fn() } }));
vi.mock('./displayCache', () => ({ displayCacheKey: async () => null, readDisplayCache: async () => null, writeDisplayCache: async () => true,
  forgetDisplayMemoryCache: vi.fn(), peekDisplayCache: vi.fn(() => null) }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({ open: fake.open, close: fake.close,
  setParams: async () => ({}), renderView: async (_sid: string, tier: string) => ({ width: 2, height: 1, data: new Uint8Array(8), tier, ms: 1 }),
  thumbnail: async () => { throw new Error('No embedded preview'); } }) }));
let session: typeof SessionModule;
const path = '/owned/a.NEF', other = '/owned/b.NEF';
const hello = { methods: ['render_view'] } as HelloResult;
const saved = () => { const s = structuredClone(newSidecar()); s.params.filmEdge.seeded = true; s.state = 'processed'; return s; };
const state = () => session.sessionStore.getState();
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  fake.changes.mockResolvedValue({ revision: '1', paths: [path] });
  fake.save.mockResolvedValue('/owned/sidecar.json'); fake.confirm.mockResolvedValue(false);
  fake.load.mockResolvedValue(encodeSidecar(saved())); fake.close.mockResolvedValue(undefined);
  fake.open.mockResolvedValue({ session: 'new', width: 20, height: 10, kind: 'raw', metadata: {} });
  session = await import('./session');
  session.sessionStore.setState({ selection: path, sidecar: saved(), engineSession: 'old', frameKind: 'raw',
    frames: [path, other].map((p) => ({ path: p, name: p, size: 1, mtime_ms: 0 })),
    hello, hostState: { phase: 'ready', hello }, nativeSize: { width: 20, height: 10 } });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe('external edit journal', () => {
  it('takes the first journal as a cursor, then refreshes a clean selected frame and invalidates other thumbnails', async () => {
    await session.pollAgentChanges(); expect(fake.load).not.toHaveBeenCalled(); expect(fake.open).not.toHaveBeenCalled();
    const next = saved(); next.adjustments.exposure = 1.75;
    fake.load.mockResolvedValue(encodeSidecar(next));
    fake.changes.mockResolvedValue({ revision: '2', paths: [path, other] });
    await session.pollAgentChanges();
    expect(fake.open).toHaveBeenCalledOnce(); expect(fake.close).toHaveBeenCalledWith('old');
    expect(state().sidecar.adjustments.exposure).toBe(1.75);
    expect(fake.invalidate).toHaveBeenCalledWith(other);
  });
  it('preserves local edits and stops autosave, including navigation, until an explicit reload is accepted', async () => {
    await session.pollAgentChanges();
    session.setAdjustments((a) => ({ ...a, exposure: 2 }));
    fake.changes.mockResolvedValue({ revision: '2', paths: [path] });
    await session.pollAgentChanges(); await vi.advanceTimersByTimeAsync(700);
    expect(state().externalEditConflict).toBe(true); expect(state().sidecar.adjustments.exposure).toBe(2);
    expect(fake.save).not.toHaveBeenCalled();
    await session.select(other); expect(state().selection).toBe(path);
    await session.reloadExternalEdits(); expect(state().sidecar.adjustments.exposure).toBe(2);
    fake.confirm.mockResolvedValue(true);
    await session.reloadExternalEdits();
    expect(state().externalEditConflict).toBe(false); expect(state().sidecar.adjustments.exposure).toBe(0);
    expect(fake.open).toHaveBeenCalledOnce();
  });
  it('rejects a disk refresh that finishes after a new local edit', async () => {
    await session.pollAgentChanges();
    let finish!: (value: unknown) => void;
    fake.load.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    fake.changes.mockResolvedValue({ revision: '2', paths: [path] });
    const pending = session.pollAgentChanges(); await vi.advanceTimersByTimeAsync(1);
    session.setAdjustments((a) => ({ ...a, contrast: 30 }));
    finish(encodeSidecar(saved())); await pending;
    expect(fake.close).not.toHaveBeenCalled(); expect(fake.open).not.toHaveBeenCalled();
    expect(state().sidecar.adjustments.contrast).toBe(30); expect(state().externalEditConflict).toBe(true);
  });
  it('keeps a change pending while a batch holds the editor, then refreshes at idle', async () => {
    await session.pollAgentChanges(); session.sessionStore.setState({ batchExporting: true });
    fake.changes.mockResolvedValue({ revision: '2', paths: [path] });
    await session.pollAgentChanges(); expect(fake.open).not.toHaveBeenCalled();
    session.sessionStore.setState({ batchExporting: false });
    await session.pollAgentChanges(); expect(fake.open).toHaveBeenCalledOnce();
  });
  it('handles a native revision conflict even before the next journal poll, retaining the edit snapshot token', async () => {
    const token = { key: '/owned/a.json', base: 'a'.repeat(64) };
    session.sessionStore.setState({ sidecar: decodeSidecar({ ...encodeSidecar(saved()), _spkRevision: token }) });
    session.setAdjustments((a) => ({ ...a, exposure: 2 }));
    fake.save.mockRejectedValue(new Error('EXTERNAL_EDIT_CONFLICT: changed outside'));
    await session.flushSave();
    expect(fake.save.mock.calls[0]?.[1]._spkRevision).toEqual(token);
    expect(state().externalEditConflict).toBe(true); expect(state().sidecar.adjustments.exposure).toBe(2);
    await session.flushSave(); expect(fake.save).toHaveBeenCalledOnce();
  });
  it('checks the saved selected snapshot when a bounded journal overflow omits its path', async () => {
    await session.pollAgentChanges();
    const next = saved(); next.adjustments.exposure = 1;
    fake.load.mockResolvedValue(encodeSidecar(next));
    fake.changes.mockResolvedValue({ revision: '2', paths: [other], all: true });
    await session.pollAgentChanges();
    expect(state().sidecar.adjustments.exposure).toBe(1); expect(fake.open).toHaveBeenCalledOnce();
  });
  it('does not reopen unchanged selected pixels merely because other paths overflowed', async () => {
    await session.pollAgentChanges();
    fake.changes.mockResolvedValue({ revision: '2', paths: [other], all: true });
    await session.pollAgentChanges();
    expect(fake.open).not.toHaveBeenCalled(); expect(state().externalEditConflict).toBe(false);
    expect(fake.invalidate).toHaveBeenCalledWith(path);
  });
});
