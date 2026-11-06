// The native menu bar holds Tauri resources, one per item, and an item's
// action lives with its resource. A change to the recent-folder list must
// swap only the Open Recent entries, release what it replaces and nothing
// else, and apply in order, so the resource count stays flat however many
// folders are opened and the menu always shows the latest list.
// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';

// A stand-in for @tauri-apps/api/menu that keeps the resource table: every
// `new` adds a live resource, `close` removes it, and `setAsAppMenu` hands
// back the previous app menu as a new resource, as Tauri does.
const fake = vi.hoisted(() => {
  const all = new Map<number, { kind: string; text?: string }>();
  const live = new Set<number>();
  let nextRid = 1;
  let appMenu: unknown = null;
  let created = 0;
  let slow: Promise<void> | null = null;
  class Resource {
    rid: number;
    constructor(kind: string, text?: string) {
      this.rid = nextRid++;
      all.set(this.rid, { kind, text });
      live.add(this.rid);
      created++;
    }
    async close() {
      if (!live.has(this.rid)) throw new Error(`closed twice: ${this.rid}`);
      live.delete(this.rid);
    }
  }
  class MenuItem extends Resource {
    text: string;
    constructor(text: string) { super('item', text); this.text = text; }
    static async new(o: { text: string }) { if (slow) await slow; return new MenuItem(o.text); }
  }
  class PredefinedMenuItem extends Resource {
    constructor() { super('separator'); }
    static async new() { return new PredefinedMenuItem(); }
  }
  class Submenu extends Resource {
    text: string;
    enabled = true;
    children: Resource[];
    constructor(text: string, items: Resource[]) { super('submenu', text); this.text = text; this.children = items; }
    static async new(o: { text: string; items: Resource[] }) { return new Submenu(o.text, o.items); }
    async setEnabled(v: boolean) { this.enabled = v; }
    async insert(items: Resource[], at: number) { this.children.splice(at, 0, ...items); }
    async remove(item: Resource) {
      const i = this.children.indexOf(item);
      if (i < 0) throw new Error('not a child');
      this.children.splice(i, 1);
    }
  }
  class Menu extends Resource {
    children: Resource[];
    constructor(items: Resource[]) { super('menu'); this.children = items; }
    static async new(o: { items: Resource[] }) { return new Menu(o.items); }
    async setAsAppMenu() {
      const previous = appMenu as Menu | null;
      appMenu = this as Menu;
      return previous ? new Menu(previous.children) : null;
    }
  }
  return {
    all, live, MenuItem, PredefinedMenuItem, Submenu, Menu,
    created: () => created,
    // The table itself is kept across tests: the menu built by one test is
    // released by the next test's rebuild, which is part of what is checked.
    reset: () => { created = 0; slow = null; },
    stall: (p: Promise<void> | null) => { slow = p; },
  };
});
vi.mock('@tauri-apps/api/menu', () => ({ Menu: fake.Menu, MenuItem: fake.MenuItem, PredefinedMenuItem: fake.PredefinedMenuItem, Submenu: fake.Submenu }));
vi.mock('./keys', () => ({ webviewOwnsMenuKeys: () => false }));
vi.mock('./actions', () => ({ openDialog: vi.fn(), openExport: vi.fn(), openFilesDialog: vi.fn(), restartHost: vi.fn(), revealSettings: vi.fn() }));
vi.mock('../platform', () => ({ platform: () => ({}) }));
vi.mock('../state/session', () => ({
  sessionStore: { getState: () => ({ batchExporting: false }) },
  setAdjustments: vi.fn(), makePair: vi.fn(), openFolder: vi.fn(), copySettings: vi.fn(), currentFitZoom: vi.fn(),
  pasteSettings: vi.fn(), redo: vi.fn(), resetAdjustments: vi.fn(), resetCrop: vi.fn(), resetParams: vi.fn(),
  selectAllFrames: vi.fn(), selectRelative: vi.fn(), setGeometry: vi.fn(), setPages: vi.fn(), setTool: vi.fn(),
  syncSettings: vi.fn(), toggleCompare: vi.fn(), undo: vi.fn(), zoomStep: vi.fn(), zoomTo: vi.fn(), zoomToFit: vi.fn(),
}));

