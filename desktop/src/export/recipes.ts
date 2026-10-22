// recipes.ts — an export recipe (`Export/ExportRecipe.swift`): format, depth,
// colour space, size, naming, folder and what to do about an existing file.
// Pure; `recipes.test.ts` pins the naming.

export type ExportFormat = 'jpeg' | 'png' | 'tiff' | 'di';
export type ExportSpace = 'sRGB' | 'display-p3' | 'prophoto' | 'adobe-rgb' | 'rec2020';
export const EXPORT_SPACES: { value: ExportSpace; label: string }[] = [
  { value: 'sRGB', label: 'sRGB' }, { value: 'display-p3', label: 'Display P3' },
  { value: 'adobe-rgb', label: 'Adobe RGB (1998)' }, { value: 'prophoto', label: 'ProPhoto RGB' },
  { value: 'rec2020', label: 'Rec.2020' },
];
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
  /** Absent in older recipes: uncompressed and no extra preview page. */
  tiffCompression?: 'none' | 'lzw';
  embedsPreview?: boolean;
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
      ...(o.tiffCompression !== undefined ? { tiffCompression: o.tiffCompression === 'lzw' ? 'lzw' : 'none' } : {}),
      ...(o.embedsPreview !== undefined ? { embedsPreview: o.embedsPreview === true } : {}),
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
  // Older versions silently saved edits over a built-in ID. Preserve those
  // edits as custom while restoring the preset that the ID/name promises.
  const recovered: ExportRecipe[] = [];
  for (let i = 0; i < out.length; i++) {
    const r = out[i]!;
    const builtin = DEFAULT_RECIPES.find((d) => d.id === r.id);
    if (builtin && JSON.stringify(r) !== JSON.stringify(builtin)) {
      recovered.push({ ...r, id: `custom-recovered-${i}`, name: `${r.name} (custom)` });
      out[i] = structuredClone(builtin);
    }
  }
  return out.length ? [...out, ...recovered] : DEFAULT_RECIPES;
}


export function editRecipe(recipes: ExportRecipe[], current: number, patch: Partial<ExportRecipe>) {
  const index = Math.min(current, recipes.length - 1);
  const r = recipes[index]!;
  if (DEFAULT_RECIPES.some((d) => d.id === r.id)) {
    const id = `custom-${crypto.randomUUID()}`;
    const custom = { ...structuredClone(r), ...patch, id, name: patch.name ?? `${r.name} (custom)` };
    return { recipes: [...recipes, custom], current: recipes.length };
  }
  return { recipes: recipes.map((r, i) => i === index ? { ...r, ...patch } : r), current: index };
}

export function recipeSummary(r: ExportRecipe): string {
  if (r.format === 'di') return 'Digital Intermediate';
  const space = EXPORT_SPACES.find((space) => space.value === r.colorSpace)?.label ?? r.colorSpace;
  return `${r.format.toUpperCase()} · ${r.bitDepth} bit · ${space}`;
}
