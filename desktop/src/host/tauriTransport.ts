// tauriTransport.ts — the Tauri core's `host_request` and its events.

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { decodeFrame, encodeFrame } from '@shared/framing';
import type { HostState } from '@shared/protocol';
import { HostCallError, type Reply, type RequestOptions, type Transport } from './transport';

function unpack(method: string, buf: ArrayBuffer): Reply {
  const { header, payload } = decodeFrame(new Uint8Array(buf));
  const h = header as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string } };
  if (!h.ok) throw new HostCallError(method, h.error?.code ?? 'internal', h.error?.message ?? 'unknown error');
  return { result: h.result ?? {}, payload };
}

export function tauriTransport(): Transport {
  // listen() registers through async IPC. Do not read a startup snapshot
  // until registration finishes, or a ready event can fall into the gap.
  let stateSubscription: Promise<unknown> = Promise.resolve();
  return {
    kind: 'tauri',
    async request(method, params, opts: RequestOptions = {}) {
      if (opts.payload) {
        const body = encodeFrame({ method, params, timeout_ms: opts.timeoutMs }, opts.payload);
        const buf = await invoke<ArrayBuffer>('host_request_upload', body);
        return unpack(method, buf);
      }
      const buf = await invoke<ArrayBuffer>('host_request', { method, params, timeoutMs: opts.timeoutMs });
      return unpack(method, buf);
    },
    async state() {
      await stateSubscription;
      return invoke<HostState>('host_state');
    },
    onState(cb) {
      const un = listen<HostState>('host-state', (e) => cb(e.payload));
      stateSubscription = un;
      return () => void un.then((f) => f()).catch(() => {});
    },
    onEvent(cb) {
      const un = listen<Record<string, unknown>>('host-event', (e) => cb(e.payload));
      return () => void un.then((f) => f());
    },
    restart: () => invoke('host_restart'),
    diagnostics: () => invoke('host_diagnostics'),
  };
}
