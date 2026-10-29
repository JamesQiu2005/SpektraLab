// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { newSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarSave: async () => '' }),
  baseName: (p: string) => p, dirName: (p: string) => p }));
import { sessionStore, setParams } from '../state/session';
import { settingsStore } from '../state/settings';
import { setLanguage } from '../i18n';
import { RightRail } from './RightRail';

let root: Root, div: HTMLDivElement;
const field = () => div.querySelector('[data-section=filmFormat] .unit-field') as HTMLInputElement;
const button = (id: string) => div.querySelector(`[data-testid=${id}]`) as HTMLButtonElement;
beforeEach(async () => {
  vi.useFakeTimers(); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true); vi.stubGlobal('React', React);
  setLanguage('english');
  settingsStore.setState({ collapsedSections: {}, parametersTab: 'preDev', sideUnit: 'mm' });
  sessionStore.setState({ sidecar: structuredClone(newSidecar()), selection: null, engineSession: null,
    latitude: { reply: null, failure: null, refusal: null, session: null, frame: null, stamp: null },
    gate: ALL_FEATURES, nativeSize: { width: 6, height: 4 }, batchExporting: false,
    pair: null, pairInfo: null, undo: [], redo: [] });
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
  await act(async () => root.render(<RightRail />));
});
afterEach(async () => {
  await act(async () => root.unmount()); div.remove(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals();
});

it('only allows a custom frame side length to be typed', async () => {
  expect(field().disabled).toBe(true);
  await act(async () => setParams((p) => ({ ...p, filmFrame: 'Custom', sideLengthMM: 42 })));
  expect(field().disabled).toBe(false);
  expect(field().value).toBe('42.0');
});

it('shows the active film gate, locks its controls, and restores the stored custom frame', async () => {
  await act(async () => setParams((p) => ({ ...p, filmFrame: 'Custom', filmSide: 'long', sideLengthMM: 42,
    filmEdge: { ...p.filmEdge, active: true, format: '120_6x7' } })));
  expect(button('film-format-size').disabled).toBe(true);
  expect(button('film-format-size').textContent).toContain('6×7');
  expect(button('film-format-size').title).toContain('69.5 × 56 mm');
  expect(button('film-format-side').disabled).toBe(true);
  expect(button('film-format-unit').disabled).toBe(true);
  expect(field().disabled).toBe(true);

  // Resetting effects while a gate owns the frame must not erase its held size.
  await act(async () => div.querySelector('[data-section=filmFormat] .section-header button[title]')!
    .dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await act(async () => setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: false } })));
  const p = sessionStore.getState().sidecar.params;
  expect([p.filmFrame, p.filmSide, p.sideLengthMM]).toEqual(['Custom', 'long', 42]);
  expect(button('film-format-size').disabled).toBe(false);
  expect(button('film-format-size').textContent).toContain('Custom');
  expect(button('film-format-side').disabled).toBe(false);
  expect(button('film-format-unit').disabled).toBe(false);
  expect(field().disabled).toBe(false);
});

it('does not lock the physical frame when the host cannot render the saved film edge', async () => {
  await act(async () => {
    sessionStore.setState({ gate: { ...ALL_FEATURES, overscan: false } });
    setParams((p) => ({ ...p, filmFrame: 'Custom', filmEdge: { ...p.filmEdge, active: true } }));
  });
  expect(button('film-format-size').disabled).toBe(false);
  expect(field().disabled).toBe(false);
});

it('names print white balance offsets in Chinese and steps post exposure by a quarter stop', async () => {
  setLanguage('simplifiedChinese');
  await act(async () => settingsStore.setState({ parametersTab: 'postDev' }));
  const wb = div.querySelector('[data-section=wb2]')!;
  expect(wb.textContent).toContain('色温偏移');
  expect(wb.textContent).toContain('色调偏移');
  const exposure = div.querySelector('[data-testid=adj-exposure] input')!;
  await act(async () => exposure.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true })));
  expect(sessionStore.getState().sidecar.adjustments.exposure).toBe(.25);
});
