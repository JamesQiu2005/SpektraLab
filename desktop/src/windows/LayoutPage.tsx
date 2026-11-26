// LayoutPage.tsx — Develop's multi-photo layouts (shared/layouts.ts): pick a template (diptych, triptych,
// grids, one large and two small, cinematic 2.39:1 stills), put a photograph in each cell from the
// filmstrip or from anywhere, move and enlarge it in its cell, set the gap, the border and their grey,
// and export the sheet: each photograph developed with its own film, paper and edit (layoutExport.ts).
// The preview places the filmstrip's thumbnails with the export's own `coverPlacement`.

import { useEffect, useRef, useState } from 'react';
import { PillMenu, ScrubSlider } from '../controls/controls';
import { tz } from '../i18n';
import { addFrames, setPages, useSession } from '../state/session';
import { thumbs } from '../state/thumbs';
import { platform } from '../platform';
import { type CellPhoto, type LayoutDoc, LAYOUT_ASPECTS, LAYOUT_DEFAULT, LAYOUT_TEMPLATES, cellRects, coverPlacement, decodeLayout, sheetSize, templateOf } from '@shared/layouts';
import { exportLayout } from '../export/layoutExport';
import { SHARED_PICTURES, destination } from '../export/exporter';
import type { ExportSpace } from '../export/recipes';

const KEY = 'develop.layout';
function loadDoc(): LayoutDoc {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? decodeLayout(JSON.parse(raw)) : LAYOUT_DEFAULT;
  } catch {
    return LAYOUT_DEFAULT;
  }
}

const baseName = (p: string) => p.split(/[\\/]/).pop() ?? p;

/** One cell of the preview: the photograph's thumbnail placed as the export places it. */
function CellView({ photo, w, h }: { photo: CellPhoto | null; w: number; h: number }) {
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  useSession((s) => s.thumbVersion);
  const url = photo ? thumbs.get(photo.path) : null;
  if (!photo) return <div className="layout-empty">{tz('Click to choose a photograph', '点击选择照片')}</div>;
  if (!url) return <div className="layout-empty">{baseName(photo.path)}</div>;
  const p = natural ? coverPlacement(natural.w, natural.h, w, h, photo) : null;
  return (
    <img
      src={url}
      alt=""
      draggable={false}
      onLoad={(e) => setNatural({ w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight })}
      style={p ? { position: 'absolute', left: p.ox, top: p.oy, width: p.w, height: p.h } : { width: '100%', height: '100%', objectFit: 'cover' }}
    />
  );
}

