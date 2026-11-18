// commands.ts — every command of the window, once (README §6.1, board_menus):
// its words, its access key, its key, whether it can run now, whether it is a
// checked toggle, and what it does. The title bar's menu bar, the toolbar's
// ···, the picture's flyout and the keyboard all read this table, so "every
// toolbar item is also in a menu" holds by construction.
//
// A gated command (README §3.8) is not in the table at all while the engine
// refuses its feature: absent, not dimmed. A command that cannot run now is
// dimmed (`enabled: false`), never hidden.

import { tz } from '../i18n';
import {
  copySettings, currentFitZoom, pasteSettings, redo, resetAdjustments, resetCrop, resetEnlarger, resetFilmStock,
  selectAllFrames, sessionStore, setAdjustments, setGeometry, setPages, setTool, solveNow,
  toggleCompare, undo, zoomStep, zoomTo, zoomToFit, openPaths, select, recomputeFilmFormat,
} from '../state/session';
import { settingsStore } from '../state/settings';
import { turned } from '@shared/geometry';
import { openDialog, openFilesDialog, openExport, restartHost } from '../windows/actions';
import { platform } from '../platform';
import { closeWindow, toggleFullScreen } from './windowChrome';
import { computeLayout, toggleRail, type RailSide } from './layout';
import { setLibraryView, setUi, setWorkspace, uiStore, goBack } from './ui';
import {
  addFolder, closeLibrary, developTargets, libraryStore, newLibrary, openCaptureOneDialog, openLibrary, openLibraryDialog, pickAll, pickNone,
  refresh, setRating, toggleFavourite,
} from '../library/store';
import { browserRows, exportPaths, stepRow } from '../library/browser';
import { chooseMode } from './modes';

export type MenuId = 'file' | 'edit' | 'view' | 'frame' | 'go' | 'help';

export interface Command {
  id: string;
  label: string;
  /** The access key: a letter of `label` (or the CJK form's "(F)"). */
  access?: string;
  /** The key as the menu shows it (`Ctrl+Shift+C`). */
  keys?: string;
  enabled: boolean;
  checked?: boolean;
  run: () => void;
}
export type MenuEntry = Command | { separator: true } | { submenu: string; label: string; access?: string; items: MenuEntry[]; enabled: boolean };

const sess = () => sessionStore.getState();
const settings = () => settingsStore.getState();

/** The open frame can be edited (not mid-batch; the engine is up). */
const canEdit = () => !!sess().selection && !sess().batchExporting && sess().hostState.phase === 'ready';
const inField = () => {
  const el = document.activeElement as HTMLElement | null;
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
};

export function layoutNow() {
  const u = uiStore.getState(), s = settings();
  return computeLayout({ width: u.window.width, height: u.window.height, leftHidden: s.leftCollapsed, rightHidden: s.rightCollapsed,
    fullGrid: u.fullGrid, navigatorHidden: s.navigatorHidden, overlay: u.overlay, railLeft: s.railLeft, browserWidth: s.browserWidth, fullScreen: u.fullScreen });
}

/** The left column's toggle (F7, Ctrl+B) and the split's (F8): `left` is the column, `right` the browser. */
export function toggleRailCommand(side: RailSide) {
  const u = uiStore.getState();
  // The split pressed under the full grid: the picture comes back beside the browser.
  if (side === 'right' && u.fullGrid) { setUi({ fullGrid: false }); settings().set('rightCollapsed', false); return; }
  const r = toggleRail(side, layoutNow(), u.window.width);
  if (r.hide !== undefined) settings().set(side === 'left' ? 'leftCollapsed' : 'rightCollapsed', r.hide);
  if (r.overlay !== undefined) setUi({ overlay: r.overlay });
}

/** The grid takes the window (G; the Mac's `fullGrid`): pressed in Develop or Edit it goes to the Library with it on. */
export function toggleFullGrid() {
  const u = uiStore.getState();
  if (u.workspace !== 'library') { setWorkspace('library'); setUi({ fullGrid: true, libraryView: 'grid' }); return; }
  setUi({ fullGrid: !u.fullGrid, libraryView: 'grid' });
}

/** Develop ↵ (Enter, double-click): the Library's rows into the editor, the focused one open. */
export async function developFromLibrary() {
  const { open } = developTargets();
  // The editor's roll is the browser's rows (the browser is the roll now); the chosen ones stay chosen.
  const paths = browserRows().filter((r) => r.exists).map((r) => r.path);
  if (!paths.length) return;
  setWorkspace('develop');
  const roll = sess().frames.map((f) => f.path);
  // The roll is already these rows (a row opened on the page brought them): just open the one.
  if (!(roll.length === paths.length && paths.every((p) => roll.includes(p)))) await openPaths(paths);
  if (open && sess().selection !== open) await select(open);
}

