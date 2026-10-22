// Scene Placement's local fit and admissible range, ported from upstream
// f1440bd1 Model/Latitude.swift. The engine's latitude_fit.cpp is the oracle.
// A measurement is immutable; dragging a slider never waits for another RPC.
import { SCENE_LATITUDE_DEFAULT, type SceneLatitudeSettings } from './params';

export type PlacementSide = 'highlight' | 'shadow';
export interface PlacementIssue { code: string; side: string; message: string }
export interface LatitudeFitSide {
  on: boolean; pull_back: number; minimum_pull_back: number;
  scene_extreme_ev: number; medium_boundary_ev: number;
  knee?: number; room?: number; landing_ev: number; slope_at_extreme: number;
}
export interface LatitudeFit {
  valid: boolean; issues: PlacementIssue[]; warnings: PlacementIssue[];
  highlight: LatitudeFitSide; shadow: LatitudeFitSide; core_stops?: number;
  params_delta?: {
    scene_latitude_active: boolean; scene_latitude_norm: string;
    scene_latitude_highlight_knee: number; scene_latitude_highlight_room: number;
    scene_latitude_shadow_knee: number; scene_latitude_shadow_room: number;
    scene_latitude_rolloff: number; scene_latitude_max_lift: number;
  };
}
export interface LatitudeReply {
  medium: { shadow_ev: number; highlight_ev: number; latitude_stops: number;
    y_black: number; y_white: number; ramp_ev: number[]; ramp_y: number[] };
  scene: { norm: string; samples: number; p0_1: number; p1: number; p50: number; p99: number; p99_9: number;
    histogram: { lo_ev: number; hi_ev: number; fractions: number[]; placed_fractions?: number[] } };
  suggested: { highlight_pull_back: number; shadow_pull_back: number; margin_used: number; valid: boolean };
  fit: LatitudeFit;
}
export interface PlacementMeasured {
  highlightExtreme: number; highlightBoundary: number; shadowExtreme: number; shadowBoundary: number;
}
export type PlacementOutcome = { placed: SceneLatitudeSettings; issue?: never } | { issue: PlacementIssue; placed?: never };
export interface PlacementWindow { span: [number, number] | null; below: PlacementIssue; above: PlacementIssue | null }
export const PLACEMENT_RANGE: [number, number] = [0, 8];

export function latitudeRequest(s: SceneLatitudeSettings): Record<string, unknown> {
  return { highlight_pull_back: s.highlightPullBack, shadow_pull_back: s.shadowPullBack,
    rolloff: s.rolloff, max_lift: s.maxLift, norm: s.norm,
    shadow_percentile: s.shadowPercentile, highlight_percentile: s.highlightPercentile };
}

/** A copied intent is not the source photograph's solved curve. */
export function placementIntent(s: SceneLatitudeSettings): SceneLatitudeSettings {
  return { ...SCENE_LATITUDE_DEFAULT, highlightPullBack: s.highlightPullBack, shadowPullBack: s.shadowPullBack,
    highlightPercentile: s.highlightPercentile, shadowPercentile: s.shadowPercentile,
    norm: s.norm, rolloff: s.rolloff, maxLift: s.maxLift };
}

export function measuredFromReply(reply: LatitudeReply | null): PlacementMeasured | null {
  if (!reply?.fit?.highlight || !reply.fit.shadow) return null;
  const h = reply.fit.highlight, s = reply.fit.shadow;
  const m = { highlightExtreme: h.scene_extreme_ev, highlightBoundary: h.medium_boundary_ev,
    shadowExtreme: s.scene_extreme_ev, shadowBoundary: s.medium_boundary_ev };
  return Object.values(m).every(Number.isFinite) ? m : null;
}

