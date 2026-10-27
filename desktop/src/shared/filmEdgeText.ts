// Session+FilmEdge.swift::edgeText(for:gauge:). These are the stock's edge
// markings, which can differ from the catalogue's display name and by gauge.
import stockNames from './stockNames.json';

const MARKS: Record<string, [string, string]> = {
  kodak_gold_200: ['KODAK GB 200-7', 'KODAK 200'],
  kodak_portra_800: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_portra_800_push1: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_portra_800_push2: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_ultramax_400: ['KODAK GC 400', 'KODAK GC 400'],
  kodak_ektachrome_100: ['KODAK E100', 'KODAK E100'],
  fujifilm_c200: ['FUJI 200', 'FUJI 200'],
  fujifilm_xtra_400: ['S-400', 'FUJI S-400'],
  fujifilm_pro_400h: ['PRO400H', 'FUJI PRO400H'],
  fujifilm_provia_100f: ['FUJI RDPIII', 'FUJI RDPIII'],
  fujifilm_velvia_100: ['RVP100', 'FUJI RVP100'],
  kodak_vision3_50d: ['EASTMAN 5203', 'EASTMAN 5203'],
  kodak_vision3_250d: ['EASTMAN 5207', 'EASTMAN 5207'],
  kodak_vision3_200t: ['EASTMAN 5213', 'EASTMAN 5213'],
  kodak_vision3_500t: ['EASTMAN 5219', 'EASTMAN 5219'],
  kodak_tri_x_400: ['KODAK 400TX', 'KODAK 400TX'],
  kodak_tmax_100: ['KODAK 100TMX', 'KODAK 100TMX'],
  fujifilm_neopan_acros_100_ii: ['FUJI 100 ACROS II', 'FUJI 100 ACROS II'],
  ilford_hp5_plus_400: ['ILFORD HP5 PLUS', 'ILFORD HP5 PLUS'],
};

export function stockEdgeText(id: string, format: string): string {
  const own = MARKS[id];
  if (own) return own[format.startsWith('120') ? 1 : 0];
  return ((stockNames as Record<string, string>)[id] ?? '').split('(')[0]!.trim().toUpperCase();
}