export function LayoutPage() {
  const open = useSession((s) => s.layoutOpen);
  const frames = useSession((s) => s.frames);
  const [doc, setDoc] = useState<LayoutDoc>(loadDoc);
  const [active, setActive] = useState(0);
  const [format, setFormat] = useState<'jpeg' | 'png' | 'tiff16'>('jpeg');
  const [space, setSpace] = useState<ExportSpace>('sRGB');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const area = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ w: 800, h: 600 });

  useEffect(() => {
    try {
      localStorage.setItem(KEY, JSON.stringify(doc));
    } catch {
      /* the layout lasts the session */
    }
  }, [doc]);
  useEffect(() => {
    const el = area.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth - 48, h: el.clientHeight - 48 }));
    ro.observe(el);
    return () => ro.disconnect();
  }, [open]);

  if (!open) return null;
  const t = templateOf(doc.template);
  const cells = t.cells.map((_, i) => doc.cells[i] ?? null);
  const sheet = sheetSize(doc, 1000);
  const k = Math.min(box.w / sheet.width, box.h / sheet.height);
  const pw = Math.max(1, Math.round(sheet.width * k)), ph = Math.max(1, Math.round(sheet.height * k));
  const rects = cellRects(doc, pw, ph);
  const grey = Math.round(doc.tone * 255);
  const cur = cells[active] ?? null;

  const set = (patch: Partial<LayoutDoc>) => setDoc((d) => ({ ...d, ...patch }));
  const setCell = (i: number, photo: CellPhoto | null) =>
    setDoc((d) => {
      const next = templateOf(d.template).cells.map((_, j) => d.cells[j] ?? null);
      next[i] = photo;
      return { ...d, cells: next };
    });
  const putPhoto = (path: string) => setCell(active, { path, panX: 0, panY: 0, zoom: 1 });
  const importPhotos = async () => {
    const files = await platform().pickFiles(tz('Add photographs to the layout', '为排版添加照片'));
    if (!files.length) return;
    addFrames(files);
    // fill the empty cells from the chosen cell on
    setDoc((d) => {
      const next = templateOf(d.template).cells.map((_, j) => d.cells[j] ?? null);
      let f = 0;
      for (let j = active; j < next.length && f < files.length; j++) if (!next[j] || j === active) next[j] = { path: files[f++]!, panX: 0, panY: 0, zoom: 1 };
      return { ...d, cells: next };
    });
  };
  const runExport = async () => {
    const ext = format === 'tiff16' ? 'tif' : format === 'png' ? 'png' : 'jpg';
    // Android: no save dialog that gives a path; the sheet goes to Pictures/Develop (exporter.ts destination).
    const d = platform().shared ? await destination('', 'Layout', ext, 'addSuffix', SHARED_PICTURES) : null;
    if (d && 'skipped' in d) return;
    const target = d ? d.write : await platform().pickSave(tz('Export the layout', '导出排版'), `Layout.${ext}`, ext);
    if (!target) return;
    setBusy(true);
    try {
      const r = await exportLayout({ ...doc, cells }, { path: target, format, quality: 92, colorSpace: space }, (done, total, name) =>
        setStatus(name ? tz(`Developing ${name} (${done + 1} of ${total})…`, `正在冲洗 ${name}（${done + 1}/${total}）…`) : tz('Writing…', '正在写入…')),
      );
      const where = d ? await d.finish(r.path) : baseName(r.path);
      setStatus(tz(`Written: ${where}, ${r.width} × ${r.height}`, `已写入：${where}，${r.width} × ${r.height}`));
    } catch (e) {
      setStatus(tz('Not written: ', '未写入：') + (e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="export-page" data-testid="layout-page">
      <div className="topbar">
        <span style={{ fontWeight: 700, fontSize: 'var(--fs-rail-title)' }}>{tz('Layout', '排版')}</span>
        <span className="bar-status">{status}</span>
        <button className="btn" disabled={busy} onClick={() => setPages({ layoutOpen: false })} style={{ marginRight: 8 }}>
          {tz('Close', '关闭')}
        </button>
        <button className="btn" disabled={busy || cells.every((c) => !c)} onClick={() => void runExport()}>
          {busy ? tz('Exporting…', '正在导出…') : tz('Export…', '导出…')}
        </button>
      </div>
      <div className="export-body">
        <div className="export-strip" style={{ borderLeft: 'none', borderRight: '1px solid var(--rule-region)' }}>
          <div className="caption">{tz('Template', '模板')}</div>
          <div className="layout-templates">
            {LAYOUT_TEMPLATES.map((tp) => (
              <button key={tp.id} className={'btn' + (tp.id === doc.template ? ' on' : '')} onClick={() => set({ template: tp.id })} title={tp.name}>
                <svg viewBox="0 0 30 20" width="48" height="32" aria-hidden="true">
                  {tp.cells.map((c, i) => (
                    <rect key={i} x={1 + c.x * 28 + 0.6} y={1 + c.y * 18 + 0.6} width={c.w * 28 - 1.2} height={c.h * 18 - 1.2} fill="currentColor" opacity={0.75} />
                  ))}
                </svg>
                <span>{tp.name}</span>
              </button>
            ))}
          </div>
          <PillMenu label={tz('Shape', '画幅')} value={doc.aspect} fill options={LAYOUT_ASPECTS.map((a) => ({ value: a.id, label: a.id === 'auto' ? tz('The template’s', '模板默认') : a.name }))} onChange={(v) => set({ aspect: v })} />
          <ScrubSlider label={tz('Gap', '间距')} value={doc.gap} range={[0, 10]} zero={1.5} snap={0.25} format={(v) => v.toFixed(2)} onChange={(v) => set({ gap: v })} />
          <ScrubSlider label={tz('Border', '边框')} value={doc.margin} range={[0, 15]} zero={3} snap={0.25} format={(v) => v.toFixed(2)} onChange={(v) => set({ margin: v })} />
          <ScrubSlider label={tz('Tone', '明暗')} sublabel={tz('0 black · 100 white', '0 黑 · 100 白')} value={doc.tone * 100} range={[0, 100]} zero={100} snap={5} format={(v) => v.toFixed(0)} onChange={(v) => set({ tone: v / 100 })} />
          <ScrubSlider label={tz('Long Edge', '长边')} sublabel="px" value={doc.longEdge} range={[1000, 12000]} zero={4000} snap={100} format={(v) => v.toFixed(0)} onChange={(v) => set({ longEdge: Math.round(v) })} />
          <PillMenu label={tz('Format', '格式')} value={format} fill options={[{ value: 'jpeg', label: 'JPEG' }, { value: 'png', label: 'PNG' }, { value: 'tiff16', label: 'TIFF 16-bit' }]} onChange={(v) => setFormat(v as typeof format)} />
          <PillMenu label={tz('Color Space', '色彩空间')} value={space} fill options={[{ value: 'sRGB', label: 'sRGB' }, { value: 'display-p3', label: 'Display P3' }, { value: 'adobe-rgb', label: 'Adobe RGB (1998)' }, { value: 'prophoto', label: 'ProPhoto RGB' }]} onChange={(v) => setSpace(v as ExportSpace)} />
        </div>
        <div className="export-proof" ref={area}>
          <div className="layout-sheet" style={{ width: pw, height: ph, background: `rgb(${grey},${grey},${grey})` }}>
            {rects.map((r, i) => (
              <div
                key={i}
                className={'layout-cell' + (i === active ? ' on' : '')}
                style={{ left: r.x, top: r.y, width: r.w, height: r.h }}
                onClick={() => setActive(i)}
                data-testid={'layout-cell-' + i}
              >
                <CellView photo={cells[i] ?? null} w={r.w} h={r.h} />
              </div>
            ))}
          </div>
        </div>
        <div className="export-strip">
          <div className="caption">{tz(`Cell ${active + 1}: ${cur ? baseName(cur.path) : 'empty'}`, `第 ${active + 1} 格：${cur ? baseName(cur.path) : '空'}`)}</div>
          <ScrubSlider label={tz('Across', '左右')} value={(cur?.panX ?? 0) * 100} range={[-100, 100]} zero={0} snap={5} format={(v) => v.toFixed(0)} disabled={!cur} onChange={(v) => cur && setCell(active, { ...cur, panX: v / 100 })} />
          <ScrubSlider label={tz('Up / Down', '上下')} value={(cur?.panY ?? 0) * 100} range={[-100, 100]} zero={0} snap={5} format={(v) => v.toFixed(0)} disabled={!cur} onChange={(v) => cur && setCell(active, { ...cur, panY: v / 100 })} />
          <ScrubSlider label={tz('Zoom', '缩放')} value={cur?.zoom ?? 1} range={[1, 4]} zero={1} snap={0.05} format={(v) => `${v.toFixed(2)}×`} disabled={!cur} onChange={(v) => cur && setCell(active, { ...cur, zoom: v })} />
          <div className="row" style={{ gap: 8 }}>
            <button className="btn" disabled={!cur} onClick={() => setCell(active, null)}>
              {tz('Empty this cell', '清空此格')}
            </button>
            <button className="btn" onClick={() => void importPhotos()}>
              {tz('Add photos…', '添加照片…')}
            </button>
          </div>
          <div className="caption">{tz('Click a photograph to put it in the cell:', '点击照片放入此格：')}</div>
          <div className="layout-picks">
            {frames.map((f) => {
              const url = thumbs.get(f.path);
              return (
                <button key={f.path} className={'layout-pick' + (cur?.path === f.path ? ' on' : '')} onClick={() => putPhoto(f.path)} title={f.name}>
                  {url ? <img src={url} alt="" /> : <span>{f.name}</span>}
                </button>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