/** A refused or incomplete engine response can never become a committed edit. */
export function applyLatitudeFit(base: SceneLatitudeSettings, fit: LatitudeFit): SceneLatitudeSettings | null {
  const d = fit?.params_delta;
  if (!fit?.valid || !d || typeof d.scene_latitude_active !== 'boolean' || !['power', 'y', 'max'].includes(d.scene_latitude_norm)) return null;
  const out = { ...base, highlightPullBack: fit.highlight?.pull_back, shadowPullBack: fit.shadow?.pull_back,
    active: d.scene_latitude_active, norm: d.scene_latitude_norm,
    highlightKnee: d.scene_latitude_highlight_knee, highlightRoom: d.scene_latitude_highlight_room,
    shadowKnee: d.scene_latitude_shadow_knee, shadowRoom: d.scene_latitude_shadow_room,
    rolloff: d.scene_latitude_rolloff, maxLift: d.scene_latitude_max_lift };
  return [out.highlightPullBack, out.shadowPullBack, out.highlightKnee, out.highlightRoom,
    out.shadowKnee, out.shadowRoom, out.rolloff, out.maxLift].every(Number.isFinite) ? out : null;
}

const minimum = (at: PlacementMeasured, side: PlacementSide) => side === 'highlight'
  ? at.highlightExtreme - at.highlightBoundary : at.shadowBoundary - at.shadowExtreme;
const issue = (code: string, side: string): PlacementIssue => ({ code, side, message: '' });

function departure(D: number, H: number, m: number): number {
  if (!(D > 0)) return 0;
  if (m === 2) { const r = Math.sqrt(H * H + D * D); return -(D * D * D) / (r * (H + r)); }
  if (m === 1) return -(D * D) / (H + D);
  return D * (H / Math.pow(Math.pow(H, m) + Math.pow(D, m), 1 / m) - 1);
}

function solveKnee(a: number, C: number, N: number, m: number): number | null {
  const t = a - N;
  if (!(N > 0 && t < C)) return null;
  const landing = (K: number) => K + ((a - K) + departure(a - K, C - K, m));
  const seed = t - Math.sqrt(Math.max(0, (a - t) * (C - t)));
  let lo = seed - 64, hi = t;
  if (!(landing(lo) < t)) return null;
  for (let i = 0; i < 200 && hi - lo > 1e-12; i++) {
    const mid = 0.5 * (lo + hi);
    if (landing(mid) > t) hi = mid; else lo = mid;
  }
  return 0.5 * (lo + hi);
}

export function fitPlacement(at: PlacementMeasured, highlight: number, shadow: number, base: SceneLatitudeSettings): PlacementOutcome {
  if (![...Object.values(at), highlight, shadow, base.rolloff, base.maxLift].every(Number.isFinite)) return { issue: issue('out_of_range', 'both') };
  const out = { ...base, active: true, highlightPullBack: highlight, shadowPullBack: shadow, highlightRoom: 0, shadowRoom: 0 };
  const issues: PlacementIssue[] = [];
  let top: { knee: number; room: number } | null = null;
  let bottom: { knee: number; room: number } | null = null;
  if (highlight > 0) {
    const k = solveKnee(at.highlightExtreme, at.highlightBoundary, highlight, base.rolloff);
    if (k !== null) top = { knee: k, room: at.highlightBoundary - k };
    else issues.push(issue('pull_back_below_minimum', 'highlight'));
  }
  let lift: number | null = null;
  if (shadow > 0 && !(shadow > minimum(at, 'shadow'))) issues.push(issue('pull_back_below_minimum', 'shadow'));
  else if (shadow > 0) {
    const L = base.maxLift;
    if (shadow < L) lift = shadow * L / Math.sqrt(L * L - shadow * shadow);
    else issues.push(issue('pull_back_exceeds_max_lift', 'shadow'));
  }
  if (lift !== null) {
    const k = solveKnee(-at.shadowExtreme, -at.shadowBoundary, lift, base.rolloff);
    if (k !== null) bottom = { knee: -k, room: -k - at.shadowBoundary };
    else issues.push(issue('pull_back_below_minimum', 'shadow'));
  }
  for (const [side, name] of [[top, 'highlight'], [bottom, 'shadow']] as const) {
    if (!side) continue;
    if (side.room < 0.5) issues.push(issue('room_below_minimum', name));
    if (side.room > 24 || Math.abs(side.knee) > 24) issues.push(issue('out_of_range', name));
  }
  if (top && bottom && !(bottom.knee < top.knee)) issues.push(issue('knees_cross', 'both'));
  if (issues.length) return { issue: issues[0]! };
  out.active = top !== null || bottom !== null;
  if (top) { out.highlightKnee = top.knee; out.highlightRoom = top.room; }
  if (bottom) { out.shadowKnee = bottom.knee; out.shadowRoom = bottom.room; }
  return { placed: out };
}

