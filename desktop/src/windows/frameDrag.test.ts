// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { installFrameDrag, onFrameDrop } from './frameDrag';

let strip: HTMLDivElement, source: HTMLDivElement, target: HTMLDivElement, canvas: HTMLDivElement;
let enabled: boolean;
let cleanups: (() => void)[];
const reorder = vi.fn(), save = vi.fn(), open = vi.fn(), receive = vi.fn(() => true);
function pointer(type: string, x: number, y: number, element: EventTarget = window) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.assign(event, { clientX: x, clientY: y, pointerId: 1, button: 0 });
  element.dispatchEvent(event);
}
function start() { pointer('pointerdown', 10, 10, source); pointer('pointermove', 30, 30); }
beforeEach(() => {
  vi.useFakeTimers(); vi.clearAllMocks(); enabled = true; cleanups = [];
  strip = document.createElement('div');
  source = document.createElement('div'); target = document.createElement('div'); canvas = document.createElement('div');
  source.className = target.className = 'thumb'; source.dataset.path = 'a.NEF'; target.dataset.path = 'b.NEF';
  strip.append(source, target); document.body.append(strip, canvas);
  source.addEventListener('click', open);
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: vi.fn(() => canvas) });
  cleanups.push(installFrameDrag(strip, { enabled: () => enabled, reorder, save }), onFrameDrop(canvas, receive));
});
afterEach(() => { cleanups.forEach((c) => c()); strip.remove(); canvas.remove(); Reflect.deleteProperty(document, 'elementFromPoint'); vi.restoreAllMocks(); vi.useRealTimers(); });

it('uses pointer coordinates to fill a canvas hole without opening the dragged photograph', () => {
  start(); expect(receive).not.toHaveBeenCalled(); expect(open).not.toHaveBeenCalled();
  pointer('pointerup', 300, 200); source.click();
  expect(receive).toHaveBeenCalledExactlyOnceWith({ path: 'a.NEF', clientX: 300, clientY: 200 });
  expect(open).not.toHaveBeenCalled(); expect(reorder).not.toHaveBeenCalled(); expect(save).not.toHaveBeenCalled();
  vi.runAllTimers(); source.click(); expect(open).toHaveBeenCalledOnce();
});
it('leaves a normal short click and control-click to the filmstrip selection handler', () => {
  pointer('pointerdown', 10, 10, source); pointer('pointermove', 12, 12); pointer('pointerup', 12, 12);
  source.dispatchEvent(new MouseEvent('click', { bubbles: true, ctrlKey: true }));
  expect(open).toHaveBeenCalledOnce(); expect(receive).not.toHaveBeenCalled(); expect(reorder).not.toHaveBeenCalled();
});
it('commits and saves one reorder only on release over a different thumbnail', () => {
  vi.mocked(document.elementFromPoint).mockReturnValue(target);
  start(); expect(reorder).not.toHaveBeenCalled(); pointer('pointerup', 200, 100);
  expect(reorder).toHaveBeenCalledExactlyOnceWith('a.NEF', 'b.NEF'); expect(save).toHaveBeenCalledOnce(); expect(open).not.toHaveBeenCalled();
});
it.each(['escape', 'pointercancel', 'blur'])('cancels with %s without committing a drop or partial reorder', (kind) => {
  start();
  if (kind === 'escape') window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  else window.dispatchEvent(new Event(kind));
  pointer('pointerup', 200, 100);
  expect(receive).not.toHaveBeenCalled(); expect(reorder).not.toHaveBeenCalled(); expect(save).not.toHaveBeenCalled();
});
it('refuses both a new gesture and an in-progress release when batch export locks the editor', () => {
  enabled = false; start(); pointer('pointerup', 300, 200);
  expect(receive).not.toHaveBeenCalled();
  enabled = true; start(); enabled = false; pointer('pointerup', 300, 200);
  expect(receive).not.toHaveBeenCalled(); expect(save).not.toHaveBeenCalled();
});
it('removes global gesture and drop listeners when either UI surface unmounts', () => {
  start(); cleanups.forEach((c) => c()); pointer('pointerup', 300, 200);
  expect(receive).not.toHaveBeenCalled(); expect(save).not.toHaveBeenCalled();
  vi.runAllTimers(); expect(vi.getTimerCount()).toBe(0);
});
it('does not consume external file-drop events while preventing HTML5 thumbnail drag', () => {
  const externalDrop = vi.fn(); window.addEventListener('drop', externalDrop);
  const native = new Event('dragstart', { bubbles: true, cancelable: true }); source.dispatchEvent(native);
  expect(native.defaultPrevented).toBe(true);
  const external = new Event('drop', { bubbles: true, cancelable: true }); canvas.dispatchEvent(external);
  expect(externalDrop).toHaveBeenCalledOnce(); expect(external.defaultPrevented).toBe(false);
  expect(receive).not.toHaveBeenCalled(); window.removeEventListener('drop', externalDrop);
});
