// Browser.tsx — the library's browser at the window's right, in every mode
// (PRD-W5 §2, R3; the Mac's `MacBrowserSplit` and `MacBrowserHeader.slim`).
//
// The slim bar: the count and the search. Under it the rows (browser.ts):
// the library's own, by day under the capture-date order, drawn as the
// Library grid's tiles (PC-L1); or, with no library open, the folder's frames
// as the filmstrip drew them (the whole photograph, the crop's outside
// masked). One selection in every mode; a press in Develop or Edit opens the
// picture. Mounted once for the whole window, so its scroll is as it was
// when a mode comes back.

import { useEffect, useMemo, useRef, useState } from 'react';
import { tz } from '../i18n';
import { useSession } from '../state/session';
import { useSettings } from '../state/settings';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { Thumb } from '../windows/Filmstrip';
import { thumbs } from '../state/thumbs';
import { setSearch, useLibrary } from './store';
import { pressRow, type BrowserRow } from './browser';
import { developFromLibrary } from '../app/commands';
import { useUi } from '../app/ui';
import { DAY, dayWords, LibraryTile } from './LibraryWorkspace';

function FrameTile({ row, open, picked }: { row: BrowserRow; open: boolean; picked: boolean }) {
  const live = useSession((s) => s.sidecar.geometry);
  const saved = useSession((s) => s.savedGeometry);
  return (
    <button className={'v2-lib-tile frame' + (picked || open ? ' picked' : '')} data-testid="browser-tile" data-path={row.path} aria-pressed={picked || open}
      aria-label={`${row.name}${open ? `, ${tz('open', '已打开')}` : ''}`} title={row.name}
      onClick={(e) => void pressRow(row, { ctrl: e.ctrlKey || e.metaKey, shift: e.shiftKey })}>
      <Thumb path={row.path} geometry={open ? live : saved[row.path] ?? GEOMETRY_DEFAULT} height={120} source="filmstrip" />
      <span className="v2-frame-name">{row.name}</span>
    </button>
  );
}

/** The folder's frames (no library open): the filmstrip's rows, now a column of the browser. */
function FolderRows() {
  const frames = useSession((s) => s.frames);
  const selection = useSession((s) => s.selection);
  const picked = useSession((s) => s.picked);
  const tile = useSettings((x) => x.libraryTile);
  const [, setSeen] = useState(0);
  const box = useRef<HTMLDivElement>(null);
  // Only the tiles in view (and a screen's worth beyond) ask the host for their thumbnails — the
  // filmstrip's rule: a folder of thousands must not fill the host's queue.
  useEffect(() => {
    const root = box.current?.closest('.v2-browser-rows');
    if (!root || typeof IntersectionObserver === 'undefined') { thumbs.setFilmstripPaths(frames.map((f) => f.path)); return () => thumbs.setFilmstripPaths([]); }
    const near = new Set<string>();
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) { const p = (e.target as HTMLElement).dataset.path!; if (e.isIntersecting) near.add(p); else near.delete(p); }
      thumbs.setFilmstripPaths(near);
      setSeen((v) => v + 1);
    }, { root, rootMargin: '600px 0px', threshold: 0 });
    box.current!.querySelectorAll<HTMLElement>('[data-path]').forEach((el) => io.observe(el));
    return () => { io.disconnect(); thumbs.setFilmstripPaths([]); };
  }, [frames]);
  useEffect(() => { box.current?.querySelector('[aria-pressed="true"]')?.scrollIntoView({ block: 'nearest' }); }, [selection]);
  if (!frames.length) {
    return <div className="v2-browser-empty dim" data-testid="browser-empty">{tz('No pictures. Open a file or a folder (Ctrl+O), or add a folder in the Library.', '没有照片。打开文件或文件夹（Ctrl+O），或在图库中添加文件夹。')}</div>;
  }
  return (
    <div className="v2-day-tiles" ref={box} style={{ ['--v2-lib-tile' as string]: `${tile}px` }}>
      {frames.map((f) => {
        const row: BrowserRow = { id: f.path, path: f.path, name: f.name, exists: true };
        return <FrameTile key={f.path} row={row} open={f.path === selection} picked={picked.length > 1 && picked.includes(f.path)} />;
      })}
    </div>
  );
}

