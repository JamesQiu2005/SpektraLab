// menus.ts — the native menu bar (`SpektrafilmApp.swift` EditorCommands),
// built in TypeScript so it follows the language switch and calls the store
// directly. Ctrl shortcuts are accelerators (Capture One's mapping, with Ctrl
// for ⌘). Single-key shortcuts are named in the label only — see keys.ts for
// why they must not be accelerators (trap 32).

import { webviewOwnsMenuKeys } from './keys';
import { Menu, MenuItem, PredefinedMenuItem, Submenu } from '@tauri-apps/api/menu';
import { t, tz } from '../i18n';
import { openDialog, openExport, openFilesDialog, restartHost, revealSettings } from './actions';
import {
  setAdjustments,
  makePair,
  openFolder,
  copySettings,
  currentFitZoom,
  pasteSettings,
  redo,
  removeSelectedFrames,
  resetAdjustments,
  resetCrop,
  resetParams,
  selectAllFrames,
  selectRelative,
  sessionStore,
  setGeometry,
  setPages,
  setTool,
  syncSettings,
  toggleCompare,
  undo,
  zoomStep,
  zoomTo,
  zoomToFit,
} from '../state/session';
import { forgetRecentFolders, settingsStore } from '../state/settings';
import { turned } from '@shared/geometry';
import { platform } from '../platform';

/** The Ctrl chords the menu owns; keys.ts leaves them to the menu in Tauri. */
export const MENU_CHORDS = new Set([
  'ctrl+o',
  'ctrl+shift+o',
  'ctrl+e',
  'ctrl+j',
  'ctrl+z',
  'ctrl+shift+z',
  'ctrl+shift+c',
  'ctrl+shift+v',
  'ctrl+a',
  'ctrl+=',
  'ctrl+-',
  'ctrl+0',
  'ctrl+b',
  'ctrl+shift+f',
  'ctrl+shift+b',
  'ctrl+alt+r',
  'ctrl+alt+[',
  'ctrl+alt+]',
  'ctrl+,',
  'ctrl+q',
  'f11',
]);

// Every `MenuItem.new` / `Submenu.new` is a resource in the webview's table
// until it is closed, and an item's `action` lives with that resource: the
// native menu keeps only the item itself, so closing a handle while the item
// is still in the menu leaves it there with nothing to call (tried: Clear
// Menu and Settings… went dead). So every handle of the installed menu stays
// open for as long as the menu is up, and is closed when the item leaves it:
// the folder entries on a change to Open Recent, everything on a rebuild.
type Handle = MenuItem | PredefinedMenuItem | Submenu;
const release = (handles: readonly (Handle | Menu)[]) => Promise.all(handles.map((h) => h.close()));

/** The handles made while the current `rebuild` runs. */
let made: Handle[] = [];
const track = async <T extends Handle>(h: Promise<T>): Promise<T> => { const r = await h; made.push(r); return r; };

const plainItem = (text: string, action: () => void, accelerator?: string) => {
  const webKeys = webviewOwnsMenuKeys();
  return MenuItem.new({
    text: webKeys && accelerator ? `${text}\t${accelerator.replace('CmdOrCtrl', 'Ctrl')}` : text,
    action: () => { if (!sessionStore.getState().batchExporting) action(); },
    accelerator: webKeys ? undefined : accelerator,
  });
};
const item = (text: string, action: () => void, accelerator?: string) => track(plainItem(text, action, accelerator));
const sep = () => track(PredefinedMenuItem.new({ item: 'Separator' }));
const submenu = (text: string, items: readonly Handle[]) => track(Submenu.new({ text, items: [...items] }));

interface Installed {
  menu: Menu;
  /** Every handle of the bar other than the folder entries. */
  handles: Handle[];
  /** File › Open Recent, kept so the folder entries can be swapped in place. */
  recent: Submenu;
  /** The folder entries now in `recent`, newest first, and their paths. */
  folders: MenuItem[];
  shown: readonly string[];
}
let installed: Installed | null = null;

// Menu work runs one job at a time, in the order it was asked for, so a
// rebuild for a language change and the Open Recent updates after it cannot
// overtake each other and leave an older list on screen. Each job reads the
// settings when it runs, so a burst of changes converges on the latest state.
let queue: Promise<void> = Promise.resolve();
const enqueue = (job: () => Promise<void>): Promise<void> => {
  queue = queue.then(job).catch((e) => console.error('menu', e));
  return queue;
};

