import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { ask, message, open, save } from '@tauri-apps/plugin-dialog';
import { error as logError, info as logInfo, warn as logWarn } from '@tauri-apps/plugin-log';
import { openUrl, revealItemInDir } from '@tauri-apps/plugin-opener';
import type { AppPaths, FileEntry, Platform } from './index';

export function tauriPlatform(): Platform {
  return {
    kind: 'tauri',
    listImages: (dir) => invoke<FileEntry[]>('list_images', { dir }),
    expandPaths: (paths) => invoke<FileEntry[]>('expand_paths', { paths }),
    sidecarLoad: (image) => invoke<unknown | null>('sidecar_load', { image }),
    sidecarSave: (image, sidecar) => invoke<string>('sidecar_save', { image, sidecar }),
    sidecarPath: (image) => invoke<string>('sidecar_path', { image }),
    storeRead: (area, name) => invoke<unknown | null>('store_read', { area, name }),
    storeWrite: (area, name, value) => invoke<void>('store_write', { area, name, value }),
    takeLaunchPaths: () => invoke<string[]>('take_launch_paths'),
    pathExists: (path) => invoke<boolean>('path_exists', { path }),
    ensureDir: (path) => invoke<void>('ensure_dir', { path }),
    appPaths: () => invoke<AppPaths>('app_paths'),
    async pickFolder(title) {
      const r = await open({ directory: true, multiple: false, title });
      return typeof r === 'string' ? r : null;
    },
    async pickFiles(title) {
      const r = await open({
        multiple: true,
        title,
        filters: [
          {
            name: 'Photographs',
            extensions: ['nef', 'NEF', 'arw', 'ARW', 'cr2', 'CR2', 'cr3', 'CR3', 'raf', 'RAF', 'dng', 'DNG', 'orf', 'ORF', 'rw2', 'RW2', 'pef', 'PEF', 'srw', 'SRW', 'tif', 'tiff', 'TIF', 'TIFF', 'jpg', 'jpeg', 'JPG', 'JPEG', 'png', 'PNG'],
          },
          { name: 'All files', extensions: ['*'] },
        ],
      });
      if (Array.isArray(r)) return r;
      return typeof r === 'string' ? [r] : [];
    },
    async pickSave(title, defaultPath, ext) {
      const r = await save({ title, defaultPath, filters: [{ name: ext.toUpperCase(), extensions: [ext] }] });
      return r ?? null;
    },
    reveal: (path) => revealItemInDir(path),
    openUrl: (url) => openUrl(url),
    async message(title, text, kind = 'info') {
      await message(text, { title, kind });
    },
    confirm: (title, text) => ask(text, { title, kind: 'warning' }),
    onOpenPaths(cb) {
      const un = listen<string[]>('open-paths', (e) => cb(e.payload));
      return () => void un.then((f) => f());
    },
    onDrop(cb) {
      const un = getCurrentWebview().onDragDropEvent((e) => {
        if (e.payload.type === 'drop') cb(e.payload.paths);
      });
      return () => void un.then((f) => f());
    },
    setTitle: (title) => getCurrentWindow().setTitle(title),
    log(level, msg) {
      void (level === 'error' ? logError(msg) : level === 'warn' ? logWarn(msg) : logInfo(msg)).catch(() => {});
    },
    async toggleFullscreen() {
      const w = getCurrentWindow();
      await w.setFullscreen(!(await w.isFullscreen()));
    },
  };
}
