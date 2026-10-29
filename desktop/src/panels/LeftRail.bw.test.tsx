// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SessionState } from '../state/session';
import type { SettingsStore } from '../state/settings';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
import { StockCatalog } from '@shared/stocks';
import { newSidecar } from '@shared/sidecar';
import { featureGate } from '@shared/params';
import { CLIPBOARD_GROUPS } from '@shared/clipboard';
import { newPair } from '@shared/pair';

const fake = vi.hoisted(() => ({ selectFilm: vi.fn(), selectPaper: vi.fn(), setParams: vi.fn(), toggleNoFilm: vi.fn() }));
vi.mock('../state/session', async () => {
  const { createStore } = await import('zustand/vanilla');
  const { useStore } = await import('zustand');
  const sessionStore = createStore<SessionState>(() => ({} as SessionState));
  return { sessionStore, useSession: <T,>(selector: (s: SessionState) => T) => useStore(sessionStore, selector),
    resetFilmStock: vi.fn(),
  selectFilmStock: fake.selectFilm, selectPrintStock: fake.selectPaper, setParams: fake.setParams,
    toggleNoFilm: fake.toggleNoFilm,
    setEnlarger: fake.setParams, resetEnlarger: vi.fn(), enlargerParams: (s: SessionState) => s.sidecar.params,
    canMakePair: () => false, makePair: vi.fn(),
    copySettings: vi.fn(), pasteSettings: vi.fn(), setGeometry: vi.fn(), setPages: vi.fn(), syncSettings: vi.fn(),
    zoomToFit: vi.fn(), setView: vi.fn(), setTool: vi.fn(), changeFilmBody: vi.fn(), advanceFilm: vi.fn(), flipFilmGate: vi.fn(),
  };
});
vi.mock('../state/settings', () => {
  const state = { collapsedSections: {}, set: vi.fn(), toggleSection: vi.fn() } as unknown as SettingsStore;
  return { settingsStore: { getState: () => state }, useSettings: <T,>(selector: (s: SettingsStore) => T) => selector(state) };
});
vi.mock('../canvas/output', () => ({ useOutput: () => null }));
vi.mock('./PairSection', () => ({ PairSection: () => null }));
import { sessionStore } from '../state/session';
import { setLanguage } from '../i18n';
import { LeftRail } from './LeftRail';

