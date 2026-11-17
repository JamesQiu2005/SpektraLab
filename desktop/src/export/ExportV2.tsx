// ExportV2.tsx — Export drawn as win_export.svg draws it (PC-O1): an 800 × 560
// ContentDialog — the title and what is exported; the proof in a 300 × 400
// well at the left with its size under it; at the right RECIPE (the recipes
// as capsules, + New) and two grouped cards of rows, the recipe's settings
// and SAVE TO, each value a drop-down; Export (accent) and Cancel in the
// footer band. The model — the recipes, the proof, the frozen batch — is
// ExportPage's: this file draws it and nothing else.

import type { ReactNode, RefObject } from 'react';
import { tz } from '../i18n';
import { baseName } from '../platform';
import { MenuButton } from '../edit/rails';
import { Glyph as G } from '../theme/Glyph';
import type { MenuEntry } from '../app/commands';
import { EXPORT_SPACES, NAME_TOKENS, type ExportRecipe, type NameToken } from './recipes';
import type { ExportOutcome } from './exporter';
import { hostMessage } from '../host/messages';

export interface ExportV2Props {
  recipes: ExportRecipe[];
  current: number;
  recipe: ExportRecipe;
  frames: string[];
  selection: string | null;
  sample: string;
  proofRef: RefObject<HTMLCanvasElement | null>;
  proofShown: boolean;
  proofMessage: string;
  proofSize: { width: number; height: number; space: string } | null;
  frameSize: { width: number; height: number } | null;
  supported: boolean;
  spaces: string[];
  digitalIntermediate: boolean;
  status: string;
  log: { name: string; outcome: ExportOutcome }[];
  tokenLabel: Record<NameToken, () => string>;
  choose: (i: number) => void;
  edit: (patch: Partial<ExportRecipe>) => void;
  add: () => void;
  remove: () => void;
  restore: () => void;
  exportCube: () => void;
  pickFolder: () => void;
  run: () => void;
  cancel: () => void;
}

const LONG_EDGES = [0, 2048, 3000, 3840, 6000];

/** A recipe's capsule (PC-O1: "JPEG · sRGB", "TIFF · sRGB · 16-bit"): what it writes, in the fewest words; its name is the tooltip. */
export function recipeWords(r: ExportRecipe): string {
  if (r.format === 'di') return 'DI';
  const space = r.colorSpace === 'display-p3' ? 'P3' : EXPORT_SPACES.find((s) => s.value === r.colorSpace)?.label.replace(/ RGB.*$/, '') ?? r.colorSpace;
  return `${r.format.toUpperCase()} · ${space}${r.format === 'tiff' ? ` · ${r.bitDepth}-bit` : ''}`;
}
const spaceWords = (v: string) => EXPORT_SPACES.find((s) => s.value === v || s.value.toLowerCase() === v.toLowerCase())?.label ?? v;
const QUALITIES = [70, 80, 90, 95, 100];

/** A row of a grouped card: the label at the left, the value at the right and, when it can change, its ⌄ and menu. */
function Row({ label, value, items, testId, dim }: { label: string; value: string; items?: () => MenuEntry[]; testId?: string; dim?: boolean }) {
  return (
    <div className="v2-x-row" data-testid={testId}>
      <span className="v2-x-label">{label}</span>
      {items
        ? <MenuButton className="v2-x-value" label={`${label}: ${value}`} align="right" items={items}><span>{value}</span><G name="chevronDown" /></MenuButton>
        : <span className={'v2-x-value fixed' + (dim ? ' dim' : '')}>{value}</span>}
    </div>
  );
}

const Card = ({ children }: { children: ReactNode }) => <div className="v2-x-card">{children}</div>;

const pick = (id: string, label: string, on: boolean, run: () => void, enabled = true): MenuEntry => ({ id, label, run, enabled, checked: on });

