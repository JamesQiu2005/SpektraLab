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

const ANDROID = typeof navigator !== 'undefined' && /Android/.test(navigator.userAgent);
const PART = 4 << 20;

function base64(bytes: Uint8Array): string {
  const native = (bytes as Uint8Array & { toBase64?: () => string }).toBase64;
  if (native) return native.call(bytes);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/**
 * Android: the WebView cannot hand a request body to the app, so Tauri sends every call there as JSON, and a
 * whole image as JSON (an array of numbers, a few hundred MB of text) runs the WebView out of memory. The
 * payload goes over in 4 MB base64 parts instead (lib.rs `upload_part`), then the request that uses it.
 */
async function uploadInParts(method: string, params: Record<string, unknown>, payload: Uint8Array, timeoutMs?: number) {
  const id = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  try {
    for (let o = 0; o === 0 || o < payload.length; o += PART)
      await invoke('upload_part', { id, offset: o, data: base64(payload.subarray(o, o + PART)) });
  } catch (e) {
    void invoke('upload_discard', { id }).catch(() => {});
    throw e;
  }
  return invoke<ArrayBuffer>('host_request_uploaded', { id, method, params, timeoutMs });
}

export function tauriTransport(): Transport {
  return {
    kind: 'tauri',
    async request(method, params, opts: RequestOptions = {}) {
      if (opts.payload && ANDROID) return unpack(method, await uploadInParts(method, params, opts.payload, opts.timeoutMs));
      if (opts.payload) {
        const body = encodeFrame({ method, params, timeout_ms: opts.timeoutMs }, opts.payload);
        const buf = await invoke<ArrayBuffer>('host_request_upload', body);
        return unpack(method, buf);
      }
      const buf = await invoke<ArrayBuffer>('host_request', { method, params, timeoutMs: opts.timeoutMs });
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
