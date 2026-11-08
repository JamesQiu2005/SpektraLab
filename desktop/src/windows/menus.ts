// menus.ts — the native menu bar (`SpektrafilmApp.swift` EditorCommands),
// built in TypeScript so it follows the language switch and calls the store
// directly. Ctrl shortcuts are accelerators (Capture One's mapping, with Ctrl
// for ⌘). Single-key shortcuts are named in the label only — see keys.ts for
// why they must not be accelerators (trap 32).

import { Menu, MenuItem, PredefinedMenuItem, Submenu } from '@tauri-apps/api/menu';
import { t, tz } from '../i18n';
import { openDialog, openExport, openFilesDialog, restartHost, revealSettings } from './actions';
import {
  copySettings,
  currentFitZoom,
  pasteSettings,
  redo,
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
import { settingsStore } from '../state/settings';
import { turned } from '@shared/geometry';
import { platform } from '../platform';

/** The Ctrl chords the menu owns; keys.ts leaves them to the menu in Tauri. */
export const MENU_CHORDS = new Set([
  'ctrl+o',
  'ctrl+shift+o',
  'ctrl+e',
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
]);

const item = (text: string, action: () => void, accelerator?: string) => MenuItem.new({ text, action: () => action(), accelerator });
const sep = () => PredefinedMenuItem.new({ item: 'Separator' });

export async function installMenu(): Promise<void> {
  const file = await Submenu.new({
    text: tz('&File', '文件(&F)'),
    items: [
      await item(tz('Open Folder…', '打开文件夹…'), () => void openDialog(), 'CmdOrCtrl+O'),
      await item(tz('Open Photographs…', '打开照片…'), () => void openFilesDialog(), 'CmdOrCtrl+Shift+O'),
      await item(tz('Export…', '导出…'), openExport, 'CmdOrCtrl+E'),
      await sep(),
      await item(tz('Settings…', '设置…'), () => setPages({ settingsOpen: true }), 'CmdOrCtrl+,'),
      await sep(),
      await item(tz('Quit', '退出'), () => void import('@tauri-apps/api/window').then((w) => w.getCurrentWindow().close()), 'CmdOrCtrl+Q'),
    ],
  });
  const edit = await Submenu.new({
    text: tz('&Edit', '编辑(&E)'),
    items: [
      await item(tz('Undo', '撤销'), undo, 'CmdOrCtrl+Z'),
      await item(tz('Redo', '重做'), redo, 'CmdOrCtrl+Shift+Z'),
      await sep(),
      await item(tz('Copy Settings', '拷贝设置'), copySettings, 'CmdOrCtrl+Shift+C'),
      await item(tz('Paste Settings', '粘贴设置'), () => void pasteSettings(), 'CmdOrCtrl+Shift+V'),
      await sep(),
      await item(tz('Select All Photos', '选择全部照片'), selectAllFrames, 'CmdOrCtrl+A'),
      await item(tz('Sync Settings', '同步设置'), () => void syncSettings()),
    ],
  });
  const view = await Submenu.new({
    text: tz('&View', '显示(&V)'),
    items: [
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
          const s = sessionStore.getState();
          sessionStore.setState({ sidecar: { ...s.sidecar, adjustments: { ...s.sidecar.adjustments, enabled: !s.sidecar.adjustments.enabled } } });
        },
        'CmdOrCtrl+Shift+B',
      ),
      await item(tz('Before / After  (Y)', '前后对比  (Y)'), toggleCompare),
      await sep(),
      await item(tz('Restart Render Service', '重启渲染服务'), () => void restartHost(), 'CmdOrCtrl+Alt+R'),
    ],
  });
  const frame = await Submenu.new({
    text: tz('F&rame', '照片(&R)'),
    items: [
      await item(tz('Previous  (←)', '上一张  (←)'), () => selectRelative(-1)),
      await item(tz('Next  (→)', '下一张  (→)'), () => selectRelative(1)),
      await sep(),
      await item(tz('Reset Film, Paper, Camera and Enlarger', '重置胶片、相纸、相机与放大机'), resetParams),
      await item(tz('Reset Adjustments', '重置调整'), resetAdjustments),
      await item(tz('Reveal Settings in File Manager', '在文件管理器中显示设置'), () => void revealSettings()),
    ],
  });
  const crop = await Submenu.new({
    text: tz('&Crop', '裁剪(&C)'),
    items: [
      await item(tz('Rotate Left', '向左旋转'), () => setGeometry((g) => turned(g, -1)), 'CmdOrCtrl+Alt+['),
      await item(tz('Rotate Right', '向右旋转'), () => setGeometry((g) => turned(g, 1)), 'CmdOrCtrl+Alt+]'),
      await item(tz('Flip Horizontally', '水平翻转'), () => setGeometry((g) => ({ ...g, flipH: !g.flipH }))),
      await item(tz('Flip Vertically', '垂直翻转'), () => setGeometry((g) => ({ ...g, flipV: !g.flipV }))),
      await sep(),
      await item(tz('Reset Crop', '重置裁剪'), resetCrop),
    ],
  });
  const tool = await Submenu.new({
    text: tz('&Tool', '工具(&T)'),
    items: [
      await item(tz('Select  (V)', '选择  (V)'), () => setTool('select')),
      await item(tz('Hand  (H)', '抓手  (H)'), () => setTool('hand')),
      await item(tz('Crop  (C)', '裁剪  (C)'), () => setTool('crop')),
    ],
  });
  const help = await Submenu.new({
    text: tz('&Help', '帮助(&H)'),
    items: [
      await item(tz('About SpektraLab', '关于 SpektraLab'), () => setPages({ aboutOpen: true })),
      await item(tz('Show Logs', '显示日志'), () => void platform().appPaths().then((p) => platform().reveal(p.logs))),
    ],
  });
  const menu = await Menu.new({ items: [file, edit, view, frame, crop, tool, help] });
  await menu.setAsAppMenu();
  void t;
}
