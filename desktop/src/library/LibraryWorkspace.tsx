// LibraryWorkspace.tsx — the Library mode of the one window (PRD-W5 §2;
// README §4; PC-L0–L6, PC-T1–T2, PC-K1): in the left column under the mode
// row, the source well and its menu and the source's rows; in the middle the
// viewer — the browser's focus, large, with its info strip — or, with no
// library, the first-run card. The grid is the window's browser (Browser.tsx),
// in every mode. The light table and the contact sheet are full-window pages
// above the shell (`MainWindowLayout`).
//
// Data comes only through the `LibraryClient` (store.ts). Capture One's
// sources are read-only: a rating key says so; nothing is written there.

import { useEffect, useMemo, useState } from 'react';
import { tz } from '../i18n';
import { Thumb } from '../windows/Filmstrip';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { isRawPath } from '@shared/whiteBalance';
import { Glyph as G, type GlyphName } from '../theme/Glyph';
import type { Collection } from './client';
import { setLibraryView, setUi, useUi } from '../app/ui';
import { developFromLibrary, showInExplorer, commands } from '../app/commands';
import { MenuList } from '../app/TitleBar';
import { toggleFavourite, addFolder, newAlbum, chooseCollection, closeLibrary, kindWords, locateOriginalFolder, newLibrary, openCaptureOneDialog, openLibrary, openLibraryDialog, originalLocation, setLibrary, setSearch, useLibrary, type LibraryState } from './store';
import type { ImageRow } from './client';
import { useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import type { StockCatalog } from '@shared/stocks';
import { platform } from '../platform';
import { useLibraryPreview } from './previews';

export const DAY = (d: string | null) => (d ? d.slice(0, 10) : '');
export function dayWords(day: string, today = new Date()): [string, string] {
  if (!day) return [tz('Undated', '无日期'), ''];
  const d = new Date(`${day}T12:00:00`);
  const same = d.toDateString() === today.toDateString();
  const lang = tz('en-GB', 'zh-CN');
  const label = same ? tz('Today', '今天') : d.toLocaleDateString(lang, { weekday: 'long' });
  const date = d.toLocaleDateString(lang, d.getFullYear() === today.getFullYear() ? { day: 'numeric', month: 'short' } : { day: 'numeric', month: 'long', year: 'numeric' });
  return [label, date];
}

/**
 * A film's dot (PC-L1): the colour the drawing gives each family — a portrait
 * negative warm, a consumer negative yellow, cine blue, black and white grey.
 * The same dot marks a FILMS row and a tile developed through that film.
 */
export function filmDot(catalog: StockCatalog, film: string): string {
  const s = catalog.stock(film);
  if (s?.monochrome || /tri_x|hp5|tmax|t_max|acros|neopan|ilford/.test(film)) return '#8C8A87';
  if (s?.use === 'cine' || /vision|cinestill/.test(film)) return '#5D8FD8';
  if (/gold|ultramax|colorplus|c200|superia|xtra/.test(film)) return '#E0B54A';
  return '#D8A27A';
}

/** The same placeholder in the grid and the viewer until a picture is available. */
function picture(uuid: string): string {
  const hue = [...uuid].reduce((a, c) => a + c.charCodeAt(0), 0) % 360;
  return `linear-gradient(160deg, hsl(${hue} 22% 34%), hsl(${(hue + 40) % 360} 18% 14%))`;
}

/**
 * A tile of the grid (PC-L1): the picture edge to edge in its cell, a small
 * dot at its foot for the film it was developed through, a white ring when
 * picked. No hearts: Favourites is a row of the sidebar.
 */
export function LibraryTile({ img, picked, focus, visible, film, onClick, onOpen }: { img: ImageRow; picked: boolean; focus?: boolean; visible: boolean; film: string | null; onClick: (e: React.MouseEvent) => void; onOpen: () => void }) {
  const offline = img.exists === false;
  const catalog = useSession((s) => s.catalog);
  const preview = useLibraryPreview(visible && !offline ? img.path : null);
  return (
    <button className={'v2-lib-tile' + (picked ? ' picked' : '') + (focus ? ' focus' : '') + (offline ? ' offline' : '')} data-testid="library-tile" data-uuid={img.uuid}
      aria-pressed={picked} aria-label={`${img.file_name}${offline ? `, ${tz('Offline', '离线')}` : ''}${picked ? `, ${tz('selected', '已选中')}` : ''}`}
      onClick={onClick} onDoubleClick={onOpen}>
      {preview ? <img className="v2-lib-pic" src={preview} alt="" /> : <span className="v2-lib-pic" style={{ background: picture(img.uuid) }} />}
      {offline && <span className="v2-offline">{tz('Offline', '离线')}</span>}
      {film && !offline && <i className="v2-lib-dot" style={{ background: filmDot(catalog, film) }} title={catalog.stock(film)?.name ?? film} />}
    </button>
  );
}

function SourceMenu() {
  const s = useLibrary((x) => x);
  const k = commands();
  if (!s.sourceMenu) return null;
  const done = () => setLibrary({ sourceMenu: false });
  return (
    <div className="v2-menu-drop source" data-testid="source-menu">
      <div className="v2-menu-caption">{tz('Recent', '最近')}</div>
      <MenuList onDone={done} items={[
        ...s.recent.map((r, i) => ({ id: `r${i}`, label: r.name, enabled: true, checked: r.path === s.source?.info.path, run: () => void openLibrary(r.path) })),
        { separator: true },
        { ...k.newCatalog!, run: () => void newLibrary('catalog') }, { ...k.newSession!, run: () => void newLibrary('session') },
        { ...k.openLibrary!, run: () => void openLibraryDialog() }, { ...k.openCaptureOne!, run: () => void openCaptureOneDialog() },
        { separator: true },
        { ...k.addFolder!, run: () => void addFolder() },
        { id: 'copyIn', label: tz('Copy Photos In…', '拷入照片…'), enabled: !!s.source && !s.source.readOnly, run: () => void platform().pickFiles(tz('Copy photos in', '拷入照片')) },
        { separator: true },
        { ...k.closeLibrary!, run: () => void closeLibrary() },
      ]} />
    </div>
  );
}

function SourceWell() {
  const s = useLibrary((x) => x);
  const src = s.source;
  return (
    <div className="v2-source-wrap">
      <button className="v2-source-well" data-testid="source-well" aria-haspopup="menu" aria-expanded={s.sourceMenu} onClick={() => setLibrary({ sourceMenu: !s.sourceMenu })}>
        <span className="v2-source-icon"><G name={src?.kind === 'folder' ? 'folder' : 'library'} /></span>
        <span className="v2-source-words">
          <span className="v2-source-name">{src ? src.info.name : tz('No library open', '没有打开的图库')}</span>
          <span className="v2-source-kind">{src ? `${kindWords(src.kind)} · ${tz(`${src.info.counts.images} photos`, `${src.info.counts.images} 张照片`)}` : ''}</span>
          {src?.readOnly && <span className="v2-readonly"><G name="lock" />{tz('Read-only', '只读')}</span>}
          {s.progress && <span className="v2-source-kind">{s.progress}</span>}
        </span>
        <span className="v2-source-switch"><G name="sourceSwitch" /></span>
      </button>
      <SourceMenu />
    </div>
  );
}

const SECTION_OF: Record<string, string> = {
  all_images: 'LIBRARY', smart_album: 'LIBRARY', recent_import: 'LIBRARY', light_table: 'LIGHT TABLE', album: 'COLLECTIONS', folder: 'FOLDERS', session_folder: 'SESSION',
};
const SECTION_WORDS: Record<string, () => string> = {
  LIBRARY: () => tz('LIBRARY', '图库'), 'LIGHT TABLE': () => tz('LIGHT TABLE', '看片台'), COLLECTIONS: () => tz('COLLECTIONS', '收藏集'),
  FOLDERS: () => tz('FOLDERS', '文件夹'), FILMS: () => tz('FILMS', '胶片'), SESSION: () => tz('SESSION', '会话'), CATALOG: () => tz('CATALOG', '目录'), FOLDER: () => tz('FOLDER', '文件夹'),
};

/** A sidebar row's glyph (PC-L1), by what the row is. */
function rowGlyph(c: Collection, i: number): GlyphName {
  const k = (c.criteria ?? {}) as Record<string, unknown>;
  if (c.kind === 'recent_import') return 'recentImports';
  if (c.kind === 'folder' || c.kind === 'session_folder') return 'folder';
  if (c.kind === 'light_table') return i === 0 && !c.parent ? 'table' : 'collection';
  if (c.kind === 'smart_album' && 'rating' in k) return 'heart';
  if (c.kind === 'smart_album' && 'state' in k) return 'developing';
  return 'collection';
}
const filmOfRow = (c: Collection): string | null => {
  const f = c.kind === 'smart_album' ? (c.criteria as Record<string, unknown> | null)?.film : null;
  return typeof f === 'string' ? f : null;
};

/** The Library's tools in the left column (`MainWindowLayout`): the source well, the source's rows, the filters. */
export function LibraryColumn() {
  const s = useLibrary((x) => x);
  const view = useUi((u) => u.libraryView);
  const catalog = useSession((x) => x.catalog);
  const folded = useSettings((x) => x.collapsedSections);
  const groups = useMemo(() => {
    const out = new Map<string, LibraryState['collections']>();
    for (const c of s.collections) {
      let sec = SECTION_OF[c.kind] ?? 'COLLECTIONS';
      if (c.kind === 'smart_album' && c.criteria && 'film' in c.criteria) sec = 'FILMS';
      if (s.source?.kind === 'captureOneCatalog' && sec === 'LIBRARY') sec = 'CATALOG';
      if (s.source?.kind === 'folder') sec = 'FOLDER';
      out.set(sec, [...(out.get(sec) ?? []), c]);
    }
    const order = ['LIBRARY', 'CATALOG', 'SESSION', 'FOLDER', 'LIGHT TABLE', 'FILMS', 'COLLECTIONS', 'FOLDERS'];
    return [...out.entries()].sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0]));
  }, [s.collections, s.source]);
  return (
    <div className="v2-lib-sidebar" data-testid="library-sidebar">
      <div className="v2-rail-fixed"><SourceWell /></div>
      <div className="v2-rail-scroll">
        {!s.source && s.recent.length > 0 && <div className="v2-lib-group" data-testid="recent-libraries">
          <div className="v2-caps"><span>{tz('RECENT', '最近')}</span><G name="capsChevron" /></div>
          {s.recent.map((r) => (
            <button key={r.path} className="v2-lib-row" onClick={() => void openLibrary(r.path)}>
              <span className="v2-row-icon"><G name={r.kind === 'captureOneSession' ? 'captureOne' : r.kind === 'folder' ? 'folder' : 'library'} /></span>
              <span className="v2-row-name">{r.name}</span><span className="v2-row-count">{kindWords(r.kind)}</span>
            </button>
          ))}
        </div>}
        {groups.map(([sec, cs]) => {
          const closed = !!folded[`lib.${sec}`];
          return (
            <div key={sec} className="v2-lib-group">
              <button className="v2-caps" aria-expanded={!closed} onClick={() => settingsStore.getState().toggleSection(`lib.${sec}`)}>
                <span>{SECTION_WORDS[sec]?.() ?? sec}</span><G name={closed ? 'chevronRight' : 'capsChevron'} />
              </button>
              {!closed && cs.map((c, i) => {
                const film = filmOfRow(c);
                return (
                  <button key={c.uuid} className={'v2-lib-row' + (s.collection === c.uuid && view === 'grid' ? ' on' : '') + (c.parent ? ' child' : '')} data-testid={`collection-${c.uuid}`}
                    onClick={() => { if (c.kind === 'light_table') { void chooseCollection(c.uuid); setLibraryView('lightTable'); } else { setLibraryView('grid'); void chooseCollection(c.uuid); } }}>
                    <span className="v2-row-icon">{film ? <i className="v2-film-dot" style={{ background: filmDot(catalog, film) }} /> : <G name={rowGlyph(c, i)} />}</span>
                    <span className="v2-row-name">{c.title}</span>
                    <span className={'v2-row-count' + (s.offline.includes(c.uuid) ? ' danger' : '')}>{s.offline.includes(c.uuid) ? tz('Offline', '离线') : c.image_count ?? ''}</span>
                  </button>
                );
              })}
              {!closed && sec === 'COLLECTIONS' && !s.source?.readOnly && <button className="v2-lib-row add" onClick={() => void newAlbum()} data-testid="new-album">{tz('New Album', '新建相簿')}</button>}
              {!closed && sec === 'LIGHT TABLE' && <button className="v2-lib-row add" onClick={() => setLibraryView('contactSheet')} data-testid="new-contact-sheet">{tz('New Contact Sheet', '新建印样')}</button>}
            </div>
          );
        })}
        {s.source && <div className="v2-lib-group">
          <div className="v2-caps"><span>{tz('FILTERS', '筛选')}</span><G name="capsChevron" /></div>
          <input className="v2-search" data-testid="library-search" placeholder={tz('Search', '搜索')} value={s.search} onChange={(e) => void setSearch(e.target.value)} />
        </div>}
      </div>
    </div>
  );
}