let root: Root;
let div: HTMLDivElement;
async function mount() {
  div = document.createElement('div'); document.body.append(div);
  root = createRoot(div);
  await act(async () => { root.render(<LeftRail />); });
}
async function click(el: Element) {
  await act(async () => { el.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
}
beforeEach(() => {
  vi.clearAllMocks();
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('React', React);
  setLanguage('english');
  const sidecar = structuredClone(newSidecar());
  sidecar.params.filmStock = 'kodak_tri_x_400';
  sidecar.params.printStock = 'ilford_multigrade_iv_rc';
  sidecar.params.extendedDynamicRange = true;
  sessionStore.setState({ sidecar, catalog: new StockCatalog(stockData.stocks),
    gate: featureGate(['digital_intermediate', 'scene_latitude_mapping', 'contrast_mask', 'overscan', 'date_imprint']),
    picked: [], selection: null, pair: null, batchExporting: false, clipboard: null, clipboardGroups: [...CLIPBOARD_GROUPS], nativeSize: null,
    view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 }, canvasPx: { width: 1, height: 1 },
  });
});
afterEach(async () => {
  if (root) await act(async () => root.unmount());
  div?.remove(); vi.unstubAllGlobals();
});

describe('black-and-white picker behavior', () => {
  async function filmMenu() {
    const trigger = div.querySelector('[data-section=film] button[aria-label=More]')!;
    await act(async () => trigger.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
    return [...document.querySelectorAll('[role=menuitem]')].find((el) => /Don't Apply Film Simulation|不应用胶片模拟/.test(el.textContent ?? ''));
  }
  it('exposes film bypass as a checked film-menu action with an explicit source-view state', async () => {
    sessionStore.setState({ selection: '/test/a.ARW', gate: featureGate([], false, true),
      sidecar: { ...sessionStore.getState().sidecar, noFilm: true } });
    await mount();
    expect(div.querySelector('[data-testid=no-film-state]')?.textContent).toContain('Post-processing and crop');
    const item = await filmMenu();
    expect(item?.textContent).toContain('✓');
    expect(item?.getAttribute('aria-disabled')).not.toBe('true');
    await click(item!);
    expect(fake.toggleNoFilm).toHaveBeenCalledOnce();
  });
  it.each(['legacy', 'pair'])('keeps the film bypass menu inert for %s', async (kind) => {
    setLanguage('simplifiedChinese');
    sessionStore.setState({ selection: '/test/a.ARW', gate: featureGate([], false, kind !== 'legacy'),
      pair: kind === 'pair' ? newPair('/test') : null });
    await mount();
    const item = await filmMenu();
    expect(item?.textContent).toContain('不应用胶片模拟');
    expect(item?.getAttribute('aria-disabled')).toBe('true');
    await click(item!);
    expect(fake.toggleNoFilm).not.toHaveBeenCalled();
  });
  it('keeps unavailable Film Edge and Date Back controls inert, then enables the verified capability', async () => {
    await mount();
    await click(div.querySelector('[data-testid=film-edge-enable]')!);
    await click(div.querySelector('[data-testid=date-back-enable]')!);
    expect(fake.setParams).not.toHaveBeenCalled();
    await act(async () => { sessionStore.setState({ gate: featureGate([]) }); });
    await click(div.querySelector('[data-testid=film-edge-enable]')!);
    expect(fake.setParams).toHaveBeenCalledTimes(1);
    expect(fake.setParams.mock.calls[0]![0](newSidecar().params).filmEdge.active).toBe(true);
    expect(div.textContent).toContain('Film advance');
    expect(div.textContent).toContain('Shooting data');
  });
  it('shows the released group, prevents incompatible paper clicks and explains EDR without erasing it', async () => {
    await mount();
    expect(div.querySelector('[data-testid=film-list]')?.textContent).toContain('Black & White');
    const colour = div.querySelector('[data-stock=kodak_supra_endura]')!;
    expect(colour.getAttribute('aria-disabled')).toBe('true');
    expect(colour.getAttribute('title')).toContain('black-and-white paper');
    await click(colour);
    expect(fake.selectPaper).not.toHaveBeenCalled();
    const silver = div.querySelector('[data-stock=ilford_multigrade_iv_rc]')!;
    expect(silver.getAttribute('aria-disabled')).toBe('false');
    await click(silver);
    expect(fake.selectPaper).toHaveBeenCalledWith('ilford_multigrade_iv_rc');
    const edr = div.querySelector('[title="EDR is not calibrated for silver paper."]')!;
    expect(edr.classList.contains('disabled')).toBe(true);
    expect(edr.getAttribute('aria-checked')).toBe('true');
    await click(edr);
    expect(fake.setParams).not.toHaveBeenCalled();
    await click(div.querySelector('[data-stock=ilford_hp5_plus_400]')!);
    expect(fake.selectFilm).toHaveBeenCalledWith('ilford_hp5_plus_400');
  });

  it('shows the Chinese group/reason and disables silver paper for a colour film', async () => {
    setLanguage('simplifiedChinese');
    const sidecar = structuredClone(newSidecar());
    sessionStore.setState({ sidecar });
    await mount();
    expect(div.querySelector('[data-testid=film-list]')?.textContent).toContain('黑白');
    const silver = div.querySelector('[data-stock=ilford_multigrade_iv_rc]')!;
    expect(silver.getAttribute('aria-disabled')).toBe('true');
    expect(silver.getAttribute('title')).toBe('黑白相纸，需要选择黑白胶片。');
    expect(div.querySelector('[data-stock=kodak_supra_endura]')?.getAttribute('aria-disabled')).toBe('false');
  });
});
