import { describe, expect, it } from 'vitest';
import { createFrameOrderStore, frameOrderKey } from './frameOrder';
import type { FileEntry } from '../platform';
const files = (names: string[]) => names.map((name) => ({ path: `/owned/roll/${name}.ARW`, name: `${name}.ARW` } as FileEntry));
function storage() { const map = new Map<string, string>(); return { getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => { map.set(k, v); } }; }
describe('filmstrip order', () => {
  it('survives a new store and keeps newly added files after their listed neighbour', () => {
    const disk = storage(), first = createFrameOrderStore(disk);
    first.save('/owned/roll', files(['c', 'a', 'b']));
    const next = createFrameOrderStore(disk).apply('/owned/roll', files(['a', 'new', 'b', 'c']));
    expect(next.map((f) => f.name)).toEqual(['c.ARW', 'a.ARW', 'new.ARW', 'b.ARW']);
  });
  it('never imports missing old files when a single image is opened', () => {
    const store = createFrameOrderStore(storage()); store.save('/owned/roll', files(['c', 'a', 'b']));
    expect(store.apply('/owned/roll', files(['a']))).toEqual(files(['a']));
    expect(store.apply('/owned/other', files(['a', 'b']))).toEqual(files(['a', 'b']));
  });
  it('keys mixed-folder sets by membership and ignores damaged preferences', () => {
    const a = ['/a/1.ARW', '/b/2.ARW'];
    expect(frameOrderKey('/a', a)).toBe(frameOrderKey('/b', [...a].reverse()));
    expect(frameOrderKey('/a', a)).not.toBe(frameOrderKey('/a', ['/a/1.ARW', '/c/3.ARW']));
    const bad = createFrameOrderStore({ getItem: () => 'null', setItem: () => { throw new Error('read-only'); } });
    expect(bad.apply('/owned/roll', files(['a']))).toEqual(files(['a']));
    expect(() => bad.save('/owned/roll', files(['a']))).not.toThrow();
  });
});
