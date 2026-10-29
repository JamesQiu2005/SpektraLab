// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
vi.mock('../state/session', () => ({ beginGesture: vi.fn() }));
import { NumberField, ScrubSlider, signed } from './controls';

let root: Root, div: HTMLDivElement;
beforeEach(() => {
  vi.stubGlobal('React', React); vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  div = document.createElement('div'); document.body.append(div); root = createRoot(div);
});
afterEach(async () => { await act(async () => root.unmount()); div.remove(); vi.unstubAllGlobals(); });

async function type(field: HTMLInputElement, value: string) {
  await act(async () => field.focus());
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(field, value);
    field.dispatchEvent(new Event('input', { bubbles: true }));
  });
}
async function enter(field: HTMLInputElement) {
  await act(async () => field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
}

it('keeps a formatted negative slider value negative when focused and committed unchanged', async () => {
  const change = vi.fn();
  await act(async () => root.render(<ScrubSlider label="Exposure" value={-2} range={[-5, 5]} format={signed(1)} onChange={change} />));
  const field = div.querySelector('input')!;
  await act(async () => field.focus());
  await enter(field);
  expect(change).toHaveBeenLastCalledWith(-2);
});

it.each(['-2.5', '−2,5'])('commits signed slider input %s on Enter and ordinary blur', async (draft) => {
  const change = vi.fn();
  await act(async () => root.render(<ScrubSlider label="Angle" value={0} range={[-5, 5]} format={(v) => signed(1)(v) + '°'} onChange={change} />));
  const field = div.querySelector('input')!;
  await type(field, draft + '°'); await enter(field);
  expect(change).toHaveBeenLastCalledWith(-2.5);
  await type(field, draft + '°'); await act(async () => field.blur());
  expect(change).toHaveBeenCalledTimes(2);
  expect(change).toHaveBeenLastCalledWith(-2.5);
});

it('accepts Unicode minus and decimal comma in unit fields', async () => {
  const commit = vi.fn();
  await act(async () => root.render(<NumberField value={0} decimals={1} onCommit={commit} />));
  const field = div.querySelector('input')!;
  await type(field, '−2,5'); await enter(field);
  expect(commit).toHaveBeenLastCalledWith(-2.5);
});

it('does not submit a unit draft after its control becomes disabled', async () => {
  const commit = vi.fn();
  await act(async () => root.render(<NumberField value={24} decimals={1} onCommit={commit} />));
  const field = div.querySelector('input')!;
  await type(field, '50');
  await act(async () => root.render(<NumberField value={24} decimals={1} onCommit={commit} disabled />));
  await enter(field);
  await act(async () => field.dispatchEvent(new FocusEvent('focusout', { bubbles: true })));
  expect(commit).not.toHaveBeenCalled();
});
