// TitleBar.tsx — one 32 epx title bar across the window (README §1.1, PC-E1):
// the app's icon, the menu bar (File Edit View Frame Go Help, with access
// keys), the window's title centred in caption type, and the caption buttons.
// Every empty part of it drags the window (`data-tauri-drag-region`; a
// double-click there maximises, as the system's own title bar does).
//
// When the six titles do not fit (a narrow window, CJK), the menu bar folds
// into one menu button at the icon's right (README §9.2).

import { Fragment, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { menuBar, type MenuEntry } from './commands';
import { Glyph as G } from '../theme/Glyph';
import { openMenu, setUi, useUi } from './ui';
import { closeWindow, minimize, toggleMaximize } from './windowChrome';
import { useSession } from '../state/session';
import { useLibrary } from '../library/store';
import { useSettings } from '../state/settings';
import { tz } from '../i18n';

function Accessed({ label, access, show }: { label: string; access?: string; show: boolean }) {
  if (!access) return <>{label}</>;
  const i = label.toLowerCase().indexOf(access.toLowerCase());
  if (i < 0) return <>{label}{show ? <span className="access">({access.toUpperCase()})</span> : null}</>;
  return <>{label.slice(0, i)}<span className={show ? 'access shown' : 'access'}>{label[i]}</span>{label.slice(i + 1)}</>;
}

export function MenuList({ items, onDone, testId }: { items: MenuEntry[]; onDone: () => void; testId?: string }) {
  const [sub, setSub] = useState<string | null>(null);
  return (
    <div className="v2-menu" role="menu" data-testid={testId}>
      {items.map((it, i) => {
        if ('separator' in it) return <div key={`s${i}`} className="v2-menu-sep" role="separator" />;
        if ('submenu' in it) {
          return (
            <div key={it.submenu} className="v2-menu-item has-sub" role="menuitem" aria-haspopup="menu" aria-disabled={!it.enabled || undefined}
              onPointerEnter={() => setSub(it.submenu)} onClick={() => setSub(sub === it.submenu ? null : it.submenu)}>
              <span className="check" />
              <span className="label">{it.label}</span>
              <span className="keys sub"><G name="chevronRight" /></span>
              {sub === it.submenu && it.items.length > 0 && <div className="v2-submenu"><MenuList items={it.items} onDone={onDone} /></div>}
            </div>
          );
        }
        return (
          <button key={it.id} className="v2-menu-item" role={it.checked !== undefined ? 'menuitemcheckbox' : 'menuitem'} aria-checked={it.checked}
            disabled={!it.enabled} data-command={it.id} onPointerEnter={() => setSub(null)}
            onClick={() => { onDone(); it.run(); }}>
            <span className="check">{it.checked ? <G name="check" size={16} /> : ''}</span>
            <span className="label">{it.label}</span>
            {it.keys && <span className="keys">{it.keys}</span>}
          </button>
        );
      })}
    </div>
  );
}

export function TitleBar({ title }: { title: string }) {
  const open = useUi((s) => s.menu);
  const access = useUi((s) => s.accessKeys);
  const maximized = useUi((s) => s.maximized);
  // Re-read the menus when what they show changes.
  useSession((s) => s);
  useLibrary((s) => s);
  useSettings((s) => s);
  useUi((s) => s);
  const menus = menuBar();
  const bar = useRef<HTMLDivElement>(null);
  const measure = useRef<HTMLDivElement>(null);
  const [folded, setFolded] = useState(false);
  const width = useUi((s) => s.window.width);
  const titles = menus.map((m) => m.label).join();
  useLayoutEffect(() => {
    // The titles' own width against the room the bar has for them (README §9.2).
    const need = measure.current?.scrollWidth ?? 0;
    const room = width - 46 * 3 - 40 - 160;
    setFolded(need > room);
  }, [width, titles]);
  useEffect(() => {
    if (!open) return;
    const close = (e: PointerEvent) => { if (!bar.current?.contains(e.target as Node)) openMenu(null); };
    window.addEventListener('pointerdown', close);
    return () => window.removeEventListener('pointerdown', close);
  }, [open]);
  const done = () => { openMenu(null); setUi({ accessKeys: false }); };
  return (
    <header className="v2-titlebar" data-testid="titlebar" data-tauri-drag-region onDoubleClick={(e) => { if (e.target === e.currentTarget) void toggleMaximize(); }}>
      <div className="v2-app-icon" aria-hidden><span /></div>
      <div className="v2-menubar" ref={bar} role="menubar" aria-label={tz('Menu bar', '菜单栏')} data-testid="menubar" data-folded={folded || undefined}>
        {folded ? (
          <div className="v2-menubar-title">
            <button className={'v2-menubar-btn' + (open ? ' open' : '')} aria-label={tz('Menu', '菜单')} data-testid="menu-fold" onClick={() => openMenu(open ? null : 'file')}>☰</button>
            {open && <div className="v2-menu-drop"><MenuList onDone={done} items={menus.map((m) => ({ submenu: m.id, label: m.label, access: m.access, items: m.items, enabled: true }))} /></div>}
          </div>
        ) : menus.map((m) => (
          <div key={m.id} className="v2-menubar-title">
            <button className={'v2-menubar-btn' + (open === m.id ? ' open' : '')} role="menuitem" aria-haspopup="menu" aria-expanded={open === m.id}
              data-testid={`menu-${m.id}`}
              onClick={() => openMenu(open === m.id ? null : m.id)} onPointerEnter={() => { if (open && open !== m.id) openMenu(m.id); }}>
              <Accessed label={m.label} access={m.access} show={access} />
            </button>
            {open === m.id && <div className="v2-menu-drop"><MenuList items={m.items} onDone={done} testId={`menu-${m.id}-list`} /></div>}
          </div>
        ))}
      </div>
      <div className="v2-menubar-measure" ref={measure} aria-hidden>{menus.map((m) => <span key={m.id}>{m.label}</span>)}</div>
      <div className="v2-window-title" data-tauri-drag-region data-testid="window-title">{title}</div>
      <div className="v2-captions">
        <button className="v2-caption" aria-label={tz('Minimize', '最小化')} data-testid="caption-min" onClick={() => void minimize()}><svg width="10" height="10"><path d="M0 5.5h10" stroke="currentColor" /></svg></button>
        <button className="v2-caption" aria-label={maximized ? tz('Restore', '还原') : tz('Maximize', '最大化')} data-testid="caption-max" onClick={() => void toggleMaximize()}>
          {maximized
            ? <svg width="10" height="10"><rect x="0.5" y="2.5" width="7" height="7" fill="none" stroke="currentColor" /><path d="M2.5 2.5v-2h7v7h-2" fill="none" stroke="currentColor" /></svg>
            : <svg width="10" height="10"><rect x="0.5" y="0.5" width="9" height="9" fill="none" stroke="currentColor" /></svg>}
        </button>
        <button className="v2-caption close" aria-label={tz('Close', '关闭')} data-testid="caption-close" onClick={() => void closeWindow()}><svg width="10" height="10"><path d="M0 0l10 10M10 0L0 10" stroke="currentColor" /></svg></button>
      </div>
    </header>
  );
}

export { Fragment };
