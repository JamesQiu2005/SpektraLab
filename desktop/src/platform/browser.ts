// The browser stand-in: a fixed mock roll and localStorage for sidecars.

import type { AppPaths, FileEntry, Platform } from './index';

const ROLL = '/mock/Roll 01';
const NAMES = ['DSC_0001.NEF', 'DSC_0002.NEF', 'DSC_0003.NEF', 'DSC_0004.ARW', 'DSC_0005.ARW', 'IMG_0006.CR3', 'scan_0007.tif', 'scan_0008.jpg'];

function entries(dir: string): FileEntry[] {
  return NAMES.map((name, i) => ({ path: `${dir}/${name}`, name, size: 24_000_000 + i, mtime_ms: 1.79e12 + i * 1000 }));
}

function ls(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function browserPlatform(): Platform {
  const dropListeners = new Set<(p: string[]) => void>();
  const openListeners = new Set<(p: string[]) => void>();
  (window as unknown as Record<string, unknown>).__spkOpenPaths = (paths: string[]) => openListeners.forEach((l) => l(paths));
  return {
    kind: 'browser',
    listImages: async (dir) => entries(dir),
    expandPaths: async (paths) =>
      paths.flatMap((p) => (/\.[a-z0-9]+$/i.test(p) ? [{ path: p, name: p.split('/').pop()!, size: 1, mtime_ms: 0 }] : entries(p))),
    async sidecarLoad(image) {
      const v = ls()?.getItem('sidecar:' + image);
      return v ? JSON.parse(v) : null;
    },
    async sidecarSave(image, sidecar) {
      ls()?.setItem('sidecar:' + image, JSON.stringify(sidecar));
      return 'localStorage:sidecar:' + image;
    },
    sidecarPath: async (image) => 'localStorage:sidecar:' + image,
    async storeRead(area, name) {
      const v = ls()?.getItem(`store:${area}/${name}`);
      return v ? JSON.parse(v) : null;
    },
    async storeWrite(area, name, value) {
      ls()?.setItem(`store:${area}/${name}`, JSON.stringify(value));
    },
    takeLaunchPaths: async () => {
      const q = new URLSearchParams(location.search).get('open');
      return q === null ? [] : [q || ROLL];
    },
    pathExists: async () => false,
    ensureDir: async () => {},
    appPaths: async (): Promise<AppPaths> => ({
      appData: '(browser)',
      sidecars: '(localStorage)',
      logs: '(console)',
      home: '/mock',
      pictures: '/mock',
      os: 'browser',
      version: '1.3.1',
    }),
    pickFolder: async () => ROLL,
    pickFiles: async () => entries(ROLL).slice(0, 3).map((e) => e.path),
    pickSave: async (_t, defaultPath) => defaultPath,
    reveal: async (p) => console.info('reveal', p),
    openUrl: async (u) => void window.open(u, '_blank'),
    message: async (title, text) => window.alert(`${title}\n\n${text}`),
    confirm: async (title, text) => window.confirm(`${title}\n\n${text}`),
    onOpenPaths(cb) {
      openListeners.add(cb);
      return () => openListeners.delete(cb);
    },
    onDrop(cb) {
      dropListeners.add(cb);
      return () => dropListeners.delete(cb);
    },
    setTitle: async (t) => void (document.title = t),
    log: (level, m) => console[level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'info'](m),
    toggleFullscreen: async () => {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    },
  };
}