function FirstRun() {
  return (
    <div className="v2-first-run" data-testid="first-run">
      <div className="v2-first-art" aria-hidden><i /><i /><i /></div>
      <h1>{tz('An empty darkroom', '空的暗房')}</h1>
      <div className="v2-first-buttons">
        <button className="v2-button" data-testid="first-new-catalog" onClick={() => void newLibrary('catalog')}><G name="library" /><span>{tz('New Catalog…', '新建目录…')}</span></button>
        <button className="v2-button" data-testid="first-open-library" onClick={() => void openLibraryDialog()}><G name="folder" /><span>{tz('Open Library…', '打开图库…')}</span></button>
        <button className="v2-button" data-testid="first-open-c1" onClick={() => void openCaptureOneDialog()}><G name="captureOne" /><span>{tz('Open Capture One Catalog…', '打开 Capture One 目录…')}</span></button>
        <button className="v2-button" data-testid="first-add-folder" onClick={() => void addFolder()}><G name="addFolder" /><span>{tz('Add a Folder…', '添加文件夹…')}</span></button>
      </div>
      <p className="dim v2-drop-hint">{tz('Drop a folder or pictures here.', '把文件夹或照片拖到这里。')}</p>
    </div>
  );
}

/** "4,000 × 6,000 · 24 MP". */
const dims = (w?: number | null, h?: number | null) => (w && h ? `${w.toLocaleString('en')} × ${h.toLocaleString('en')}  ·  ${Math.round((w * h) / 1e6)} MP` : '');