/** Export: the browser's chosen frames (in its order), or the open picture alone (`MacDevelopExport`). */
export function exportFromBrowser() {
  const frames = new Set(sess().frames.map((f) => f.path));
  const paths = exportPaths(sess().selection).filter((p) => frames.has(p));
  if (paths.length > 1) sessionStore.setState({ picked: paths });
  else if (sess().selection) sessionStore.setState({ picked: [sess().selection!] });
  openExport();
}

export function showInExplorer() {
  const ws = uiStore.getState().workspace;
  const lib = libraryStore.getState();
  const path = ws === 'library' ? lib.images.find((i) => i.uuid === lib.focus)?.path : sess().selection;
  if (path) void platform().reveal(path);
}

export function commands(): Record<string, Command> {
  const s = sess();
  const u = uiStore.getState();
  const lib = libraryStore.getState();
  const st = settings();
  const l = layoutNow();
  const gate = s.gate;
  const library = u.workspace === 'library';
  const editing = canEdit();
  const rows = browserRows();
  const printed = !!s.selection && s.badge !== null;
  const c = (id: string, label: string, run: () => void, o: Partial<Omit<Command, 'id' | 'label' | 'run'>> = {}): Command =>
    ({ id, label, run, enabled: true, ...o });
  const geo = (fn: Parameters<typeof setGeometry>[0]) => () => setGeometry(fn);
  const list: Command[] = [
    // File
    c('open', tz('Open…', '打开…'), () => void openDialog(), { access: 'O', keys: 'Ctrl+O', enabled: !s.batchExporting }),
    c('import', tz('Import…', '导入…'), () => void openFilesDialog(), { access: 'I', keys: 'Ctrl+Shift+I', enabled: !s.batchExporting }),
    c('newCatalog', tz('New Catalog…', '新建目录…'), () => void newLibrary('catalog'), { access: 'N' }),
    c('newSession', tz('New Session…', '新建会话…'), () => void newLibrary('session'), { access: 'S' }),
    c('openLibrary', tz('Open Library…', '打开图库…'), () => void openLibraryDialog(), { access: 'L' }),
    c('openCaptureOne', tz('Open Capture One Catalog…', '打开 Capture One 目录…'), () => void openCaptureOneDialog(), { access: 'C', keys: 'Ctrl+Shift+O' }),
    c('addFolder', tz('Add a Folder…', '添加文件夹…'), () => void addFolder(), {}),
    c('closeLibrary', tz('Close Library', '关闭图库'), () => void closeLibrary(), { enabled: !!lib.source }),
    c('refreshLibrary', tz('Refresh Library', '刷新图库'), () => void refresh(), { access: 'R', keys: 'F5', enabled: !!lib.source }),
    c('export', tz('Export…', '导出…'), () => (library ? void developFromLibrary().then(exportFromBrowser) : exportFromBrowser()), { access: 'E', keys: 'Ctrl+E', enabled: library ? lib.picked.length > 0 : printed && !s.batchExporting }),
    c('exportLast', tz('Export with the Last Recipe', '用上次的配方导出'), () => openExport(), { access: 'W', keys: 'Ctrl+Shift+E', enabled: printed && !s.batchExporting }),
    c('settings', tz('Settings…', '设置…'), () => setPages({ settingsOpen: true }), { access: 'T', keys: 'Ctrl+,' }),
    c('exit', tz('Exit', '退出'), () => void closeWindow(), { access: 'X', keys: 'Alt+F4' }),
    // Edit
    c('undo', s.undo.length ? tz('Undo', '撤销') : tz('Undo', '撤销'), undo, { access: 'U', keys: 'Ctrl+Z', enabled: editing && s.undo.length > 0 }),
    c('redo', tz('Redo', '重做'), redo, { access: 'R', keys: 'Ctrl+Y', enabled: editing && s.redo.length > 0 }),
    c('cut', tz('Cut', '剪切'), () => document.execCommand('cut'), { access: 't', keys: 'Ctrl+X', enabled: inField() }),
    c('copy', tz('Copy', '复制'), () => document.execCommand('copy'), { access: 'C', keys: 'Ctrl+C', enabled: inField() }),
    c('paste', tz('Paste', '粘贴'), () => document.execCommand('paste'), { access: 'P', keys: 'Ctrl+V', enabled: inField() }),
    // The browser's rows: the library's where one is open, else the folder's frames — in every mode.
    c('selectAll', tz('Select All', '全选'), () => (lib.source ? pickAll() : selectAllFrames()), { access: 'A', keys: 'Ctrl+A' }),
    c('selectNone', tz('Select None', '全不选'), () => (lib.source ? pickNone() : sessionStore.setState({ picked: [] })), { access: 'N', keys: 'Ctrl+Shift+A' }),
    c('copySettings', tz('Copy Settings', '拷贝设置'), copySettings, { access: 'S', keys: 'Ctrl+Shift+C', enabled: editing }),
    c('copySettingsDialog', tz('Copy Settings…', '拷贝设置…'), () => setUi({ copySettingsOpen: true, moreOpen: false }), { access: 'e', keys: 'Ctrl+Alt+Shift+C', enabled: editing }),
    c('pasteSettings', tz('Paste Settings', '粘贴设置'), () => void pasteSettings(), { access: 'P', keys: 'Ctrl+Shift+V', enabled: !!s.clipboard && !s.batchExporting }),
    // The browser's search, in every mode (it is the browser's slim bar).
    c('find', tz('Find', '查找'), () => { if (st.rightCollapsed) st.set('rightCollapsed', false); requestAnimationFrame(() => (document.querySelector('[data-testid="browser-search"]') as HTMLInputElement | null)?.focus()); }, { access: 'F', keys: 'Ctrl+F', enabled: !!lib.source }),
    // View
    // The one window's panes (PRD-W5 R5): the left column, the browser beside the picture, the full grid, the loupe.
    c('leftColumn', tz('Left Column', '左栏'), () => toggleRailCommand('left'), { access: 'L', keys: 'Ctrl+B', checked: l.left === 'docked' || l.left === 'over' }),
    c('browser', tz('Browser', '浏览器'), () => toggleRailCommand('right'), { access: 'B', keys: 'F8', checked: !l.fullGrid && (l.right === 'docked' || l.right === 'over') }),
    c('fullGrid', tz('Grid', '网格'), toggleFullGrid, { access: 'G', keys: 'G', checked: l.fullGrid }),
    c('loupe', tz('Light Table', '看片台'), () => setLibraryView('lightTable'), { access: 'T', keys: 'Ctrl+Shift+L', enabled: !!lib.source }),
    c('navigator', tz('Navigator', '导航器'), () => st.set('navigatorHidden', !st.navigatorHidden), { access: 'N', checked: !st.navigatorHidden }),
    c('zoomIn', tz('Zoom In', '放大'), () => zoomStep(1, currentFitZoom), { access: 'I', keys: 'Ctrl++', enabled: !!s.selection }),
    c('zoomOut', tz('Zoom Out', '缩小'), () => zoomStep(-1, currentFitZoom), { access: 'O', keys: 'Ctrl+−', enabled: !!s.selection }),
    c('zoomFit', tz('Zoom to Fit', '适合窗口'), zoomToFit, { access: 'F', keys: 'Ctrl+0', enabled: !!s.selection }),
    c('zoom100', '100 %', () => zoomTo(1), { access: '1', keys: 'Ctrl+1', enabled: !!s.selection }),
    c('compare', tz('Compare', '对比'), toggleCompare, { access: 'C', keys: 'Y', enabled: !!s.selection, checked: s.comparing }),
    c('bypass', tz('Bypass Adjustments', '停用调整'), () => setAdjustments((a) => ({ ...a, enabled: !a.enabled })), { access: 'B', keys: 'Ctrl+Shift+B', enabled: editing, checked: !s.sidecar.adjustments.enabled }),
    c('fullScreen', tz('Full Screen', '全屏'), () => void toggleFullScreen(), { access: 'u', keys: 'F11', checked: u.fullScreen }),
    // Frame
    c('developAgain', tz('Develop Again', '重新冲洗'), () => void solveNow(), { access: 'D', keys: 'Ctrl+Enter', enabled: editing }),
    // Crop is persistent (the shared bar's): pressed in the Library it is the open picture's, on the Develop page.
    c('crop', tz('Crop', '裁剪'), () => { if (library) void chooseMode('develop').then(() => setTool('crop')); else setTool(s.tool === 'crop' ? 'select' : 'crop'); }, { access: 'C', keys: 'C', enabled: editing, checked: s.tool === 'crop' }),
    c('rotateLeft', tz('Rotate Left', '向左旋转'), geo((g) => turned(g, -1)), { access: 'L', keys: 'Ctrl+[', enabled: editing }),
    c('rotateRight', tz('Rotate Right', '向右旋转'), geo((g) => turned(g, 1)), { access: 'R', keys: 'Ctrl+]', enabled: editing }),
    c('flipH', tz('Flip Horizontal', '水平翻转'), geo((g) => ({ ...g, flipH: !g.flipH })), { access: 'H', enabled: editing }),
    c('flipV', tz('Flip Vertical', '垂直翻转'), geo((g) => ({ ...g, flipV: !g.flipV })), { access: 'V', enabled: editing }),
    c('favourite', tz('Favourite', '收藏'), () => void toggleFavourite(), { access: 'F', keys: '.', enabled: library && !!lib.focus }),
    c('resetFilmPaper', tz('Film & Paper', '胶片与相纸'), resetFilmStock, { enabled: editing }),
    c('resetFormat', tz('Format', '画幅'), () => recomputeFilmFormat(), { enabled: editing }),
    c('resetAdjust', tz('Adjust', '调整'), resetAdjustments, { enabled: editing }),
    c('resetDarkroom', tz('Darkroom', '暗房'), resetEnlarger, { enabled: editing }),
    c('resetCrop', tz('Crop', '裁剪'), resetCrop, { enabled: editing }),
    c('showInExplorer', tz('Show in File Explorer', '在文件资源管理器中显示'), showInExplorer, { access: 'S', keys: 'Ctrl+Shift+R', enabled: library ? !!lib.focus : !!s.selection }),
    // Go
    c('goLibrary', tz('Library', '图库'), () => void chooseMode('library'), { access: 'L', keys: 'Ctrl+Alt+1', checked: library }),
    c('goDevelop', tz('Develop', '冲洗'), () => void chooseMode('develop'), { access: 'D', keys: 'Ctrl+Alt+2', checked: u.workspace === 'develop' }),
    c('goEdit', tz('Edit', '编辑'), () => void chooseMode('edit'), { access: 'E', keys: 'Ctrl+Alt+3', checked: u.workspace === 'edit' }),
    // ← → walk the browser's rows in every mode (PRD-W5 §2).
    c('prevFrame', tz('Previous Frame', '上一张'), () => void stepRow(-1), { access: 'P', keys: '←', enabled: rows.length > 1 }),
    c('nextFrame', tz('Next Frame', '下一张'), () => void stepRow(1), { access: 'N', keys: '→', enabled: rows.length > 1 }),
    c('back', tz('Back', '返回'), goBack, { access: 'B', keys: 'Alt+←', enabled: !!u.previous }),
    // Help
    c('help', tz('SpektraLab Help', 'SpektraLab 帮助'), () => void platform().openUrl('https://github.com/JamesQiu2005/SpektraLab'), { access: 'H', keys: 'F1' }),
    c('keyboard', tz('Keyboard Shortcuts', '键盘快捷键'), () => setPages({ aboutOpen: true }), { access: 'K' }),
    c('updates', tz('Check for Updates…', '检查更新…'), () => { settings().set('settingsPane', 'general'); setPages({ settingsOpen: true }); }, { access: 'U' }),
    c('logs', tz('Show Logs in File Explorer', '在文件资源管理器中显示日志'), () => void platform().appPaths().then((p) => platform().reveal(p.logs)), { access: 'L' }),
    c('diagnostic', tz('Make a Diagnostic Bundle…', '生成诊断包…'), () => { settings().set('settingsPane', 'diagnostics'); setPages({ settingsOpen: true }); }, { access: 'D' }),
    c('about', tz('About SpektraLab', '关于 SpektraLab'), () => setPages({ aboutOpen: true }), { access: 'A' }),
    c('restartEngine', tz('Restart the Engine', '重启引擎'), () => void restartHost(), {}),
  ];
  void gate;
  const out: Record<string, Command> = {};
  for (const x of list) {
    // Nothing runs while a batch is exporting, but looking around (View, Go) and leaving do.
    const look = ['leftColumn', 'browser', 'navigator', 'fullScreen', 'zoomIn', 'zoomOut', 'zoomFit', 'zoom100', 'exit', 'about', 'logs', 'help', 'keyboard'];
    out[x.id] = s.batchExporting && !look.includes(x.id) ? { ...x, enabled: false } : x;
  }
  return out;
}

