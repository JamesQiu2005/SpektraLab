// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { newSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
import type { HelloResult } from '@shared/protocol';
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  sceneLatitude: async () => ({ medium: { shadow_ev: -5, highlight_ev: 4, latitude_stops: 9 },
    scene: { histogram: { lo_ev: -16, hi_ev: 16, fractions: [.1, .8, .1] } }, fit: {
      highlight: { scene_extreme_ev: 7, medium_boundary_ev: 4, minimum_pull_back: 3 },
      shadow: { scene_extreme_ev: -8, medium_boundary_ev: -5, minimum_pull_back: 3 } } }),
  setParams: async () => ({}), render: async () => ({ width: 6, height: 4, data: new Uint8Array(96), ms: 1 }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarSave: async () => '' }),
  baseName: (p: string) => p, dirName: (p: string) => p }));
import { refreshLatitude, sessionStore } from '../state/session';
import { settingsStore } from '../state/settings';
import { setLanguage } from '../i18n';
import { RightRail } from './RightRail';
let root: Root, div: HTMLDivElement;
beforeEach(async () => {
  vi.useFakeTimers(); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.stubGlobal('React', React);
  setLanguage('english');
  settingsStore.setState({ collapsedSections: {}, parametersTab: 'preDev' });
  sessionStore.setState({ sidecar: structuredClone(newSidecar()), selection: '/owned/a.ARW', engineSession: 's1',
    latitude: { reply: null, failure: null, refusal: null, session: null, frame: null, stamp: null },
    hello: { methods: ['scene_latitude', 'redecode', 'pick_neutral'] } as HelloResult,
    gate: ALL_FEATURES, nativeSize: { width: 6, height: 4 }, frameKind: 'raw', batchExporting: false, redecoding: false });
  await refreshLatitude();
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
  await act(async () => root.render(<RightRail />));
});
afterEach(async () => {
  await act(async () => root.unmount()); div.remove(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals();
});
it('renders usable bands, clamps typed keyboard input to a fitted value, and resets it', async () => {
  const row = div.querySelector('[data-testid=placement-highlight]')!;
  expect(row.querySelector('.usable')).not.toBeNull();
  const field = row.querySelector('input')!;
  expect(field.disabled).toBe(false);
  await act(async () => { field.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true })); });
  expect(Number(field.value)).toBeGreaterThan(3);
  expect(sessionStore.getState().sidecar.params.sceneLatitude.active).toBe(true);
  expect(div.querySelector('[data-testid=placement-highlight-reason]')?.textContent).toContain('transition would turn too sharply');
  const reset = div.querySelector('[data-section=scenePlacement] .section-header button[title]')!;
  await act(async () => { reset.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
  expect(field.value).toBe('0.00');
});
it('keeps unsupported controls visibly disabled and exposes the RAW neutral picker', async () => {
  expect((div.querySelector('[data-testid=pick-neutral]') as HTMLButtonElement).disabled).toBe(false);
  await act(async () => sessionStore.setState({ gate: { ...ALL_FEATURES, sceneLatitude: false } }));
  expect((div.querySelector('[data-testid=placement-highlight] input') as HTMLInputElement).disabled).toBe(true);
  expect(div.querySelector('[data-section=scenePlacement]')?.textContent).toContain('not available with this engine');
});
it('enables lens correction only for a matched profile and preserves the per-photo preference', async () => {
  const lensRow = () => div.querySelector('[data-testid=lens-correction]')!;
  expect(lensRow().getAttribute('aria-disabled')).toBe('true');
  await act(async () => sessionStore.setState({ metadata: { lens_correction: { available: true, applied: false,
    profile: 'Test lens', distortion: true, tca: true, vignetting: false, scale: 1.02 } } }));
  expect(lensRow().getAttribute('aria-disabled')).not.toBe('true');
  expect(div.querySelector('[data-testid=lens-profile]')?.textContent).toContain('Test lens');
  await act(async () => lensRow().dispatchEvent(new MouseEvent('click', { bubbles: true })));
  expect(sessionStore.getState().sidecar.decode.lensCorrection).toBe(true);
});