/**
 * The Library's middle (`MacLibraryBrowser` with the viewer on): the browser's focus, large, and
 * under it the info strip — its file, capture and print; with several chosen, what can be done to
 * them all. The Develop and Edit modes are the mode row's; Show in File Explorer stays here.
 */
function Viewer() {
  const s = useLibrary((x) => x);
  const clip = useSession((x) => x.clipboard);
  const catalog = useSession((x) => x.catalog);
  const frames = useSession((x) => x.frames);
  const selection = useSession((x) => x.selection);
  const folderPicked = useSession((x) => x.picked);
  const c1 = s.source?.kind === 'captureOneCatalog' || s.source?.kind === 'captureOneSession';
  const f = s.images.find((i) => i.uuid === s.focus);
  const several = s.source ? s.picked.length : folderPicked.length;
  const preview = useLibraryPreview(s.source && several <= 1 && f?.exists !== false ? f?.path ?? null : null, true);
  if (several > 1) {
    return (
      <div className="v2-viewer" data-testid="info-picked">
        <div className="v2-viewer-card">
          <div className="v2-info-line count">{tz(`${several} frames`, `${several} 张`)}</div>
          <div className="v2-info-line dim small">{clip ? `${tz('Clipboard', '剪贴板')}: ${clip.sourceName}` : tz('Clipboard: empty', '剪贴板：空')}</div>
          <div className="v2-info-actions">
            <button className="v2-button" data-testid="paste-picked" disabled={!clip || !!s.source?.readOnly}
              title={!clip ? tz('Copy settings from a frame first (Ctrl+Shift+C).', '请先从一张照片拷贝设置（Ctrl+Shift+C）。') : undefined}
              onClick={() => void developFromLibrary().then(() => commands().pasteSettings?.run())}>{tz(`Paste to ${several}`, `粘贴到 ${several} 张`)}</button>
            {s.source && <button className="v2-button" data-testid="favourite-picked" disabled={!!s.source?.readOnly} onClick={() => void toggleFavourite()}>{tz('Favourite', '收藏')}</button>}
          </div>
        </div>
      </div>
    );
  }
  // No library: the folder's frame the browser is on.
  if (!s.source) {
    const open = frames.find((x) => x.path === selection);
    if (!open) return <FirstRun />;
    return (
      <div className="v2-viewer" data-testid="info-one">
        <div className="v2-viewer-well"><Thumb path={open.path} geometry={GEOMETRY_DEFAULT} height={480} /></div>
        <div className="v2-viewer-strip" data-testid="viewer-strip">
          <b>{open.name}</b>
          <button className="v2-button" data-testid="show-in-explorer" onClick={showInExplorer}>{tz('Show in File Explorer', '在文件资源管理器中显示')}</button>
        </div>
      </div>
    );
  }
  if (!f) return <div className="v2-viewer" data-testid="info-empty"><div className="v2-viewer-well empty"><span className="dim">{tz('No selection', '未选择')}</span></div></div>;
  const ex = f.exposure;
  const film = s.filmOf[f.uuid];
  const print = film ? catalog.stock(film)?.name.replace(/^(Kodak|Fujifilm|Ilford|Fuji) (Professional )?/, '') ?? '' : f.variants[0]?.edit_revision ? tz('Developed', '已冲洗') : '';
  const parts = [
    f.exists === false ? tz('Offline', '离线') : '',
    dims(f.width, f.height),
    f.camera?.model ?? '',
    ex ? `${ex.shutter} s · f/${ex.aperture} · ISO ${ex.iso}` : '',
    takenWords(f.captured_local),
    c1 ? tz('Adjustments stay in Capture One', '调整保留在 Capture One 中') : print,
  ].filter((x) => x && x !== '—');
  return (
    <div className="v2-viewer" data-testid="info-one">
      <div className="v2-viewer-well">
        {preview ? <img className="v2-viewer-image" src={preview} alt={f.file_name} data-testid="library-viewer-image" />
          : <span className="v2-viewer-pic" style={{ background: picture(f.uuid) }} />}
      </div>
      <div className="v2-viewer-strip" data-testid="viewer-strip">
        <b title={f.path}>{f.file_name}</b>
        {preview && <span className="v2-preview-origin">{isRawPath(f.path) ? tz('Camera preview', '相机预览') : tz('Original preview', '原片预览')}</span>}
        <span className="dim">{parts.join('  ·  ')}</span>
        {c1 && originalLocation(f, s.locations)
          ? <button className="v2-button" data-testid="locate-original-folder" disabled={s.locating || s.phase !== 'open'}
              onClick={() => void locateOriginalFolder(f)}>{tz('Locate Folder…', '定位文件夹…')}</button>
          : <button className="v2-button" data-testid="show-in-explorer" disabled={f.exists === false} onClick={showInExplorer}>{tz('Show in File Explorer', '在文件资源管理器中显示')}</button>}
      </div>
    </div>
  );
}