const sep = { separator: true } as const;

/** The menu bar's six menus, in order (README §6.1). */
export function menuBar(): { id: MenuId; label: string; access: string; items: MenuEntry[] }[] {
  const k = commands();
  const sub = (submenu: string, label: string, items: MenuEntry[], access?: string) => ({ submenu, label, items, access, enabled: items.some((i) => 'enabled' in i && i.enabled) });
  const lib = libraryStore.getState();
  const recent = lib.recent.map((r, i) => ({ id: `recent${i}`, label: r.name, run: () => { setWorkspace('library'); void openLibrary(r.path); }, enabled: true } as Command));
  return [
    { id: 'file', label: tz('File', '文件'), access: 'F', items: [k.open!, k.import!, sub('recent', tz('Open Recent', '最近打开'), recent, 'R'), sep, k.newCatalog!, k.newSession!, k.openLibrary!, k.openCaptureOne!, k.refreshLibrary!, sep, k.export!, k.exportLast!, sep, k.settings!, sep, k.exit!] },
    { id: 'edit', label: tz('Edit', '编辑'), access: 'E', items: [k.undo!, k.redo!, sep, k.cut!, k.copy!, k.paste!, k.selectAll!, k.selectNone!, sep, k.copySettings!, k.copySettingsDialog!, k.pasteSettings!, sep, k.find!] },
    { id: 'view', label: tz('View', '视图'), access: 'V', items: [k.leftColumn!, k.browser!, k.fullGrid!, k.loupe!, k.navigator!, sep, k.zoomIn!, k.zoomOut!, k.zoomFit!, k.zoom100!, sep, k.compare!, k.bypass!, sep, k.fullScreen!] },
    { id: 'frame', label: tz('Frame', '照片'), access: 'R', items: [k.developAgain!, sep, k.crop!, k.rotateLeft!, k.rotateRight!, k.flipH!, k.flipV!, sep, k.favourite!,
      sub('rating', tz('Rating', '评分'), [0, 1, 2, 3, 4, 5].map((n) => ({ id: `rating${n}`, label: n ? '★'.repeat(n) : tz('None', '无'), keys: String(n), run: () => void setRating(n || null), enabled: uiStore.getState().workspace === 'library' && lib.picked.length > 0 } as Command)), 'a'),
      sep, sub('reset', tz('Reset', '重置'), [k.resetFilmPaper!, k.resetFormat!, k.resetAdjust!, k.resetDarkroom!, k.resetCrop!], 's'), sep, k.showInExplorer!] },
    { id: 'go', label: tz('Go', '转到'), access: 'G', items: [k.goLibrary!, k.goDevelop!, k.goEdit!, sep, k.prevFrame!, k.nextFrame!, sep, k.back!] },
    { id: 'help', label: tz('Help', '帮助'), access: 'H', items: [k.help!, k.keyboard!, sep, k.updates!, k.logs!, k.diagnostic!, sep, k.about!] },
  ];
}

