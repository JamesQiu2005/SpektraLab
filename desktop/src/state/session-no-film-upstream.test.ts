// 1.3.4's "Don't Apply Film Simulation" (`Session.noFilm`, `FilmSection.select`):
// one undo step, persisted only when on, cleared by choosing a film, refused for a pair.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult, HostState } from '@shared/protocol';
import type * as SessionModule from './session';
import { StockCatalog } from '@shared/stocks';
import { decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

const fake = vi.hoisted(() => ({
  setParams: vi.fn(async () => ({})),
  render: vi.fn(async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'preview', reprinted: false, ms: 1 })),
  save: vi.fn(async (_path: string, _sidecar: unknown) => ''),
}));
vi.mock('../host/client', () => ({
  HostCallError: class extends Error {},
  host: () => ({ setParams: fake.setParams, render: fake.render, close: async () => {}, state: async () => ({ phase: 'ready' }),
    onState: () => {}, thumbnail: async () => { throw new Error('no thumbnail'); } }),
}));
vi.mock('../platform', () => ({
  platform: () => ({ log: () => {}, sidecarLoad: async () => null, sidecarSave: fake.save, setTitle: async () => {} }),
  baseName: (p: string) => p.split(/[\\/]/).pop() ?? p,
  dirName: (p: string) => p.replace(/[\\/][^\\/]*$/, ''),
}));

const catalog = new StockCatalog(stockData.stocks);
const ready = { phase: 'ready', hello: {} as HelloResult } as HostState;
let session: typeof SessionModule;
const sc = () => session.sessionStore.getState().sidecar;

beforeEach(async () => {
  vi.useFakeTimers();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  vi.clearAllMocks();
  vi.resetModules();
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  session = await import('./session');
  session.sessionStore.setState({ catalog, hostState: ready, selection: '/owned/a.ARW', picked: ['/owned/a.ARW'],
    engineSession: 's1', nativeSize: { width: 6, height: 4 }, sidecar: newSidecar(), undo: [], redo: [], pair: null });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("Don't Apply Film Simulation", () => {
  it('is one undo step that keeps the film settings, and undo/redo carry it', () => {
    const params = sc().params;
    session.setNoFilm(true);
    expect(sc().noFilm).toBe(true);
    // Native requests resolve derived edge metadata; user film controls remain unchanged.
    expect({ ...sc().params, filmEdge: params.filmEdge }).toEqual(params);
    expect(session.noFilmShown(session.sessionStore.getState())).toBe(true);
    expect(session.sessionStore.getState().undo).toHaveLength(1);
    session.undo();
    expect(sc().noFilm).toBe(false);
    session.redo();
    expect(sc().noFilm).toBe(true);
  });

  it('is cleared by choosing a film, inside the stock change\'s own undo step', () => {
    session.setNoFilm(true);
    vi.mocked(performance.now).mockReturnValue(20_000);
    session.pickFilmStock('cinestill_800t');
    expect(sc().params.filmStock).toBe('cinestill_800t');
    expect(sc().noFilm).toBe(false);
    expect(session.sessionStore.getState().undo).toHaveLength(2);
    session.undo();
    expect(sc().params.filmStock).toBe('kodak_portra_400');
    expect(sc().noFilm).toBe(true);
    // Re-choosing the film already chosen still asks for it: the flag clears as its own step.
    session.pickFilmStock('kodak_portra_400');
    expect(sc().noFilm).toBe(false);
  });

  it('is left alone by the reset arrow, which repairs a silver paper', () => {
    session.sessionStore.setState({ sidecar: { ...sc(), params: { ...sc().params, filmStock: 'kodak_tri_x_400', printStock: 'ilford_multigrade_iv_rc' } } });
    session.setNoFilm(true);
    session.resetFilmStock();
    expect(sc().params.filmStock).toBe('kodak_portra_400');
    expect(catalog.canPrint('kodak_portra_400', sc().params.printStock)).toBe(true);
    expect(sc().noFilm).toBe(true);
  });

  it('has no state on a pair, and needs an open frame', () => {
    session.sessionStore.setState({ pair: { left: null, right: null } as unknown as SessionModule.SessionState['pair'] });
    session.setNoFilm(true);
    expect(sc().noFilm ?? false).toBe(false);
    session.sessionStore.setState({ pair: null, selection: null });
    session.setNoFilm(true);
    expect(sc().noFilm ?? false).toBe(false);
  });

  it('is written to the sidecar only when on', () => {
    const on = encodeSidecar({ ...newSidecar(), noFilm: true });
    expect(on.noFilm).toBe(true);
    expect(decodeSidecar(on).noFilm).toBe(true);
    const off = encodeSidecar({ ...decodeSidecar(on), noFilm: false });
    expect('noFilm' in off).toBe(false);
    expect(decodeSidecar({}).noFilm).toBe(false);
  });
});
