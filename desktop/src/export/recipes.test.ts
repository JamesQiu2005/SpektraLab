import { describe, expect, it } from 'vitest';
import { DEFAULT_RECIPES, decodeRecipes, hostFormat, resolveTarget, stem, stockToken } from './recipes';

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
