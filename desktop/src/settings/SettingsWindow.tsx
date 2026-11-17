// SettingsWindow.tsx — Settings, 860 × 600, its panes in a list at the left
// (Windows Settings' own pattern; the chosen pane is white) — README §6.5,
// PC-G1–G3. File › Settings… (Ctrl+,) and ··· › Settings…, last.
//
// It is drawn inside the main window rather than as a second Tauri window:
// one webview holds the one session store, so a change shows on the picture
// beside it at once with no cross-window sync (v1's decision, NOTES.md). The
// panes are the HIG's: General, Recipes, Library, Rendering, Engine,
// Diagnostics. The Mac's Memory and Agents panes are not on Windows.

import { useEffect, useState } from 'react';
import { tz } from '../i18n';
import { PillMenu, ToggleRow } from '../controls/controls';
import { settingsStore, useSettings, INTERFACE_SCALES, SETTINGS_DEFAULT } from '../state/settings';
import { setPages, useSession } from '../state/session';
import { platform, type AppPaths } from '../platform';
import { UpdateSettings } from '../windows/SettingsPages';
import { DiagnosticSettings } from '../windows/DiagnosticSettings';
import { NewPhotoDefaultsSettings } from '../windows/NewPhotoDefaultsSettings';
import { DEFAULT_RECIPES, decodeRecipes, recipeSummary, type ExportRecipe } from '../export/recipes';
import { scheduler } from '../scheduler';
import type { BudgetReading } from '../scheduler/types';

type Pane = 'general' | 'recipes' | 'library' | 'rendering' | 'engine' | 'diagnostics';
const PANES: { id: Pane; label: () => string }[] = [
  { id: 'general', label: () => tz('General', '常规') },
  { id: 'recipes', label: () => tz('Recipes', '配方') },
  { id: 'library', label: () => tz('Library', '图库') },
  { id: 'rendering', label: () => tz('Rendering', '渲染') },
  { id: 'engine', label: () => tz('Engine', '引擎') },
  { id: 'diagnostics', label: () => tz('Diagnostics', '诊断') },
];

/** The engine's refusals in the HIG's words (README §3.8, PC-G3). */
export const GATED: { flag: string; name: () => string }[] = [
  { flag: 'overscan', name: () => tz('Film Edge', '片边') },
  { flag: 'overscan', name: () => tz('Half-Frame Pair', '半格拼接') },
  { flag: 'date_imprint', name: () => tz('Date Back', '日期背') },
  { flag: 'scene_latitude_mapping', name: () => tz('Scene Placement', '场景定位') },
  { flag: 'digital_intermediate', name: () => tz('Digital Intermediate', '数字中间片') },
];

function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return <div className="v2-set-group"><div className="v2-set-caps">{title}</div><div className="v2-set-list">{children}</div></div>;
}
function Row({ label, value, children }: { label: string; value?: React.ReactNode; children?: React.ReactNode }) {
  return <div className="v2-set-row"><span className="v2-set-label">{label}</span><span className="v2-set-value">{value}{children}</span></div>;
}

function General({ paths }: { paths: AppPaths | null }) {
  const st = useSettings((s) => s);
  const set = settingsStore.getState().set;
  return <>
    <Group title={tz('GENERAL', '常规')}>
      <Row label={tz('Language', '语言')}>
        <PillMenu label={tz('Language', '语言')} value={st.language} testId="language"
          options={[{ value: 'system', label: tz('System', '跟随系统') }, { value: 'english', label: 'English' }, { value: 'simplifiedChinese', label: '简体中文' }]}
          onChange={(v) => set('language', v)} />
      </Row>
      <Row label={tz('Interface Scale', '界面缩放')}>
        <div className="v2-seg" role="radiogroup" aria-label={tz('Interface Scale', '界面缩放')}>
          {INTERFACE_SCALES.map((x) => <button key={x} role="radio" aria-checked={st.interfaceScale === x} className={st.interfaceScale === x ? 'on' : ''} onClick={() => set('interfaceScale', x)}>{x} %</button>)}
        </div>
      </Row>
      <Row label={tz('When Reopened', '重新打开时')} value={tz('Where You Left Off', '回到上次的位置')} />
    </Group>
    <p className="v2-set-note">{tz('Text size in Windows is read at start. Interface Scale follows it up to 130 %.', 'Windows 的文字大小在启动时读取，界面缩放最多跟随到 130 %。')}</p>
    <Group title={tz('UPDATES', '更新')}><div className="v2-set-host"><UpdateSettings version={paths?.version} os={paths?.os} /></div></Group>
    <Group title={tz('NEW PHOTOGRAPHS', '新照片')}><div className="v2-set-host"><NewPhotoDefaultsSettings /></div></Group>
    <Group title={tz('LAYOUT', '布局')}>
      <Row label={tz('Rails, sections and the filmstrip', '侧栏、分区与胶片条')}>
        <button className="v2-button" data-testid="reset-layout" onClick={() => {
          for (const k of ['interfaceScale', 'leftCollapsed', 'rightCollapsed', 'filmstripCollapsed', 'railLeft', 'railRight', 'navigatorHidden', 'collapsedSections'] as const) set(k, SETTINGS_DEFAULT[k] as never);
        }}>{tz('Reset All Layout', '重置全部布局')}</button>
      </Row>
    </Group>
  </>;
}

