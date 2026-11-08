// browserShim.ts — the host, in the page, for running the interface without
// Tauri (plain `vite`, and the Playwright layout harness in Chromium).
//
// Backed by the same mock as `mock-host/main.ts`, so the shim and the stdio
// mock cannot disagree about the protocol.

import type { HostState } from '@shared/protocol';
import { MockHost } from '../../mock-host/core';
import { HostCallError, type Reply, type Transport } from './transport';

export function browserTransport(): Transport {
  const params = new URLSearchParams(typeof location !== 'undefined' ? location.search : '');
  const mock = new MockHost({
    realisticUnsupported: params.get('allFeatures') !== '1',
    nativeWidth: 1800,
    nativeHeight: 1200,
    renderDelayMs: Number(params.get('renderDelay') ?? 0),
  });
  let id = 1;
  let hello: Record<string, unknown> | null = null;
  const stateListeners = new Set<(s: HostState) => void>();
  const ready = mock.handle({ id: 0, method: 'hello', params: {} }).then((r) => {
    hello = { ...(r.header.result as Record<string, unknown>), mock: true };
    for (const l of stateListeners) l({ phase: 'ready', hello: hello as never });
  });
  return {
    kind: 'browser',
    async request(method, p): Promise<Reply> {
      await ready;
      const r = await mock.handle({ id: id++, method, params: p });
      const h = r.header as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string } };
      if (!h.ok) throw new HostCallError(method, h.error!.code, h.error!.message);
      return { result: h.result ?? {}, payload: r.payload ?? new Uint8Array(0) };
    },
    async state() {
      await ready;
      return { phase: 'ready', hello: hello as never };
    },
    onState(cb) {
      stateListeners.add(cb);
      return () => stateListeners.delete(cb);
    },
    onEvent() {
      return () => {};
    },
    async restart() {},
    async diagnostics() {
      return { state: 'browser shim' };
    },
  };
}
