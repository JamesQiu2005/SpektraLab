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
    supportsNoFilm: params.get('noFilm') !== '0',
    nativeWidth: 1800,
    nativeHeight: 1200,
    renderDelayMs: Number(params.get('renderDelay') ?? 0),
  });
  let id = 1;
  let hello: Record<string, unknown> | null = null;
  // The layout harness's levers (T3): `?failRenders=N` fails the next N
  // renders like a lost GPU; `?hostFail=1` is an engine that cannot start
  // (PC-E13); `?unsupported=a,b` adds refusals to the capabilities (R7).
  let failRenders = Number(params.get('failRenders') ?? 0);
  const hostFail = params.get('hostFail') === '1';
  const extraUnsupported = (params.get('unsupported') ?? '').split(',').filter(Boolean);
  const failed: HostState = { phase: 'failed', reason: 'No Vulkan device was found.', detail: 'vkEnumeratePhysicalDevices returned 0 devices' };
  (globalThis as Record<string, unknown>).__spkMock = { failNextRenders: (n: number) => { failRenders = n; } };
  const stateListeners = new Set<(s: HostState) => void>();
  const ready = mock.handle({ id: 0, method: 'hello', params: {} }).then((r) => {
    const h = r.header.result as Record<string, unknown> & { capabilities?: { backend?: { unsupported_features?: string[] } } };
    if (extraUnsupported.length && h.capabilities?.backend)
      h.capabilities.backend.unsupported_features = [...(h.capabilities.backend.unsupported_features ?? []), ...extraUnsupported];
    hello = { ...h, mock: true };
    for (const l of stateListeners) l(hostFail ? failed : { phase: 'ready', hello: hello as never });
  });
  return {
    kind: 'browser',
    async request(method, p, opts): Promise<Reply> {
      await ready;
      if (hostFail) throw new HostCallError(method, 'host_unavailable', 'No Vulkan device was found.');
      if ((method === 'render_view' || method === 'render') && failRenders > 0) {
        failRenders--;
        throw new HostCallError(method, 'internal', 'The graphics device stopped responding.');
      }
      const r = await mock.handle({ id: id++, method, params: p, payload: opts?.payload });
      const h = r.header as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string } };
      if (!h.ok) throw new HostCallError(method, h.error!.code, h.error!.message);
      return { result: h.result ?? {}, payload: r.payload ?? new Uint8Array(0) };
    },
    async state() {
      await ready;
      return hostFail ? failed : { phase: 'ready', hello: hello as never };
    },
    onState(cb) {
      stateListeners.add(cb);
      return () => stateListeners.delete(cb);
    },
    onEvent(cb) {
      return mock.onEvent(cb);
    },
    async restart() {},
    async diagnostics() {
      return { state: 'browser shim' };
    },
  };
}
