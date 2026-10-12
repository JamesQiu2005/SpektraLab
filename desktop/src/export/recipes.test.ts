import { describe, expect, it } from 'vitest';
import { DEFAULT_RECIPES, editRecipe, decodeRecipes, hostFormat, resolveTarget, stem, stockToken } from './recipes';

const ctx = { originalName: 'image_1', filmStock: 'Portra_400', printStock: 'Vision_2383', date: new Date(2026, 9, 6) };

describe('export recipes', () => {
  it('names a file from the chosen tokens in the row order', () => {
    const r = DEFAULT_RECIPES[0]!;
    expect(stem(r, ctx)).toBe('image_1_Portra_400_Vision_2383');
    const dated = { ...r, naming: { ...r.naming, tokens: ['date', 'originalName'] as const, order: ['date', 'originalName', 'filmStock', 'printStock'] as const } };
    expect(stem(dated as never, ctx)).toBe('2026-10-06_image_1');
    expect(stem({ ...r, naming: { ...r.naming, tokens: ['filmStock'] } }, { ...ctx, filmStock: '' })).toBe('image_1');
    expect(stem(r, { ...ctx, originalName: 'a/b:c' })).toContain('a-b-c');
  });

  it('a stock name becomes a token', () => {
    expect(stockToken('Kodak Portra 400')).toBe('Portra_400');
    expect(stockToken('Kodak Professional Portra Endura')).toBe('Portra_Endura');
  });

  it('existing files: suffix, overwrite, skip', async () => {
    const taken = new Set(['/o/x.jpg', '/o/x-2.jpg']);
    const exists = async (p: string) => taken.has(p);
    const join = (d: string, n: string) => `${d}/${n}`;
    expect(await resolveTarget('/o', 'x', 'jpg', 'addSuffix', exists, join)).toEqual({ path: '/o/x-3.jpg', overwrite: false });
    expect(await resolveTarget('/o', 'x', 'jpg', 'overwrite', exists, join)).toEqual({ path: '/o/x.jpg', overwrite: true });
    expect(await resolveTarget('/o', 'x', 'jpg', 'skip', exists, join)).toBeNull();
    expect(await resolveTarget('/o', 'y', 'jpg', 'skip', exists, join)).toEqual({ path: '/o/y.jpg', overwrite: false });
  });

  it('host formats', () => {
    expect(DEFAULT_RECIPES.map(hostFormat)).toEqual(['jpeg', 'tiff16', 'png', 'tiff16']);
  });

  it('reads a hand-edited file leniently', () => {
    expect(decodeRecipes('nonsense')).toBe(DEFAULT_RECIPES);
    const r = decodeRecipes([{ name: 'Mine', format: 'png', naming: { tokens: ['bogus'] } }]);
    expect(r[0]!.name).toBe('Mine');
    expect(r[0]!.naming.order).toHaveLength(4);
  });
});


it('editing a built-in recipe creates a selected custom copy; the original still means its name', () => {
  const original = structuredClone(DEFAULT_RECIPES);
  const edited = editRecipe(original, 0, { format: 'png', bitDepth: 8, colorSpace: 'sRGB' });
  expect(edited.recipes[0]).toEqual(DEFAULT_RECIPES[0]);
  expect(edited.current).toBe(original.length);
  expect(edited.recipes[edited.current]).toMatchObject({ format: 'png', colorSpace: 'sRGB' });
  expect(edited.recipes[edited.current]!.id).not.toBe(DEFAULT_RECIPES[0]!.id);
  const again = editRecipe(edited.recipes, edited.current, { quality: 100 });
  expect(again.recipes).toHaveLength(edited.recipes.length);
  expect(again.recipes[again.current]!.quality).toBe(100);
});
it('restores a previously changed built-in without losing its custom settings', () => {
  const restored = decodeRecipes([{ ...DEFAULT_RECIPES[0], format: 'png', colorSpace: 'sRGB' }]);
  expect(restored.find((r) => r.id === 'jpeg-p3')).toEqual(DEFAULT_RECIPES[0]);
  expect(restored.some((r) => r.id !== 'jpeg-p3' && r.format === 'png' && r.colorSpace === 'sRGB')).toBe(true);
});
