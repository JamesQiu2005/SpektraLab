// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
import { newSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
import { StockCatalog } from '@shared/stocks';
import type { HelloResult } from '@shared/protocol';
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  setParams: async () => ({}), render: async () => ({ width: 6, height: 4, data: new Uint8Array(96), ms: 1 }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarSave: async () => '' }),
  baseName: (p: string) => p, dirName: (p: string) => p }));
import { sessionStore } from '../state/session';
import { settingsStore } from '../state/settings';
import { setLanguage } from '../i18n';
import { RightRail } from './RightRail';

// 1.3.4's Film Format rows for a film with no anti-halation layer (ParameterSections.swift).
let root: Root, div: HTMLDivElement;
async function mount(filmStock: string, decoupleEffects = false) {
  settingsStore.setState({ collapsedSections: {}, parametersTab: 'preDev', decoupleEffects });
  const sidecar = structuredClone(newSidecar());
  sidecar.params.filmStock = filmStock;
  sidecar.params.printStock = 'kodak_2383';
  sessionStore.setState({ sidecar, selection: null, catalog: new StockCatalog(stockData.stocks),
    hello: { methods: [] } as unknown as HelloResult, gate: ALL_FEATURES, nativeSize: null, frameKind: null });
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
  await act(async () => root.render(<RightRail />));
}
beforeEach(() => {
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.stubGlobal('React', React);
  setLanguage('english');
});
afterEach(async () => {
  await act(async () => root.unmount()); div.remove(); vi.unstubAllGlobals();
});

describe('CineStill 800T in Film Format', () => {
  it('shows the anti-halation layer off and fixed, with the reason, and the headroom slider under it', async () => {
    await mount('cinestill_800t');
    const layer = div.querySelector('[data-testid=antihalation-toggle]')!;
    expect(layer.getAttribute('aria-checked')).toBe('false');
    expect(layer.getAttribute('aria-disabled')).toBe('true');
    expect(layer.getAttribute('title')).toBe('This film has no anti-halation layer');
    await act(async () => { layer.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
    expect(sessionStore.getState().sidecar.params.effects.antihalationRemoved).toBe(false);
    const slider = div.querySelector('[data-testid=headroom-slider]')!;
    expect(slider.textContent).toContain('Highlight Headroom');
    expect(slider.querySelector('input')!.value).toBe('4.0');
    // Directly under the layer row, in the simple layout too.
    expect(layer.nextElementSibling).toBe(slider);
  });

  it('greys the headroom with halation off', async () => {
    await mount('cinestill_800t', true);
    await act(async () => { sessionStore.setState((s) => ({ sidecar: { ...s.sidecar, params: { ...s.sidecar.params, halationActive: false } } })); });
    expect(div.querySelector('[data-testid=headroom-slider]')!.classList.contains('disabled')).toBe(true);
  });

  it('keeps the live switch and no headroom on a film with a layer', async () => {
    await mount('kodak_vision3_500t');
    const layer = div.querySelector('[data-testid=antihalation-toggle]')!;
    expect(layer.getAttribute('aria-checked')).toBe('true');
    expect(layer.getAttribute('aria-disabled')).toBeNull();
    expect(div.querySelector('[data-testid=headroom-slider]')).toBeNull();
  });

  it('reads 高光余量 in Chinese', async () => {
    setLanguage('simplifiedChinese');
    await mount('cinestill_800t');
    expect(div.querySelector('[data-testid=headroom-slider]')!.textContent).toContain('高光余量');
    expect(div.querySelector('[data-testid=antihalation-toggle]')!.getAttribute('title')).toBe('此胶片没有防光晕层');
  });
});
