// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { GEOMETRY_DEFAULT } from '@shared/geometry';

const fake = vi.hoisted(() => ({ thumbnail: vi.fn(), url: vi.fn(), state: {} as Record<string, unknown> }));
vi.mock('../host/client', () => ({ host: () => ({ thumbnail: fake.thumbnail }) }));
vi.mock('../state/frames', () => ({ rgbaToURL: fake.url }));
vi.mock('../state/session', () => ({
  click: vi.fn(), moveFrame: vi.fn(), saveFrameOrder: vi.fn(), selectRelative: vi.fn(),
  sessionStore: { getState: () => fake.state },
  useSession: <T,>(selector: (state: typeof fake.state) => T) => selector(fake.state),
}));
vi.mock('./frameDrag', () => ({ installFrameDrag: () => () => {} }));
vi.mock('../i18n', () => ({ t: (key: string) => key }));

let root: Root;
let container: HTMLDivElement;
let callback: IntersectionObserverCallback;
let options: IntersectionObserverInit | undefined;
const observed = new Set<Element>();
const disconnect = vi.fn(() => observed.clear());

beforeEach(() => {
  vi.resetModules(); vi.clearAllMocks(); observed.clear();
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('React', React);
  vi.stubGlobal('IntersectionObserver', class {
    constructor(cb: IntersectionObserverCallback, opts?: IntersectionObserverInit) { callback = cb; options = opts; }
    observe(element: Element) { observed.add(element); }
    disconnect = disconnect;
  });
  fake.state = { frames: Array.from({ length: 100 }, (_, i) => ({ path: `/${i}.ARW`, name: `${i}.ARW` })),
    selection: null, picked: [], sidecar: { geometry: GEOMETRY_DEFAULT }, savedGeometry: {}, batchExporting: false };
  fake.thumbnail.mockResolvedValue({}); fake.url.mockResolvedValue(null);
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

it('does not request a whole imported folder before visibility is known; requests nearby cells as they enter', async () => {
  const { Filmstrip } = await import('./Filmstrip');
  await act(async () => root.render(<Filmstrip />));
  expect(observed.size).toBe(100);
  expect(options).toMatchObject({ root: container.querySelector('.filmstrip-cells'), rootMargin: '0px 320px' });
  expect(fake.thumbnail).not.toHaveBeenCalled();
  const cells = [...observed];
  await act(async () => callback([
    { target: cells[0], isIntersecting: true }, { target: cells[1], isIntersecting: true },
    { target: cells[99], isIntersecting: false },
  ] as IntersectionObserverEntry[], {} as IntersectionObserver));
  expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/0.ARW', '/1.ARW']);
  await act(async () => callback([
    { target: cells[0], isIntersecting: false }, { target: cells[1], isIntersecting: false },
    { target: cells[50], isIntersecting: true },
  ] as IntersectionObserverEntry[], {} as IntersectionObserver));
  expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/0.ARW', '/1.ARW', '/50.ARW']);
});

it('uses a bounded geometry fallback when IntersectionObserver is unavailable', async () => {
  vi.stubGlobal('IntersectionObserver', undefined);
  vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
    const left = this.classList.contains('filmstrip-cells') ? 0 : Number((this as HTMLElement).dataset.path?.match(/\d+/)?.[0]) * 120;
    const width = this.classList.contains('filmstrip-cells') ? 200 : 100;
    return { left, right: left + width, top: 0, bottom: 100, width, height: 100, x: left, y: 0, toJSON: () => ({}) };
  });
  const { Filmstrip } = await import('./Filmstrip');
  await act(async () => root.render(<Filmstrip />));
  expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/0.ARW', '/1.ARW', '/2.ARW', '/3.ARW', '/4.ARW']);
});

it('keeps independent export cells subscribed to completed thumbnails', async () => {
  const { Thumb } = await import('./Filmstrip');
  const { thumbs } = await import('../state/thumbs');
  await act(async () => root.render(<Thumb path="/export.ARW" geometry={GEOMETRY_DEFAULT} />));
  expect(fake.thumbnail).toHaveBeenCalledWith('/export.ARW', 320);
  expect(container.querySelector('canvas')).toBeNull();
  await act(async () => thumbs.setPrint('/export.ARW', 'blob:printed'));
  expect(container.querySelector('canvas')).not.toBeNull();
});

it('rebuilds visible requests after replacing a library while selection has paused the queue', async () => {
  const { Filmstrip } = await import('./Filmstrip');
  const { thumbs } = await import('../state/thumbs');
  thumbs.setPaused(true);
  await act(async () => root.render(<Filmstrip />));
  await act(async () => callback([{ target: [...observed][0], isIntersecting: true }] as IntersectionObserverEntry[], {} as IntersectionObserver));
  thumbs.reset();
  fake.state = { ...fake.state, frames: [{ path: '/new.ARW', name: 'new.ARW' }] };
  await act(async () => root.render(<Filmstrip />));
  await act(async () => callback([{ target: [...observed][0], isIntersecting: true }] as IntersectionObserverEntry[], {} as IntersectionObserver));
  expect(fake.thumbnail).not.toHaveBeenCalled();
  await act(async () => thumbs.setPaused(false));
  expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/new.ARW']);
});
