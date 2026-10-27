// tauriTransport.ts — the Tauri core's `host_request` and its events.

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { decodeFrame, encodeFrame } from '@shared/framing';
import type { HostState } from '@shared/protocol';
import { HostCallError, type Reply, type RequestOptions, type Transport } from './transport';

const CHUNK_BYTES = 8 * 1024 * 1024;

async function unpack(method: string, buf: ArrayBuffer): Promise<Reply> {
  const { header, payload } = decodeFrame(new Uint8Array(buf));
  const h = header as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string };
    tauri_download?: {id: string; bytes: number} };
  if (!h.ok) throw new HostCallError(method, h.error?.code ?? 'internal', h.error?.message ?? 'unknown error');
  if (h.tauri_download) {
    const {id, bytes} = h.tauri_download;
    try {
      if (typeof id !== 'string' || !Number.isSafeInteger(bytes) || bytes < 1 || bytes > 1024*1024*1024)
        throw new HostCallError(method, 'bad_response', 'invalid binary download descriptor');
      // Payload starts at offset zero: deep images can be viewed as uint16
      // without another full-frame alignment copy in the exporter.
      const data = new Uint8Array(bytes);
      for (let offset = 0; offset < bytes;) {
        const chunk = new Uint8Array(await invoke<ArrayBuffer>('binary_read', {id, offset}));
        if (!chunk.length || chunk.length > CHUNK_BYTES || chunk.length > bytes-offset)
          throw new HostCallError(method, 'bad_response', 'binary download made no progress or was truncated');
        data.set(chunk, offset);
        offset += chunk.length;
      }
      return {result:h.result ?? {}, payload:data};
    } finally {
      await invoke('binary_drop', {id}).catch(() => {});
    }
  }
  return { result: h.result ?? {}, payload };
}

export function tauriTransport(): Transport {
  return {
    kind: 'tauri',
    async request(method, params, opts: RequestOptions = {}) {
      if (opts.payload) {
        if (opts.payload.length > CHUNK_BYTES) {
          const id = await invoke<string>('host_upload_open', {method, params, timeoutMs:opts.timeoutMs, bytes:opts.payload.length});
          try {
            for (let offset = 0; offset < opts.payload.length; offset += CHUNK_BYTES) {
              const chunk = opts.payload.subarray(offset, Math.min(offset+CHUNK_BYTES, opts.payload.length));
              await invoke('host_upload_chunk', encodeFrame({id, offset}, chunk));
            }
            const buf = await invoke<ArrayBuffer>('host_upload_finish', {id});
            return await unpack(method, buf);
          } finally {
            await invoke('binary_drop', {id}).catch(() => {});
          }
        }
        const body = encodeFrame({ method, params, timeout_ms: opts.timeoutMs }, opts.payload);
        const buf = await invoke<ArrayBuffer>('host_request_upload', body);
        return unpack(method, buf);
      }
      const buf = await invoke<ArrayBuffer>('host_request', { method, params, timeoutMs: opts.timeoutMs, chunked:true });
      return unpack(method, buf);
    },
    state: () => invoke<HostState>('host_state'),
    onState(cb) {
      const un = listen<HostState>('host-state', (e) => cb(e.payload));
      return () => void un.then((f) => f());
    },
    onEvent(cb) {
      const un = listen<Record<string, unknown>>('host-event', (e) => cb(e.payload));
      return () => void un.then((f) => f());
    },
    restart: () => invoke('host_restart'),
    diagnostics: () => invoke('host_diagnostics'),
  };
}