const folderEntry = (dir: string) =>
  // "&" marks a mnemonic in a native menu; a path keeps its own.
  plainItem(dir.replace(/&/g, '&&'), () => void openFolder(dir));

const sameList = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((p, i) => p === b[i]);

/** File › Open Recent: the folders opened most recently, newest first. */
const recentSubmenu = async (): Promise<Pick<Installed, 'recent' | 'folders' | 'shown'>> => {
  const shown = settingsStore.getState().recentFolders;
  const folders = await Promise.all(shown.map(folderEntry));
  const tail = [await sep(), await item(tz('Clear Menu', '清除列表'), forgetRecentFolders)];
  const recent = await submenu(tz('Open Recent', '最近打开'), [...folders, ...tail]);
  await recent.setEnabled(shown.length > 0);
  return { recent, folders, shown };
};

/** Open Recent follows the settings: the old folder entries leave the submenu
 * and are released, the current list goes in above the separator. The rest
 * of the menu is untouched. */
async function applyRecent(): Promise<void> {
  const cur = installed;
  if (!cur) return;
  const shown = settingsStore.getState().recentFolders;
  if (sameList(shown, cur.shown)) return;
  for (const entry of cur.folders) await cur.recent.remove(entry);
  await release(cur.folders);
  cur.folders = [];
  cur.shown = [];
  const folders = await Promise.all(shown.map(folderEntry));
  if (folders.length) await cur.recent.insert(folders, 0);
  cur.folders = folders;
  cur.shown = shown;
  await cur.recent.setEnabled(shown.length > 0);
}

/** The whole menu bar, built anew (a language change); the one it replaces is
 * released, handle by handle. */
