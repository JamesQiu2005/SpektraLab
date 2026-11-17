// frame.ts — the open frame's session, as the page reaches it (phase 2).
//
// The engine owns the session (WIRE.md, "Sessions"); the page names the frame.
// What the page does on a frame that is not a job but needs its session —
// opening it for its parameters, size and metadata; `set_params`; `solve`;
// `scene_latitude`; `pick_neutral`; `render_source`; `redecode`;
// `update_pair` — goes through the scheduler's `editingOpen` / `editingCall`
// and lands on the engine's own editing session for that frame, under the lock
// its jobs take. `session` here is the handle `open` returned: opaque to the
// page, and refused (`not_found`) once the engine has let that session go
// (another frame's canvas job, `openFrame` moved, or the host restarted). There
// is no `close`: the engine closes it.

import type { OpenResult, WireParams } from '@shared/protocol';
import type { Geometry } from '@shared/geometry';
import type { HalfFramePair } from '@shared/pair';
import { sourceReply, type RgbaImage } from '../host/replies';
import { scheduler } from './index';

export interface FrameHost {
  open(path: string, params: WireParams, decode?: object | null): Promise<OpenResult>;
  openPair(path: string, params: WireParams, pair: HalfFramePair): Promise<OpenResult>;
  updatePair(session: string, pair: HalfFramePair, params: WireParams): Promise<OpenResult>;
  redecode(session: string, decode: object): Promise<OpenResult>;
  setParams(session: string, delta: WireParams): Promise<WireParams>;
  solve(session: string, target?: string): Promise<Record<string, unknown>>;
  sceneLatitude(session: string, request: Record<string, unknown>, snapshot?: { params?: WireParams; source_geometry?: Geometry }): Promise<Record<string, unknown>>;
  pickNeutral(session: string, x: number, y: number, side?: 'left' | 'right'): Promise<{ temperature_k: number; tint: number }>;
  renderSource(session: string, opts: { long_edge: number; display: 'srgb' | 'display-p3'; generation: number }): Promise<RgbaImage>;
}

/** The frame `frameId` (the page's frame id: its path, or a pair's key). */
export function frameHost(frameId: string): FrameHost {
  const s = () => scheduler();
  const call = async (session: string, method: string, params: Record<string, unknown>) => (await s().editingCall(frameId, session, method, params)).result;
  return {
    async open(path, params, decode) {
      return (await s().editingOpen(frameId, { path, params: params as Record<string, unknown>, ...(decode ? { decode: decode as Record<string, unknown> } : {}) })).result as unknown as OpenResult;
    },
    async openPair(path, params, pair) {
      return (await s().editingOpen(frameId, { path, params: params as Record<string, unknown>, pair: structuredClone(pair) })).result as unknown as OpenResult;
    },
    updatePair: async (session, pair, params) => (await call(session, 'update_pair', { params, pair: structuredClone(pair) })) as unknown as OpenResult,
    redecode: async (session, decode) => (await call(session, 'redecode', { decode })) as unknown as OpenResult,
    setParams: async (session, delta) => ((await call(session, 'set_params', { delta })) as { params: WireParams }).params,
    solve: (session, target = 'both') => call(session, 'solve', { target }),
    sceneLatitude: (session, request, snapshot) => call(session, 'scene_latitude', { request, ...snapshot }),
    pickNeutral: async (session, x, y, side) => (await call(session, 'pick_neutral', { x, y, ...(side ? { side } : {}) })) as { temperature_k: number; tint: number },
    async renderSource(session, opts) {
      const r = await s().editingCall(frameId, session, 'render_source', { ...opts });
      return sourceReply(r.result, r.payload, opts.generation);
    },
  };
}