function Recipes() {
  const [recipes, setRecipes] = useState<ExportRecipe[]>(DEFAULT_RECIPES);
  const [current, setCurrent] = useState(0);
  useEffect(() => { void platform().storeRead('Export', 'recipes.json').then((r) => setRecipes(decodeRecipes(r))).catch(() => {}); }, []);
  const r = recipes[current] ?? recipes[0]!;
  const size = r.longEdge ? tz(`Long edge ${r.longEdge.toLocaleString('en')} px`, `长边 ${r.longEdge} px`) : tz('Full size', '原尺寸');
  return <>
    <Group title={tz('RECIPES', '配方')}>
      {recipes.map((x, i) => (
        <button key={x.id} className={'v2-set-row choice' + (i === current ? ' on' : '')} data-testid={`recipe-${i}`} onClick={() => setCurrent(i)}>
          <span className="v2-set-label">{x.name}<small>{recipeSummary(x)}</small></span>
          {i === 0 && <span className="v2-set-value dim">{tz('Last used', '上次使用')}</span>}
        </button>
      ))}
    </Group>
    <Group title={r.name.toUpperCase()}>
      <Row label={tz('Format', '格式')} value={`${r.format.toUpperCase()} · ${r.bitDepth}-bit`} />
      <Row label={tz('Size', '尺寸')} value={size} />
      <Row label={tz('Colour', '色彩')} value={r.colorSpace} />
      <Row label={tz('Quality', '质量')} value={String(r.quality)} />
      <Row label={tz('Folder', '文件夹')} value={r.folder.kind === 'besideOriginal' ? tz('Beside the original', '原图旁') : r.folder.path} />
      <Row label={tz('Name', '名称')} value={r.naming.tokens.map((t) => `{${t}}`).join(r.naming.separator)} />
      <Row label={tz('If it exists', '已存在时')} value={r.existing === 'skip' ? tz('Skip', '跳过') : r.existing === 'overwrite' ? tz('Replace', '替换') : tz('Add a number', '加编号')} />
    </Group>
    <p className="v2-set-note">{tz('Recipes are edited in the Export dialog; the changes are kept here.', '配方在导出对话框中编辑，修改会保存在这里。')}</p>
  </>;
}