/** PC-T1/T2: the light table — the films laid on an A4 sheet at their own size; Actual Size from the display's size. */
function LightTable({ actual }: { actual: boolean }) {
  const s = useLibrary((x) => x);
  const frames = s.images.slice(0, 11);
  const mm = actual ? 4.45 / 1.25 : 1; // epx per mm: README §4.2's laptop; otherwise the sheet is drawn at 1 epx a mm × zoom
  const scale = actual ? mm : 2.2;
  return (
    <div className="v2-light-table" data-testid={actual ? 'light-table-actual' : 'light-table'}>
      <div className="v2-sheet-room">
        <div className="v2-ruler-x" aria-hidden>{Array.from({ length: 29 }, (_, i) => <span key={i} style={{ left: (i + 1) * 10 * scale }}>{i + 1}</span>)}</div>
        <div className="v2-sheet" style={{ width: 297 * scale, height: 210 * scale }}>
          {frames.map((f, i) => {
            const w = (i % 4 === 3 ? 56 : 36) * scale, h = (i % 4 === 3 ? 56 : 24) * scale;
            return <div key={f.uuid} className="v2-sheet-frame" style={{ left: (18 + (i % 4) * 60) * scale, top: (18 + Math.floor(i / 4) * 64) * scale, width: w, height: h }} title={f.file_name} />;
          })}
        </div>
      </div>
      <div className="v2-lt-foot">
        <span className="dim">{tz(`${frames.length} films  ·  A4  ·  Landscape`, `${frames.length} 卷  ·  A4  ·  横向`)}{actual ? tz('  ·  Actual Size', '  ·  实际尺寸') : ''}</span>
        <div className="v2-seg">
          <button className={actual ? 'on' : ''} data-testid="lt-actual" onClick={() => setUi({ lightTableActual: !actual })}>1:1</button>
          <button>A4</button>
        </div>
      </div>
    </div>
  );
}