export function ExportV2(p: ExportV2Props) {
  const r = p.recipe;
  const n = p.frames.length;
  const what = n === 1 && p.selection ? `${baseName(p.selection).replace(/\.[^.]+$/, '')}  ·  ${tz('1 frame', '1 张')}` : tz(`${n} frames`, `${n} 张`);
  const formatWords = r.format === 'di' ? tz('Digital Intermediate', '数字中间片') : `${r.format.toUpperCase()} · ${r.bitDepth}-bit`;
  const space = EXPORT_SPACES.find((s) => s.value === r.colorSpace)?.label ?? r.colorSpace;
  const offered = EXPORT_SPACES.filter((s) => p.spaces.includes(s.value));
  const size = r.longEdge === 0 ? tz('Original size', '原始尺寸') : tz(`Long edge ${r.longEdge.toLocaleString('en-US')} px`, `长边 ${r.longEdge.toLocaleString('en-US')} px`);
  const folder = r.folder.kind === 'fixed' ? baseName(r.folder.path) || r.folder.path : tz('Beside the original', '原图旁');
  const existing = r.existing === 'skip' ? tz('Skip', '跳过') : r.existing === 'overwrite' ? tz('Overwrite', '覆盖') : tz('Add a number', '添加编号');
  const name = p.sample.replace(/\.[^.]+$/, '') || '—';
  return (
    <div className="v2-x" data-testid="export-page">
      <div className="v2-x-head">
        <b>{tz('Export', '导出')}</b>
        <span className="dim">{what}</span>
        {p.status && <span className="v2-x-status" data-testid="export-status">{p.status}</span>}
      </div>
      <div className="v2-x-body">
        <div className="v2-x-left">
          <div className="v2-x-proof">
            <canvas ref={p.proofRef} data-testid="export-proof" style={{ display: p.proofShown ? undefined : 'none' }} />
            {!p.proofShown && <span className="dim v2-x-wait" role="status">{p.proofMessage || tz('No proof yet', '尚无软打样')}</span>}
          </div>
          <div className="v2-x-size dim" data-testid="proof-stats">
            {p.proofSize ? `${p.proofSize.width.toLocaleString('en-US')} × ${p.proofSize.height.toLocaleString('en-US')}  ·  ${spaceWords(p.proofSize.space)}`
              : p.frameSize ? `${p.frameSize.width.toLocaleString('en-US')} × ${p.frameSize.height.toLocaleString('en-US')}  ·  ${space}` : ''}
          </div>
        </div>
        <div className="v2-x-right">
          <div className="v2-caps-head">{tz('RECIPE', '配方')}</div>
          <div className="v2-x-recipes" role="radiogroup" aria-label={tz('Recipe', '配方')}>
            {/* A recipe the engine cannot write (a refused Digital Intermediate) is absent, not dimmed (README §3.8). */}
            {p.recipes.map((x, i) => (x.format === 'di' && !p.digitalIntermediate ? null :
              <button key={x.id} role="radio" aria-checked={i === p.current} className={'v2-chip' + (i === p.current ? ' on' : '')} onClick={() => p.choose(i)} title={x.name}>{recipeWords(x)}</button>
            ))}
            <MenuButton className="v2-chip" label={tz('New recipe', '新建配方')} testId="recipe-new" items={() => [
              { id: 'recipe-copy', label: tz('New Recipe from This One', '以此配方新建'), run: p.add, enabled: true },
              { id: 'recipe-remove', label: tz('Remove This Recipe', '删除此配方'), run: p.remove, enabled: p.recipes.length > 1 },
              { separator: true },
              { id: 'recipe-restore', label: tz('Restore the Built-in Recipes', '恢复内置配方'), run: p.restore, enabled: true },
              { id: 'recipe-cube', label: tz('Export the Print as a .cube LUT…', '将相纸导出为 .cube LUT…'), run: p.exportCube, enabled: true },
            ]}><span>{tz('+ New', '+ 新建')}</span></MenuButton>
          </div>
          <Card>
            <Row label={tz('Format', '格式')} value={formatWords} testId="recipe-summary" items={() => [
              pick('f-jpeg', 'JPEG · 8-bit', r.format === 'jpeg', () => p.edit({ format: 'jpeg', bitDepth: 8 })),
              pick('f-png', 'PNG · 8-bit', r.format === 'png', () => p.edit({ format: 'png', bitDepth: 8 })),
              pick('f-tiff8', 'TIFF · 8-bit', r.format === 'tiff' && r.bitDepth === 8, () => p.edit({ format: 'tiff', bitDepth: 8 })),
              pick('f-tiff16', 'TIFF · 16-bit', r.format === 'tiff' && r.bitDepth === 16, () => p.edit({ format: 'tiff', bitDepth: 16 })),
              ...(p.digitalIntermediate ? [pick('f-di', tz('Digital Intermediate', '数字中间片'), r.format === 'di', () => p.edit({ format: 'di', bitDepth: 16 }))] : []),
            ]} />
            <Row label={tz('Size', '尺寸')} value={size} items={() => LONG_EDGES.map((e) => pick(`s-${e}`, e === 0 ? tz('Original size', '原始尺寸') : tz(`Long edge ${e.toLocaleString('en-US')} px`, `长边 ${e.toLocaleString('en-US')} px`), r.longEdge === e, () => p.edit({ longEdge: e })))} />
            <Row label={tz('Colour', '色彩')} value={r.format === 'di' ? 'Cineon' : space} dim
              items={offered.length > 1 && r.format !== 'di' ? () => offered.map((s) => pick(`c-${s.value}`, s.label, r.colorSpace === s.value, () => p.edit({ colorSpace: s.value }))) : undefined} />
            <Row label={tz('Quality', '质量')} value={r.format === 'jpeg' ? String(r.quality) : '—'} dim={r.format !== 'jpeg'}
              items={r.format === 'jpeg' ? () => QUALITIES.map((q) => pick(`q-${q}`, String(q), r.quality === q, () => p.edit({ quality: q }))) : undefined} />
          </Card>
          <div className="v2-caps-head">{tz('SAVE TO', '存储到')}</div>
          <Card>
            <Row label={tz('Folder', '文件夹')} value={folder} items={() => [
              pick('d-beside', tz('Beside the original', '原图旁'), r.folder.kind === 'besideOriginal', () => p.edit({ folder: { kind: 'besideOriginal' } })),
              pick('d-choose', tz('Choose a Folder…', '选择文件夹…'), r.folder.kind === 'fixed', p.pickFolder),
            ]} />
            <Row label={tz('Name', '名称')} value={name} testId="export-sample" items={() => NAME_TOKENS.map((tok) => pick(`n-${tok}`, p.tokenLabel[tok](), r.naming.tokens.includes(tok), () => {
              const on = r.naming.tokens.includes(tok) ? r.naming.tokens.filter((x) => x !== tok) : [...r.naming.tokens, tok];
              if (on.length) p.edit({ naming: { ...r.naming, tokens: NAME_TOKENS.filter((x) => on.includes(x)) } });
            }))} />
            <Row label={tz('If it exists', '如已存在')} value={existing} items={() => [
              pick('e-suffix', tz('Add a number', '添加编号'), r.existing === 'addSuffix', () => p.edit({ existing: 'addSuffix' })),
              pick('e-skip', tz('Skip', '跳过'), r.existing === 'skip', () => p.edit({ existing: 'skip' })),
              pick('e-over', tz('Overwrite', '覆盖'), r.existing === 'overwrite', () => p.edit({ existing: 'overwrite' })),
            ]} />
          </Card>
          {p.log.length > 0 && <div className="v2-x-log">{p.log.map((l, i) => (
            <div key={i} className={l.outcome.kind === 'failed' ? 'danger' : 'dim'}>
              {l.name}: {l.outcome.kind === 'written' ? baseName(l.outcome.path) : l.outcome.kind === 'skipped' ? tz('skipped', '已跳过') : l.outcome.kind === 'cancelled' ? tz('cancelled', '已取消') : hostMessage(l.outcome.message)}
            </div>
          ))}</div>}
        </div>
      </div>
      <div className="v2-x-foot">
        <button className="v2-x-button accent" data-testid="export-run" disabled={!n || !p.supported} onClick={p.run}>{tz('Export', '导出')}</button>
        <button className="v2-x-button" data-testid="export-cancel" onClick={p.cancel}>{tz('Cancel', '取消')}</button>
      </div>
    </div>
  );
}