async function rebuild(): Promise<void> {
  made = [];
  const { recent, folders, shown } = await recentSubmenu();
  const file = await submenu(tz('&File', '文件(&F)'), [
    await item(tz('Open Folder…', '打开文件夹…'), () => void openDialog(), 'CmdOrCtrl+O'),
    await item(tz('Open Photographs…', '打开照片…'), () => void openFilesDialog(), 'CmdOrCtrl+Shift+O'),
    recent,
    await item(tz('Export…', '导出…'), openExport, 'CmdOrCtrl+E'),
    await sep(),
    await item(tz('Settings…', '设置…'), () => setPages({ settingsOpen: true }), 'CmdOrCtrl+,'),
    await sep(),
    await item(tz('Quit', '退出'), () => void import('@tauri-apps/api/window').then((w) => w.getCurrentWindow().close()), 'CmdOrCtrl+Q'),
  ]);
  const edit = await submenu(tz('&Edit', '编辑(&E)'), [
    await item(tz('Undo', '撤销'), undo, 'CmdOrCtrl+Z'),
    await item(tz('Redo', '重做'), redo, 'CmdOrCtrl+Shift+Z'),
    await sep(),
    await item(tz('Copy Settings', '拷贝设置'), copySettings, 'CmdOrCtrl+Shift+C'),
    await item(tz('Paste Settings', '粘贴设置'), () => void pasteSettings(), 'CmdOrCtrl+Shift+V'),
    await sep(),
    await item(tz('Select All Photos', '选择全部照片'), selectAllFrames, 'CmdOrCtrl+A'),
    await item(tz('Sync Settings', '同步设置'), () => void syncSettings()),
  ]);
  const view = await submenu(tz('&View', '显示(&V)'), [
    await item(tz('Zoom In', '放大'), () => zoomStep(1, currentFitZoom), 'CmdOrCtrl+='),
    await item(tz('Zoom Out', '缩小'), () => zoomStep(-1, currentFitZoom), 'CmdOrCtrl+-'),
    await item(tz('Zoom to Fit  ( , )', '适合窗口  ( , )'), zoomToFit, 'CmdOrCtrl+0'),
    await item(tz('Zoom to 100 %  ( . )', '缩放到 100 %  ( . )'), () => zoomTo(1)),
    await sep(),
    await item(
      tz('Toggle Side Panels', '显示/隐藏侧栏'),
      () => {
        const s = settingsStore.getState();
        const c = !(s.leftCollapsed && s.rightCollapsed);
        s.set('leftCollapsed', c);
        s.set('rightCollapsed', c);
      },
      'CmdOrCtrl+B',
    ),
    await item(tz('Toggle Filmstrip', '显示/隐藏胶片条'), () => settingsStore.getState().set('filmstripCollapsed', !settingsStore.getState().filmstripCollapsed), 'CmdOrCtrl+Shift+F'),
    await item(tz('Full Screen', '全屏'), () => void platform().toggleFullscreen(), 'F11'),
    await sep(),
    await item(
      tz('Bypass / Restore Adjustments', '停用 / 恢复调整'),
      () => {
        setAdjustments((a) => ({ ...a, enabled: !a.enabled }));
      },
      'CmdOrCtrl+Shift+B',
    ),
    await item(tz('Before / After  (Y)', '前后对比  (Y)'), toggleCompare),
    await sep(),
    await item(tz('Restart Render Service', '重启渲染服务'), () => void restartHost(), 'CmdOrCtrl+Alt+R'),
  ]);
  const frame = await submenu(tz('F&rame', '照片(&R)'), [
    await item(tz('Previous  (←)', '上一张  (←)'), () => selectRelative(-1)),
    await item(tz('Next  (→)', '下一张  (→)'), () => selectRelative(1)),
    await item(tz('Remove from Roll', '从工作台移除'), () => void removeSelectedFrames()),
    await item(tz('New Photo Pair (Half Frame)', '新建双图拼接（半格）'), () => void makePair(), 'CmdOrCtrl+J'),
    await sep(),
    await item(tz('Reset Film, Paper, Camera and Enlarger', '重置胶片、相纸、相机与放大机'), resetParams),
    await item(tz('Reset Adjustments', '重置调整'), resetAdjustments),
    await item(tz('Reveal Settings in File Manager', '在文件管理器中显示设置'), () => void revealSettings()),
  ]);
  const crop = await submenu(tz('&Crop', '裁剪(&C)'), [
    await item(tz('Rotate Left', '向左旋转'), () => setGeometry((g) => turned(g, -1)), 'CmdOrCtrl+Alt+['),
    await item(tz('Rotate Right', '向右旋转'), () => setGeometry((g) => turned(g, 1)), 'CmdOrCtrl+Alt+]'),
    await item(tz('Flip Horizontally', '水平翻转'), () => setGeometry((g) => ({ ...g, flipH: !g.flipH }))),
    await item(tz('Flip Vertically', '垂直翻转'), () => setGeometry((g) => ({ ...g, flipV: !g.flipV }))),
    await sep(),
    await item(tz('Reset Crop', '重置裁剪'), resetCrop),
  ]);
  const tool = await submenu(tz('&Tool', '工具(&T)'), [
    await item(tz('Select  (V)', '选择  (V)'), () => setTool('select')),
    await item(tz('Hand  (H)', '抓手  (H)'), () => setTool('hand')),
    await item(tz('Crop  (C)', '裁剪  (C)'), () => setTool('crop')),
  ]);
  const help = await submenu(tz('&Help', '帮助(&H)'), [
    await item(tz('About SpektraLab', '关于 SpektraLab'), () => setPages({ aboutOpen: true })),
    await item(tz('Show Logs', '显示日志'), () => void platform().appPaths().then((p) => platform().reveal(p.logs))),
  ]);
  const menu = await Menu.new({ items: [file, edit, view, frame, crop, tool, help] });
  // The previous app menu comes back as one more handle; it goes with the rest.
  const previous = await menu.setAsAppMenu();
  const old = installed;
  installed = { menu, handles: made, recent, folders, shown };
  made = [];
  if (previous) await previous.close();
  if (old) await release([...old.folders, ...old.handles, old.menu]);
  void t;
}

/** Build (or rebuild) the native menu bar. Queued behind any menu work in flight. */
export function installMenu(): Promise<void> {
  return enqueue(rebuild);
}

/** Bring File › Open Recent in line with the settings. Queued behind any menu
 * work in flight; a no-op while no menu is installed. */
export function refreshRecentMenu(): Promise<void> {
  return enqueue(applyRecent);
}

/** For tests: what the installed menu shows under Open Recent. */
export const installedMenu = () => installed;