import { installMenu, installedMenu, refreshRecentMenu } from './menus';
import { forgetRecentFolders, rememberFolder, settingsStore } from '../state/settings';

type FakeSubmenu = InstanceType<typeof fake.Submenu>;
type FakeItem = InstanceType<typeof fake.MenuItem>;
const recent = () => installedMenu()!.recent as unknown as FakeSubmenu;
/** The labels under Open Recent, in order (the separator left out). */
const entries = () => recent().children.filter((c) => fake.all.get(c.rid)?.kind === 'item').map((c) => (c as FakeItem).text);

beforeEach(async () => {
  fake.reset();
  settingsStore.getState().set('recentFolders', []);
  await installMenu();
});

describe('the native menu and its resources', () => {
  it('keeps every handle of the bar open once built (an action lives in its handle)', () => {
    expect(fake.created()).toBeGreaterThan(40);
    expect(fake.live.size).toBe(fake.created());
    expect(recent().enabled).toBe(false);
  });

  it('a folder change swaps the Open Recent entries and releases the old ones', async () => {
    const bar = fake.live.size;
    for (const dir of ['D:/a', 'D:/b', 'D:/c']) { rememberFolder(dir); await refreshRecentMenu(); }
    expect(entries()).toEqual(['D:/c', 'D:/b', 'D:/a', 'Clear Menu']);
    expect(fake.live.size).toBe(bar + 3);
    expect(recent().enabled).toBe(true);
    const built = fake.all.size;
    for (let i = 0; i < 10; i++) { rememberFolder(`D:/r${i}`); await refreshRecentMenu(); }
    expect(entries()[0]).toBe('D:/r9');
    expect(fake.live.size).toBe(bar + entries().length - 1);
    // Only folder entries were made since; no menu or submenu was built again.
    expect(new Set([...fake.all.values()].slice(built).map((r) => r.kind))).toEqual(new Set(['item']));
  });

  it('opening the folder already in front again changes nothing', async () => {
    rememberFolder('D:/a');
    await refreshRecentMenu();
    const before = settingsStore.getState().recentFolders;
    const made = fake.created();
    rememberFolder('D:/a');
    await refreshRecentMenu();
    expect(settingsStore.getState().recentFolders).toBe(before);
    expect(fake.created()).toBe(made);
    expect(entries()).toEqual(['D:/a', 'Clear Menu']);
  });

  it('clearing the list releases every entry and disables the submenu', async () => {
    rememberFolder('D:/a');
    rememberFolder('D:/b');
    await refreshRecentMenu();
    const bar = fake.live.size - 2;
    forgetRecentFolders();
    await refreshRecentMenu();
    expect(entries()).toEqual(['Clear Menu']);
    expect(fake.live.size).toBe(bar);
    expect(recent().enabled).toBe(false);
  });

  it('a rebuild (language change) releases the menu it replaces', async () => {
    rememberFolder('D:/a');
    await refreshRecentMenu();
    const once = fake.live.size;
    const before = new Set(fake.live);
    await installMenu();
    await installMenu();
    expect(fake.live.size).toBe(once);
    expect([...fake.live].some((rid) => before.has(rid))).toBe(false); // all new handles, none of the old
    expect(entries()).toEqual(['D:/a', 'Clear Menu']);
  });

  it('updates apply in order: a slow earlier one cannot overwrite a newer list', async () => {
    let go!: () => void;
    fake.stall(new Promise<void>((r) => { go = r; }));
    rememberFolder('D:/old');
    const first = refreshRecentMenu();
    rememberFolder('D:/new');
    const second = refreshRecentMenu();
    await Promise.resolve();
    expect(entries()).toEqual(['Clear Menu']); // the first update is still waiting on its entry
    fake.stall(null);
    go();
    await first;
    await second;
    expect(entries()).toEqual(['D:/new', 'D:/old', 'Clear Menu']);
  });
});
