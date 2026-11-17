// tauriLibrary.ts — the Library's door in the app: the Tauri commands
// `library_call(method, params)` and `library_state()` over
// `spk_library::LibraryHost` (src-tauri/src/library.rs; the helper is
// spklib-host, resolved beside the engine host). Errors arrive as the helper's
// own `{code, message, data}` and leave as `LibraryError`.

import { invoke } from '@tauri-apps/api/core';
import { LibraryError, type LibraryClient, type LibraryErrorCode, type LibraryState } from './client';

export type Invoke = <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;

export class TauriLibrary implements LibraryClient {
  constructor(private readonly call_: Invoke = invoke as Invoke) {}
  async call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    try {
      return await this.call_<T>('library_call', { method, params });
    } catch (e) {
      const x = (typeof e === 'object' && e ? e : { message: String(e) }) as { code?: string; message?: string; data?: unknown };
      throw new LibraryError((x.code ?? 'internal') as LibraryErrorCode, x.message ?? String(e), x.data ?? null);
    }
  }
  state(): Promise<LibraryState> { return this.call_<LibraryState>('library_state'); }
}