/** The library's rows: by day under the capture-date order, a plain grid under any other. */
function LibraryRows() {
  const s = useLibrary((x) => x);
  const tile = useSettings((x) => x.libraryTile);
  const editing = useUi((u) => u.workspace !== 'library');
  const box = useRef<HTMLDivElement>(null);
  const { images, sort } = s;
  const groups = useMemo(() => {
    if (sort !== 'captured') return [['', images]] as [string, typeof images][];
    const m = new Map<string, typeof images>();
    for (const i of images) m.set(DAY(i.captured_local), [...(m.get(DAY(i.captured_local)) ?? []), i]);
    return [...m.entries()];
  }, [images, sort]);
  useEffect(() => { box.current?.querySelector('.v2-lib-tile.focus')?.scrollIntoView({ block: 'nearest' }); }, [s.focus]);
  if (!s.images.length) return <div className="v2-browser-empty dim" data-testid="browser-empty">{s.search ? tz('Nothing matches the search.', '没有符合搜索的照片。') : tz('No pictures here.', '这里没有照片。')}</div>;
  return (
    <div ref={box} style={{ ['--v2-lib-tile' as string]: `${tile}px` }}>
      {s.source?.readOnly && s.message && <div className="v2-infobar soft" role="status" data-testid="library-message">{s.message}</div>}
      {groups.map(([day, rows]) => {
        const [label, date] = dayWords(day);
        return (
          <section key={day || 'all'} className="v2-day">
            {s.sort === 'captured' && <div className="v2-day-head"><b>{label}</b><span className="dim">{date}</span><span className="dim count">{rows.length}</span></div>}
            <div className="v2-day-tiles">
              {rows.map((img) => (
                <LibraryTile key={img.uuid} img={img} picked={s.picked.includes(img.uuid)} focus={s.focus === img.uuid} film={s.filmOf[img.uuid] ?? null}
                  onClick={(e) => void pressRow({ id: img.uuid, path: img.path, name: img.file_name, exists: img.exists !== false }, { ctrl: e.ctrlKey || e.metaKey, shift: e.shiftKey })}
                  onOpen={() => { if (!editing) void developFromLibrary(); }} />
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

/** The slim bar (`MacBrowserHeader.slim`): the count, and the search. */
function SlimBar() {
  const s = useLibrary((x) => x);
  const frames = useSession((x) => x.frames.length);
  const picked = useSession((x) => x.picked.length);
  const count = s.source
    ? s.picked.length > 1 ? tz(`${s.picked.length} of ${s.total} selected`, `已选 ${s.picked.length} / ${s.total} 张`) : tz(`${s.total} photos`, `${s.total} 张照片`)
    : picked > 1 ? tz(`${picked} of ${frames} selected`, `已选 ${picked} / ${frames} 张`) : tz(`${frames} photos`, `${frames} 张照片`);
  return (
    <div className="v2-browser-bar" data-testid="browser-bar">
      <span className="v2-browser-count" data-testid="browser-count">{count}</span>
      {s.source && <input className="v2-search slim" data-testid="browser-search" placeholder={tz('Search', '搜索')} aria-label={tz('Search', '搜索')}
        value={s.search} onChange={(e) => void setSearch(e.target.value)} />}
    </div>
  );
}

export function Browser({ mode, width, full }: { mode: string; width: number; full: boolean }) {
  const source = useLibrary((x) => !!x.source);
  return (
    <aside className={`v2-browser ${mode}${full ? ' full' : ''}`} data-testid="browser" data-mode={mode} data-source={source ? 'library' : 'folder'}
      style={{ width }} aria-label={tz('Browser', '浏览器')}>
      <SlimBar />
      <div className="v2-browser-rows" data-testid="browser-rows">{source ? <LibraryRows /> : <FolderRows />}</div>
    </aside>
  );
}
