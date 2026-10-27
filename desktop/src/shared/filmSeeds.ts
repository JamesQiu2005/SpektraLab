import type { FilmParams } from './params';

/** Mac Session.frameSeed: SHA256's first four bytes, big endian, signed bit clear.
 * Native file URLs already arrive absolute; slash spelling is normalised so
 * dialogs and drag/drop identify the same Windows file consistently. */
export async function frameSeed(path: string): Promise<number> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(path.replaceAll('\\', '/')));
  return new DataView(digest).getUint32(0, false) & 0x7fffffff;
}

export async function seedFilmEdge(p: FilmParams, path: string, index: number, body: number): Promise<FilmParams> {
  if (p.filmEdge.seeded) return p;
  return { ...p, filmEdge: { ...p.filmEdge, cameraSeed: body, frameSeed: await frameSeed(path),
    frameNumber: index >= 0 ? index % 99 + 1 : p.filmEdge.frameNumber, seeded: true } };
}