function Engine() {
  const hello = useSession((s) => s.hello);
  const display = useSession((s) => s.displaySpace);
  const unsupported = useSession((s) => s.unsupported);
  const [budget, setBudget] = useState<BudgetReading | null>(null);
  useEffect(() => {
    let live = true;
    const read = () => void scheduler().budget().then((b) => live && setBudget(b));
    read();
    const id = setInterval(read, 1000);
    return () => { live = false; clearInterval(id); };
  }, []);
  const gated = GATED.filter((g) => unsupported.includes(g.flag));
  return <>
    <Group title={tz('THIS COMPUTER', '这台电脑')}>
      <Row label={tz('Graphics', '显卡')} value={hello?.backend?.device_name ?? '—'} />
      <Row label={tz('Engine', '引擎')} value={`${hello?.backend?.api ?? '—'}  ·  float32`} />
      <Row label={tz('Display', '显示')} value={`${display === 'display-p3' ? 'Display P3' : 'sRGB'}  ·  8-bit`} />
    </Group>
    <Group title={tz('SCHEDULER', '调度器')}>
      <Row label={tz('Running', '运行中')} value={budget ? String(budget.running) : '—'} />
      <Row label={tz('Waiting', '等待中')} value={budget ? String(budget.queued) : '—'} />
      <Row label={tz('Memory budget', '内存预算')} value={budget?.budgetBytes ? `${(budget.budgetBytes / 2 ** 30).toFixed(1)} GB` : tz('Not reported', '未报告')} />
    </Group>
    {gated.length > 0 && <Group title={tz('NOT ON WINDOWS YET', 'WINDOWS 版尚未提供')}>
      {gated.map((g) => <Row key={g.name()} label={g.name()} value={<code>{g.flag}</code>} />)}
    </Group>}
    {gated.length > 0 && <p className="v2-set-note" data-testid="gated-note">{tz('Each appears in its place when the engine has it.', '引擎支持后，每一项都会出现在它的位置上。')}{unsupported.includes('contrast_mask') ? tz(' (contrast_mask has no control on any computer yet.)', '（contrast_mask 在任何电脑上都还没有控件。）') : ''}</p>}
  </>;
}

function Rendering() {
  const st = useSettings((s) => s);
  const set = settingsStore.getState().set;
  return <>
    <Group title={tz('FILM EFFECTS', '胶片效果')}>
      <div className="v2-set-host">
        <ToggleRow label={tz('Crop re-maps the frame', '裁剪重新映射画幅')} on={st.recalculateEffectsAfterCrop} onChange={(v) => set('recalculateEffectsAfterCrop', v)} />
      </div>
    </Group>
    <p className="v2-set-note">{tz('There is no preview size to choose: the Windows host renders the whole frame.', '没有预览尺寸可选：Windows 版引擎总是渲染整张照片。')}</p>
  </>;
}

function LibraryPane() {
  return <Group title={tz('LIBRARY', '图库')}>
    <Row label={tz('New catalogs go to', '新目录位置')} value="Pictures\SpektraLab" />
    <Row label={tz('Capture One', 'Capture One')} value={tz('Read-only; refreshed on open', '只读；打开时刷新')} />
  </Group>;
}

export function SettingsWindow() {
  const open = useSession((s) => s.settingsOpen);
  const pane = useSettings((s) => s.settingsPane) as Pane;
  const hello = useSession((s) => s.hello);
  const [paths, setPaths] = useState<AppPaths | null>(null);
  useEffect(() => { if (open) void platform().appPaths().then(setPaths).catch(() => {}); }, [open]);
  if (!open) return null;
  const current = PANES.find((p) => p.id === pane) ?? PANES[0]!;
  return (
    <div className="v2-smoke" data-testid="settings" onPointerDown={(e) => { if (e.target === e.currentTarget) setPages({ settingsOpen: false }); }}>
      <div className="v2-settings" role="dialog" aria-modal="true" aria-label={tz('Settings', '设置')}>
        <div className="v2-settings-title">{tz('Settings', '设置')}
          <button className="v2-caption close" aria-label={tz('Close', '关闭')} data-testid="settings-close" onClick={() => setPages({ settingsOpen: false })}>
            <svg width="10" height="10"><path d="M0 0l10 10M10 0L0 10" stroke="currentColor" /></svg>
          </button>
        </div>
        <nav className="v2-panes" aria-label={tz('Settings', '设置')}>
          {PANES.map((p) => <button key={p.id} className={p.id === current.id ? 'on' : ''} aria-current={p.id === current.id || undefined} data-testid={`pane-${p.id}`}
            onClick={() => settingsStore.getState().set('settingsPane', p.id)}>{p.label()}</button>)}
        </nav>
        <div className="v2-pane" data-testid={`settings-${current.id}`}>
          <h2>{current.label()}</h2>
          {current.id === 'general' && <General paths={paths} />}
          {current.id === 'recipes' && <Recipes />}
          {current.id === 'library' && <LibraryPane />}
          {current.id === 'rendering' && <Rendering />}
          {current.id === 'engine' && <Engine />}
          {current.id === 'diagnostics' && <div className="v2-set-host"><DiagnosticSettings paths={paths} hello={hello} includePaths={false} /></div>}
        </div>
      </div>
    </div>
  );
}
