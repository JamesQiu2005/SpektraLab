// typedCaller.ts — the in-page mock engine's way to the host: each call
// through the page's typed host client (`host()`), its decoded reply put back
// into the protocol's `{result, payload}` so a job's outcome reads as the Rust
// scheduler's does (WIRE.md: `hostResult` and the payload). Only the browser
// mock and the unit tests run this: in the app, the Rust engine calls the host.

import { host } from '../host/client';
import { encodeImage } from '../host/replies';
import type { HostCaller } from './mockEngine';
import type { HostReply } from './types';
import type { Tier, WireParams } from '@shared/protocol';
import type { HalfFramePair } from '@shared/pair';

const EMPTY = new Uint8Array(0);
const reply = (result: unknown): HostReply => ({ result: (result ?? {}) as Record<string, unknown>, payload: EMPTY });

export const typedCaller: HostCaller = async (method, p) => {
  const h = host() as unknown as Record<string, unknown> & ReturnType<typeof host>;
  const has = (k: string) => typeof h[k] === 'function';
  const s = String(p.session ?? '');
  switch (method) {
    case 'open': if (has('open')) return reply(await h.open(String(p.path), p.params as WireParams, p.decode as object | undefined)); break;
    case 'open_pair': if (has('openPair')) return reply(await h.openPair(String(p.path), p.params as WireParams, p.pair as HalfFramePair)); break;
    case 'close': if (has('close')) { await h.close(s); return reply({}); } if (!h.transport) return reply({}); break;
    case 'set_params': if (has('setParams')) return reply({ params: await h.setParams(s, p.delta as WireParams) }); break;
    case 'redecode': if (has('redecode')) return reply(await h.redecode(s, p.decode as object)); break;
    case 'update_pair': if (has('updatePair')) return reply(await h.updatePair(s, p.pair as HalfFramePair, p.params as WireParams)); break;
    case 'solve': if (has('solve')) return reply(await h.solve(s, String(p.target ?? 'both'))); break;
    case 'scene_latitude': if (has('sceneLatitude')) {
      const { session: _s, request, ...snapshot } = p;
      return reply(await h.sceneLatitude(s, request as Record<string, unknown>, Object.keys(snapshot).length ? snapshot : undefined));
    } break;
    case 'pick_neutral': if (has('pickNeutral')) return reply(p.side ? await h.pickNeutral(s, Number(p.x), Number(p.y), p.side as 'left' | 'right') : await h.pickNeutral(s, Number(p.x), Number(p.y))); break;
    case 'render_source': if (has('renderSource')) {
      const img = await h.renderSource(s, { long_edge: Number(p.long_edge), display: p.display as 'srgb' | 'display-p3', generation: Number(p.generation) });
      return encodeImage(img, { generation: p.generation, source: 'decoded' });
    } break;
    case 'render_view': if (has('renderView')) {
      const { session: _s, tier, format: _f, progress_id: _p, ...opts } = p;
      const img = await h.renderView(s, tier as Tier, opts as Parameters<typeof h.renderView>[2]);
      return encodeImage(img, { generation: opts.generation, tier: img.tier, print_cached: img.reprinted });
    } break;
    case 'render': if (has('render')) {
      const img = await h.render(s, p.tier as Tier, { reprint: !!p.reprint, progressId: p.progress_id as string | undefined });
      return encodeImage(img, { tier: img.tier, reprinted: img.reprinted });
    } break;
    case 'thumbnail': if (has('thumbnail')) {
      const img = p.embedded_only ? await h.thumbnail(String(p.path), Number(p.long_edge), true) : await h.thumbnail(String(p.path), Number(p.long_edge));
      return encodeImage(img);
    } break;
    case 'cancel': if (has('cancel')) return reply({ was_running: await h.cancel(s, String(p.progress_id)) }); break;
  }
  const r = await h.transport.request(method, p, { timeoutMs: 1_800_000 });
  return { result: r.result, payload: r.payload };
};