/** PC-K1: a 135 contact sheet — strips of six with the film's edge print and frame numbers. */
function ContactSheet() {
  const s = useLibrary((x) => x);
  const frames = s.images.slice(0, 36);
  const strips: ImageRow[][] = [];
  for (let i = 0; i < frames.length; i += 6) strips.push(frames.slice(i, i + 6));
  return (
    <div className="v2-light-table" data-testid="contact-sheet">
      <div className="v2-sheet-room">
        <div className="v2-sheet portrait">
          {strips.map((row, r) => (
            <div key={r} className="v2-strip-135">
              {row.map((f, i) => <div key={f.uuid} className="v2-strip-frame"><small>{r * 6 + i + 1}</small><span className="edge" aria-hidden="true" data-fit="scale">KODA PORTA 400</span><small>▸{r * 6 + i + 1}A</small></div>)}
            </div>
          ))}
        </div>
      </div>
      <div className="v2-lt-foot"><span className="dim">{tz(`Roll 4  ·  135  ·  ${frames.length} of 36  ·  Porta 400`, `第 4 卷  ·  135  ·  ${frames.length} / 36  ·  Porta 400`)}</span></div>
    </div>
  );
}

/** "23 Oct 2026, 16:42" (PC-L1), in the interface's language. */
function takenWords(local: string | null | undefined): string {
  if (!local) return '—';
  const d = new Date(local.length > 10 ? local : `${local}T00:00:00`);
  if (Number.isNaN(d.getTime())) return local;
  const date = d.toLocaleDateString(tz('en-GB', 'zh-CN'), { day: 'numeric', month: 'short', year: 'numeric' });
  return `${date}, ${local.slice(11, 16)}`;
}

