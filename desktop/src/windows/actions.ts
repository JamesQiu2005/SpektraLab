// actions.ts — commands shared by the menu, the keys and the buttons.

import { tz } from '../i18n';
import { platform } from '../platform';
import { host } from '../host/client';
import { flushSave, openFolder, openPaths, sessionStore, setPages } from '../state/session';

export async function openDialog() {
  if (sessionStore.getState().batchExporting) return;
  const dir = await platform().pickFolder(tz('Open a folder of photographs', '打开照片文件夹'));
  if (dir) await openFolder(dir);
}

export async function openFilesDialog() {
  if (sessionStore.getState().batchExporting) return;
  const files = await platform().pickFiles(tz('Open photographs', '打开照片'));
  if (files.length) await openPaths(files);
}

export async function revealSettings() {
  const sel = sessionStore.getState().selection;
  if (!sel) return;
  await flushSave();
  try {
    await platform().reveal(await platform().sidecarPath(sel));
  } catch {
    const p = await platform().appPaths();
    await platform().reveal(p.sidecars);
  }
}

export async function restartHost() {
  await host().restart();
}

export function openExport() {
  if (sessionStore.getState().selection) setPages({ exportOpen: true });
}
