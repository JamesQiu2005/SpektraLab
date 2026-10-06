// recipes.ts — an export recipe (`Export/ExportRecipe.swift`): format, depth,
// colour space, size, naming, folder and what to do about an existing file.
// Pure; `recipes.test.ts` pins the naming.

export type ExportFormat = 'jpeg' | 'png' | 'tiff' | 'di';
export type ExportSpace = 'sRGB' | 'display-p3' | 'prophoto';
export type NameToken = 'originalName' | 'filmStock' | 'printStock' | 'date';
export const NAME_TOKENS: NameToken[] = ['originalName', 'filmStock', 'printStock', 'date'];
export type ExistingPolicy = 'addSuffix' | 'overwrite' | 'skip';

export interface ExportRecipe {
  id: string;
  name: string;
  format: ExportFormat;
  bitDepth: 8 | 16;
  colorSpace: ExportSpace;
  quality: number;
  /** 0 = the frame's own size. */
  longEdge: number;
  folder: { kind: 'besideOriginal' } | { kind: 'fixed'; path: string };
  subfolder: string;
  existing: ExistingPolicy;
  naming: { order: NameToken[]; tokens: NameToken[]; separator: string };
}

const naming = (): ExportRecipe['naming'] => ({ order: [...NAME_TOKENS], tokens: ['originalName', 'filmStock', 'printStock'], separator: '_' });

export const DEFAULT_RECIPES: ExportRecipe[] = [
  { id: 'jpeg-p3', name: 'JPEG — Display P3', format: 'jpeg', bitDepth: 8, colorSpace: 'display-p3', quality: 92, longEdge: 0, folder: { kind: 'besideOriginal' }, subfolder: 'SpektraLab', existing: 'addSuffix', naming: naming() },
  { id: 'tiff-prophoto', name: 'TIFF 16-bit — ProPhoto', format: 'tiff', bitDepth: 16, colorSpace: 'prophoto', quality: 100, longEdge: 0, folder: { kind: 'besideOriginal' }, subfolder: 'SpektraLab', existing: 'addSuffix', naming: naming() },
  { id: 'png-srgb', name: 'PNG 8-bit — sRGB', format: 'png', bitDepth: 8, colorSpace: 'sRGB', quality: 100, longEdge: 0, folder: { kind: 'besideOriginal' }, subfolder: 'SpektraLab', existing: 'addSuffix', naming: naming() },
  { id: 'di', name: 'Digital Intermediate', format: 'di', bitDepth: 16, colorSpace: 'display-p3', quality: 100, longEdge: 0, folder: { kind: 'besideOriginal' }, subfolder: '_prints', existing: 'addSuffix', naming: naming() },
];

export const extensionOf = (r: ExportRecipe) => (r.format === 'jpeg' ? 'jpg' : r.format === 'png' ? 'png' : 'tif');

/** The host's `format` for a recipe. PNG is 8-bit only on this host. */
export function hostFormat(r: ExportRecipe): 'tiff16' | 'tiff8' | 'jpeg' | 'png' {
  if (r.format === 'jpeg') return 'jpeg';
  if (r.format === 'png') return 'png';
  return r.bitDepth === 8 ? 'tiff8' : 'tiff16';
}

export interface NameContext {
  originalName: string;
  filmStock: string;
  printStock: string;
  date: Date;
}

const pad = (n: number) => String(n).padStart(2, '0');

/** The filename stem; every token empty falls back to the original name. */
export function stem(r: ExportRecipe, c: NameContext): string {
  const chosen = r.naming.order.filter((t) => r.naming.tokens.includes(t));
  const parts = chosen
    .map((t) => {
      switch (t) {
        case 'originalName':
          return c.originalName;
        case 'filmStock':
          return c.filmStock;
        case 'printStock':
          return c.printStock;
        case 'date':
          return `${c.date.getFullYear()}-${pad(c.date.getMonth() + 1)}-${pad(c.date.getDate())}`;
      }
    })
    .filter((s) => s.length > 0);
  const joined = parts.join(r.naming.separator);
  return (joined || c.originalName).replace(/[/\\:]/g, '-');
}

/** A stock's name as it goes into a file name: spaces to underscores, no maker prefix doubled. */
export const stockToken = (name: string) => name.replace(/^(Kodak|Fujifilm|Fuji)\s+(Professional\s+)?/, '').replace(/\s+/g, '_');

/** The next free name under the policy: `x.jpg`, `x-2.jpg`, `x-3.jpg`… */
export async function resolveTarget(
  dir: string,
  base: string,
  ext: string,
  policy: ExistingPolicy,
  exists: (p: string) => Promise<boolean>,
  join: (d: string, n: string) => string,
): Promise<{ path: string; overwrite: boolean } | null> {
  const first = join(dir, `${base}.${ext}`);
  if (!(await exists(first))) return { path: first, overwrite: false };
  if (policy === 'overwrite') return { path: first, overwrite: true };
  if (policy === 'skip') return null;
  for (let i = 2; i < 10000; i++) {
    const p = join(dir, `${base}-${i}.${ext}`);
    if (!(await exists(p))) return { path: p, overwrite: false };
  }
  return null;
}

export function decodeRecipes(raw: unknown): ExportRecipe[] {
  if (!Array.isArray(raw)) return DEFAULT_RECIPES;
  const out: ExportRecipe[] = [];
  for (const r of raw) {
    if (!r || typeof r !== 'object') continue;
    const o = r as Partial<ExportRecipe>;
    const base = DEFAULT_RECIPES.find((d) => d.format === o.format) ?? DEFAULT_RECIPES[0]!;
    const n = o.naming;
    out.push({
      ...base,
      ...o,
      id: typeof o.id === 'string' ? o.id : `r${out.length}`,
      naming: {
        order: Array.isArray(n?.order) ? [...n.order.filter((t) => NAME_TOKENS.includes(t)), ...NAME_TOKENS.filter((t) => !n.order.includes(t))] : [...NAME_TOKENS],
        tokens: (() => {
          const on = Array.isArray(n?.tokens) ? n.tokens.filter((t) => NAME_TOKENS.includes(t)) : [];
          return on.length ? on : (['originalName'] as NameToken[]);
        })(),
        separator: typeof n?.separator === 'string' ? n.separator : '_',
      },
    } as ExportRecipe);
  }
  return out.length ? out : DEFAULT_RECIPES;
}