/**
 * The Library's half of the picture bar (PC-L1's, after the shared bar): where you are (the source ›
 * the collection) over the count; Import; the tiles' size.
 */
export function LibraryBar() {
  const s = useLibrary((x) => x);
  const tile = useSettings((x) => x.libraryTile);
  const src = s.source;
  const collection = s.collections.find((c) => c.uuid === s.collection);
  const k = commands();
  const count = s.picked.length > 1 ? tz(`${s.picked.length} Selected`, `已选 ${s.picked.length} 张`)
    : tz(`${s.total} photos${s.picked.length ? '  ·  1 selected' : ''}`, `${s.total} 张照片${s.picked.length ? '  ·  已选 1 张' : ''}`);
  return (
    <>
      <div className="v2-crumb">
        {src ? <div className="v2-crumb-line"><span className="v2-crumb-source">{src.info.name}</span><G name="crumb" /><b>{collection?.title ?? ''}</b>
          {src.readOnly && <span className="v2-readonly"><G name="lock" />{tz('Read-only', '只读')}</span>}</div> : null}
        {src && <div className="v2-crumb-count">{count}</div>}
      </div>
      <button className="v2-glyph" title={tz('Import', '导入')} aria-label={tz('Import', '导入')} disabled={!src || src.readOnly} onClick={() => k.import!.run()} data-testid="lib-import"><G name="import" /></button>
      <input className="v2-size-slider" type="range" min={96} max={240} step={1} value={tile} aria-label={tz('Thumbnail Size', '缩略图大小')} data-testid="lib-size"
        onChange={(e) => settingsStore.getState().set('libraryTile', Number(e.target.value))} />
    </>
  );
}

/** The Library's middle: the viewer (or the first-run card), and a folder dropped on it is added. */
export function LibraryCentre() {
  const src = useLibrary((x) => x.source);
  const [dragOver, setDragOver] = useState(false);
  useEffect(() => platform().onDrop((paths) => { if (paths.length) void addFolder(paths[0]); }), [src]);
  return (
    <div className={'v2-library-centre' + (dragOver ? ' drop' : '')} data-testid="library-centre" onDragOver={() => setDragOver(true)} onDragLeave={() => setDragOver(false)}>
      <Viewer />
    </div>
  );
}

/** The light table and the contact sheet: full-window pages above the shell (`MainWindowLayout`); Esc or ✕ puts them away. */
export function FullWindowPage() {
  const view = useUi((u) => u.libraryView);
  const actual = useUi((u) => u.lightTableActual);
  if (view === 'grid') return null;
  return (
    <div className="v2-full-page" data-testid="full-page" role="dialog" aria-label={view === 'lightTable' ? tz('Light Table', '看片台') : tz('Contact Sheet', '印样')}>
      <div className="v2-full-head">
        <b>{view === 'lightTable' ? tz('Light Table', '看片台') : tz('Contact Sheet', '印样')}</b>
        <button className="v2-button" data-testid="full-page-done" onClick={() => setLibraryView('grid')}>{tz('Done', '完成')}</button>
      </div>
      {view === 'lightTable' ? <LightTable actual={actual} /> : <ContactSheet />}
    </div>
  );
}
