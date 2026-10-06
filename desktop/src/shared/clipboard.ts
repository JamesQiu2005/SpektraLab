// clipboard.ts — RFC-027's settings clipboard (`Model/SettingsClipboard.swift`):
// what Copy Settings takes and what Paste Settings writes, in groups ticked
// at copy time. Pure: Sidecar in, Sidecar out.
//
// A paste writes *settings, not solved numbers*: the target meters its own
// exposure and fits its own Scene Placement (`placementNeedsFit`).

import type { Sidecar } from './sidecar';
import { jsonEqual } from './params';

export const CLIPBOARD_GROUPS = [
  'filmAndPaper',
  'exposure',
  'whiteBalance',
  'filmEffects',
  'printEffects',
  'scenePlacement',
] as const;
export type ClipboardGroup = (typeof CLIPBOARD_GROUPS)[number];

export const GROUP_PATHS: Record<ClipboardGroup, string[]> = {
  filmAndPaper: ['params.filmStock', 'params.printStock', 'params.scanFilm', 'params.digitalIntermediate', 'params.extendedDynamicRange'],
  exposure: ['params.autoExposure', 'params.autoExposureMethod', 'params.exposureCompensationEV', 'params.printBrightnessStops'],
  whiteBalance: ['decode.whiteBalance', 'decode.temperature', 'decode.tint', 'params.yFilterShift', 'params.mFilterShift'],
  filmEffects: [
    'params.filmFormatMM',
    'params.filmFrame',
    'params.filmSide',
    'params.sideLengthMM',
    'params.grainActive',
    'params.halationActive',
    'params.glareActive',
    'params.effects',
  ],
  printEffects: ['params.printEffects', 'params.preflashExposure'],
  scenePlacement: ['params.sceneLatitude', 'placementNeedsFit'],
};

export interface SettingsClip {
  groups: ClipboardGroup[];
  settings: Sidecar;
  sourceName: string;
}

type Obj = Record<string, unknown>;

function getPath(o: Obj, path: string): unknown {
  return path.split('.').reduce<unknown>((v, k) => (v && typeof v === 'object' ? (v as Obj)[k] : undefined), o);
}
function setPath(o: Obj, path: string, value: unknown): Obj {
  const [head, ...rest] = path.split('.');
  if (!rest.length) return { ...o, [head!]: value };
  return { ...o, [head!]: setPath(((o[head!] as Obj) ?? {}) as Obj, rest.join('.'), value) };
}

/** The clip applied to a target sidecar. */
export function applyClip(clip: SettingsClip, target: Sidecar): Sidecar {
  let out = target as unknown as Obj;
  const src = clip.settings as unknown as Obj;
  for (const g of clip.groups) {
    for (const path of GROUP_PATHS[g]) {
      if (path === 'placementNeedsFit') continue;
      out = setPath(out, path, structuredClone(getPath(src, path)));
    }
    if (g === 'scenePlacement') {
      // The pull-backs travel; the fitted curve is the source photograph's own
      // and is re-fitted on the target.
      const sl = (src.params as Obj).sceneLatitude as Obj;
      const active = (sl.highlightPullBack as number) > 0 || (sl.shadowPullBack as number) > 0;
      out = setPath(out, 'placementNeedsFit', active);
    }
  }
  return out as unknown as Sidecar;
}

export function clipChanges(clip: SettingsClip, target: Sidecar): boolean {
  const next = applyClip(clip, target);
  return !jsonEqual(
    { p: next.params, d: next.decode, f: next.placementNeedsFit },
    { p: target.params, d: target.decode, f: target.placementNeedsFit },
  );
}
