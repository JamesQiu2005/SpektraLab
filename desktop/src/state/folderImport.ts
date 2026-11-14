import { createStore } from 'zustand/vanilla';
import { settingsStore } from './settings';

export interface FolderImportRequest { id: number; folder: string; total: number; rawCount: number }
export const folderImportStore = createStore<{ request: FolderImportRequest | null }>(() => ({ request: null }));
let sequence = 0;
let reply: ((rawOnly: boolean | null) => void) | null = null;

export function chooseFolderImport(folder: string, total: number, rawCount: number): Promise<boolean | null> {
  reply?.(null);
  return new Promise((resolve) => {
    reply = resolve;
    folderImportStore.setState({ request: { id: ++sequence, folder, total, rawCount } });
  });
}

export function finishFolderImport(rawOnly: boolean | null): void {
  const resolve = reply; reply = null;
  folderImportStore.setState({ request: null });
  if (rawOnly !== null) settingsStore.getState().set('folderRawOnly', rawOnly);
  resolve?.(rawOnly);
}
