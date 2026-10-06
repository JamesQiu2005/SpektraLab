// platform — everything the app asks of the operating system, behind one
// interface: Tauri commands and plugins in the app, an in-memory stand-in in
// the browser (layout harness, plain `vite`).

import { inTauri } from '../host/transport';
import { browserPlatform } from './browser';
import { tauriPlatform } from './tauri';

export interface FileEntry {
  path: string;
  name: string;
  size: number;
  mtime_ms: number;
}

export interface AppPaths {
  appData: string;
  sidecars: string;
  logs: string;
  home: string;
  pictures: string;
  os: string;
  version: string;
}

export interface Platform {
  readonly kind: 'tauri' | 'browser';
  listImages(dir: string): Promise<FileEntry[]>;
  expandPaths(paths: string[]): Promise<FileEntry[]>;
  sidecarLoad(image: string): Promise<unknown | null>;
  sidecarSave(image: string, sidecar: unknown): Promise<string>;
  sidecarPath(image: string): Promise<string>;
  storeRead(area: string, name: string): Promise<unknown | null>;
  storeWrite(area: string, name: string, value: unknown): Promise<void>;
  takeLaunchPaths(): Promise<string[]>;
  appPaths(): Promise<AppPaths>;
  pickFolder(title: string): Promise<string | null>;
  pickFiles(title: string): Promise<string[]>;
  pickSave(title: string, defaultPath: string, ext: string): Promise<string | null>;
  reveal(path: string): Promise<void>;
  openUrl(url: string): Promise<void>;
  message(title: string, text: string, kind?: 'info' | 'warning' | 'error'): Promise<void>;
  confirm(title: string, text: string): Promise<boolean>;
  onOpenPaths(cb: (paths: string[]) => void): () => void;
  onDrop(cb: (paths: string[]) => void): () => void;
  setTitle(title: string): Promise<void>;
  log(level: 'info' | 'warn' | 'error', message: string): void;
  toggleFullscreen(): Promise<void>;
}

let instance: Platform | null = null;
export function platform(): Platform {
  if (!instance) instance = inTauri() ? tauriPlatform() : browserPlatform();
  return instance;
}

/** The path's last component, whichever separator the OS uses. */
export const baseName = (p: string) => p.split(/[\\/]/).pop() ?? p;
export const dirName = (p: string) => {
  const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return i > 0 ? p.slice(0, i) : p;
};
export const joinPath = (dir: string, name: string) => {
  const sep = dir.includes('\\') && !dir.includes('/') ? '\\' : '/';
  return dir.endsWith(sep) ? dir + name : dir + sep + name;
};