/** Keys → commands (the board's keys; single keys stay behind the typing guard in keys.ts). */
export const KEY_COMMANDS: Record<string, string> = {
  'ctrl+o': 'open', 'ctrl+shift+i': 'import', 'ctrl+shift+o': 'openCaptureOne', f5: 'refreshLibrary', 'ctrl+e': 'export', 'ctrl+shift+e': 'exportLast',
  'ctrl+,': 'settings', 'ctrl+z': 'undo', 'ctrl+y': 'redo', 'ctrl+shift+z': 'redo', 'ctrl+a': 'selectAll', 'ctrl+shift+a': 'selectNone',
  'ctrl+shift+c': 'copySettings', 'ctrl+alt+shift+c': 'copySettingsDialog', 'ctrl+shift+v': 'pasteSettings', 'ctrl+f': 'find',
  f7: 'leftColumn', f8: 'browser', 'ctrl+b': 'leftColumn', 'ctrl+alt+v': 'browser', g: 'fullGrid', 'ctrl+=': 'zoomIn', 'ctrl++': 'zoomIn', 'ctrl+-': 'zoomOut',
  'ctrl+0': 'zoomFit', 'ctrl+1': 'zoom100', y: 'compare', 'ctrl+shift+b': 'bypass', f11: 'fullScreen', 'ctrl+enter': 'developAgain', c: 'crop',
  'ctrl+[': 'rotateLeft', 'ctrl+]': 'rotateRight', 'ctrl+alt+[': 'rotateLeft', 'ctrl+alt+]': 'rotateRight', '.': 'favourite', 'ctrl+shift+r': 'showInExplorer',
  'ctrl+alt+1': 'goLibrary', 'ctrl+alt+2': 'goDevelop', 'ctrl+alt+3': 'goEdit', 'ctrl+shift+l': 'loupe', 'alt+arrowleft': 'back', f1: 'help',
};

/** Run a command by id if it exists and can run; returns whether it did. */
export function runCommand(id: string): boolean {
  const cmd = commands()[id];
  if (!cmd || !cmd.enabled) return false;
  cmd.run();
  return true;
}

export { setUi };
