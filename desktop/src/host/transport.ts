// transport.ts — how the webview reaches the engine host.
//
// Two implementations of one interface: the Tauri core (`host_request`, a
// binary reply in the protocol's framing) and, outside Tauri, the in-page mock
// (`browserShim.ts`) that the Playwright layout harness and `vite` alone use.

import type { HostState } from '@shared/protocol';

export interface Reply {
  result: Record<string, unknown>;
  payload: Uint8Array;
}

export class HostCallError extends Error {
  code: string;
  method: string;
  constructor(method: string, code: string, message: string) {
    super(message);
    this.code = code;
    this.method = method;
  }
}

export interface RequestOptions {
  timeoutMs?: number;
  /** A binary payload to send with the request (an image to write). */
  payload?: Uint8Array;
}

export interface Transport {
  readonly kind: 'tauri' | 'browser';
  request(method: string, params: Record<string, unknown>, opts?: RequestOptions): Promise<Reply>;
  state(): Promise<HostState>;
  onState(cb: (s: HostState) => void): () => void;
  onEvent(cb: (e: Record<string, unknown>) => void): () => void;
  restart(): Promise<void>;
  diagnostics(): Promise<unknown>;
}

export const inTauri = (): boolean =>
  typeof window !== 'undefined' && '__TAURI_INTERNALS__' in (window as unknown as Record<string, unknown>);