export function placementWindow(at: PlacementMeasured, side: PlacementSide, other: number, base: SceneLatitudeSettings): PlacementWindow {
  const verdict = (x: number) => fitPlacement(at, side === 'highlight' ? x : other, side === 'shadow' ? x : other, base);
  const own = (why: PlacementIssue) => ({ ...why, side });
  let below = issue('pull_back_below_minimum', side);
  let refusedAt = Math.max(minimum(at, side), 0);
  let first: number | null = null;
  for (let x = Math.floor(refusedAt / 0.125) * 0.125 + 0.125; x <= 8 + 1e-9; x += 0.125) {
    const v = verdict(x);
    if (v.issue) { below = own(v.issue); refusedAt = x; } else { first = x; break; }
  }
  if (first === null) return { span: null, below: { ...below, code: 'no_window' }, above: null };
  let bad = refusedAt, good = first;
  while (good - bad > 0.005) {
    const mid = (bad + good) / 2, v = verdict(mid);
    if (v.issue) { below = own(v.issue); bad = mid; } else good = mid;
  }
  const least = Math.min(Math.ceil(good / 0.01) / 100, first);
  let most = 8, above: PlacementIssue | null = null;
  const top = verdict(8);
  if (top.issue) {
    above = own(top.issue); good = first; bad = 8;
    while (bad - good > 0.005) {
      const mid = (bad + good) / 2, v = verdict(mid);
      if (v.issue) { above = own(v.issue); bad = mid; } else good = mid;
    }
    most = Math.max(Math.floor(good / 0.01) / 100, least);
  }
  return { span: [least, most], below, above };
}

export function placementLanding(window: PlacementWindow, asked: number): { value: number; issue: PlacementIssue | null } {
  if (!(asked > 0)) return { value: 0, issue: null };
  if (!window.span) return { value: 0, issue: window.below };
  if (asked < window.span[0]) return { value: window.span[0], issue: window.below };
  if (asked > window.span[1]) return { value: window.span[1], issue: window.above };
  return { value: asked, issue: null };
}

export function placementMessage(why: PlacementIssue | null, side: PlacementSide, reply: LatitudeReply | null, chinese = false): string | null {
  if (!why || (why.side !== side && why.side !== 'both')) return null;
  const words = (en: string, zh: string) => chinese ? zh : en;
  switch (why.code) {
    case 'pull_back_below_minimum': {
      const min = reply?.fit?.[side]?.minimum_pull_back;
      return min && min > 0
        ? words(`Pull back more than ${min.toFixed(2)} stops to bring this extreme inside the latitude.`, `回拉需大于 ${min.toFixed(2)} 档，才能将场景极值拉回宽容度之内。`)
        : words('Pull back further: this extreme is still past the latitude edge.', '回拉不足，场景极值仍在宽容度边界之外。');
    }
    case 'room_below_minimum': return words('Pull back a little more: the transition would turn too sharply.', '回拉再多一些，否则过渡会过于生硬。');
    case 'no_window': return words('No pull-back can bring this side inside the latitude.', '这一侧没有可用的回拉量，无法拉回宽容度之内。');
    case 'out_of_range': return words('Pull back less: this is beyond the curve’s reach.', '回拉过多，已超出曲线可达的范围。');
    case 'pull_back_exceeds_max_lift': return words('Pull back less: this exceeds the shadow lift limit.', '回拉过多，已超出阴影可提升的上限。');
    case 'knees_cross': return words('The highlight and shadow curves would cross; reduce one side.', '高光与阴影曲线会交叉，请减少其中一侧的回拉。');
    default: return why.message || words('The placement could not be fitted to this frame.', '此场景置位无法拟合到当前照片。');
  }
}
