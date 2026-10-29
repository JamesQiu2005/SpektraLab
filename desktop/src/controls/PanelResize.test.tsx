// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { createSettingsStore, settingsStore } from '../state/settings';
import { PanelResize } from './PanelResize';
let root: Root, div: HTMLDivElement;
beforeEach(() => { vi.stubGlobal('React', React); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  settingsStore.setState({ leftWidth: 254, rightWidth: 288 });
  div = document.createElement('div'); document.body.append(div); root = createRoot(div); });
afterEach(async () => { await act(async () => root.unmount()); div.remove(); vi.unstubAllGlobals(); });
it('persists bounded panel widths and repairs old out-of-range preferences', async () => {
  let raw: string | null = JSON.stringify({ leftWidth: 1, rightWidth: 9999 });
  const storage = { getItem: () => raw, setItem: (_k: string, v: string) => { raw = v; } };
  const s = createSettingsStore(storage);
  expect(s.getState()).toMatchObject({ leftWidth: 232, rightWidth: 364 });
  s.getState().set('leftWidth', 9999); s.getState().set('rightWidth', Number.NaN);
  await Promise.resolve();
  expect(createSettingsStore(storage).getState()).toMatchObject({ leftWidth: 380, rightWidth: 288 });
  raw = JSON.stringify({ rightWidth: 268 });
  expect(createSettingsStore(storage).getState().rightWidth).toBe(280);
});
it('supports keyboard resizing in the correct direction and double-click reset', async () => {
  await act(async () => root.render(<><PanelResize side="left" /><PanelResize side="right" /></>));
  const [left, right] = [...div.querySelectorAll('[role=separator]')];
  await act(async () => { for (const el of [left, right]) el!.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); });
  expect(settingsStore.getState()).toMatchObject({ leftWidth: 264, rightWidth: 280 });
  await act(async () => left!.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })));
  expect(left!.getAttribute('aria-valuenow')).toBe('254');
});
