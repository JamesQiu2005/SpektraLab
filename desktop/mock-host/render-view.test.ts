import { describe, expect, it } from 'vitest';
import { MockHost } from './core';
import { ADJUSTMENTS_DEFAULT } from '../src/shared/adjustments';
import { GEOMETRY_DEFAULT } from '../src/shared/geometry';
import { newPair, newHole } from '../src/shared/pair';

const request = (host: MockHost, method: string, params: Record<string, unknown>, payload?: Uint8Array) =>
  host.handle({ id: 1, method, params, payload });
const result = (r: Awaited<ReturnType<typeof request>>) => r.header.result as Record<string, unknown>;

async function opened() {
  const host = new MockHost({ nativeWidth: 40, nativeHeight: 24 });
  const open = result(await request(host, 'open', { path: '/test/one.ARW' }));
  const p = { session: open.session, tier: 'full', generation: 7, display: 'srgb',
    adjustments: structuredClone(ADJUSTMENTS_DEFAULT), geometry: structuredClone(GEOMETRY_DEFAULT) };
  return { host, open, p };
}

describe('processed-view mock protocol', () => {
  it('advertises decoded-source bypass and keeps it independent of the dormant film crop/cache', async () => {
    const { host, open, p } = await opened();
    expect(result(await request(host, 'hello', {})).view_options).toContain('no_film');
    const crop = { ...p.geometry, crop: { x: 0.25, y: 0, width: 0.5, height: 1 }, quarterTurns: 1 };
    const film = await request(host, 'render_view', { ...p, source_geometry: crop });
    const bypass = await request(host, 'render_view', { ...p, no_film: true, geometry: crop });
    expect(bypass.header.ok).toBe(true);
    expect(result(bypass)).toMatchObject({ print_cached: false,
      image: { width: open.height, height: (open.width as number) / 2, source_width: open.width, source_height: open.height } });
    expect(bypass.payload).not.toEqual(film.payload);
    const restored = await request(host, 'render_view', p);
    expect(restored.payload).toEqual(film.payload);
    expect(result(restored).print_cached).toBe(true);
    const graded = await request(host, 'render_view', { ...p, no_film: true, geometry: crop,
      adjustments: { ...p.adjustments, exposure: 1 } });
    expect(graded.payload).not.toEqual(bypass.payload);
    await request(host, 'set_params', { session: p.session, delta: { film_stock: 'kodak_gold_200', exposure_compensation_ev: 2 } });
    expect((await request(host, 'render_view', { ...p, no_film: true, geometry: crop })).payload).toEqual(bypass.payload);
  });

  it('uses bypass for regular proof/export geometry but keeps DI on the film path', async () => {
    const { host, open, p } = await opened();
    const crop = { ...p.geometry, crop: { x: 0.25, y: 0, width: 0.5, height: 1 } };
    const proof = { ...p, proof_long_edge: 100, format: 'tiff16', source_geometry: crop, color_space: 'sRGB' };
    const bypass = await request(host, 'render_proof', { ...proof, no_film: true });
    expect(result(bypass)).toMatchObject({ file_width: open.width, file_height: open.height });
    expect(bypass.payload).toEqual((await request(host, 'render_view', { ...p, no_film: true })).payload);
    await request(host, 'render_proof', { ...proof, format: 'di' });
    expect((await request(host, 'render_proof', { ...proof, format: 'di', no_film: true })).header).toMatchObject({ ok: false, error: { code: 'bad_request' } });
    const exported = await request(host, 'export_frame', { ...proof, path: '/test/no-film.tif', no_film: true });
    expect(result(exported)).toMatchObject({ width: open.width, height: open.height, print_cached: false });
    expect((await request(host, 'export_cineon', { ...proof, path: '/test/film.cin', no_film: true })).header)
      .toMatchObject({ ok: false, error: { code: 'bad_request' } });
  });

  it('refuses malformed bypass flags, legacy hosts and pair bypass instead of returning film pixels', async () => {
    const { host, p } = await opened();
    for (const no_film of [null, 'true', 1]) {
      expect((await request(host, 'render_view', { ...p, no_film })).header).toMatchObject({ ok: false, error: { code: 'bad_request' } });
    }
    const old = new MockHost({ supportsNoFilm: false });
    expect(result(await request(old, 'hello', {})).view_options).not.toContain('no_film');
    const legacy = result(await request(old, 'open', { path: '/test/old.ARW' }));
    expect((await request(old, 'render_view', { ...p, session: legacy.session, no_film: true })).header)
      .toMatchObject({ ok: false, error: { code: 'unsupported' } });
    const pair = { ...newPair('/test'), left: newHole('/test/left.ARW'), right: newHole('/test/right.ARW') };
    const paired = result(await request(host, 'open_pair', { path: '/test/pair.spektrapair', pair }));
    for (const method of ['render_view', 'render_proof', 'export_frame']) {
      expect((await request(host, method, { ...p, session: paired.session, no_film: true, path: '/test/out.tif', format: 'tiff16', proof_long_edge: 100 })).header)
        .toMatchObject({ ok: false, error: { code: 'unsupported' } });
    }
  });
  it('advertises render_view and returns the same neutral sRGB print with an echoed generation', async () => {
    const { host, p } = await opened();
    expect(result(await request(host, 'hello', {})).methods).toContain('render_view');
    const legacy = await request(host, 'render', { session: p.session, tier: p.tier });
    const view = await request(host, 'render_view', p);
    expect(view.header.ok).toBe(true);
    expect(result(view)).toMatchObject({ generation: 7, print_cached: false, image: { color_space: 'sRGB', processed: true } });
    expect(view.payload).toEqual(legacy.payload);
  });

  it('reuses a print for grade and gamut changes but invalidates it after film edits', async () => {
    const { host, p } = await opened();
    const neutral = await request(host, 'render_view', p);
    const graded = await request(host, 'render_view', { ...p, adjustments: { ...p.adjustments, exposure: 1 } });
    expect(result(graded).print_cached).toBe(true);
    expect(graded.payload).not.toEqual(neutral.payload);
    const p3 = await request(host, 'render_view', { ...p, display: 'display-p3', generation: 8 });
    expect(result(p3)).toMatchObject({ generation: 8, print_cached: true, image: { color_space: 'Display P3' } });
    expect(p3.payload).not.toEqual(neutral.payload);
    await request(host, 'set_params', { session: p.session, delta: { exposure_compensation_ev: 1 } });
    expect(result(await request(host, 'render_view', p)).print_cached).toBe(false);
  });

  it('applies crop and rotation to returned pixels rather than just echoing geometry', async () => {
    const { host, open, p } = await opened();
    const geometry = { ...p.geometry, crop: { x: 0.25, y: 0, width: 0.5, height: 1 }, quarterTurns: 1 };
    const view = await request(host, 'render_view', { ...p, geometry });
    const expected = { width: open.height as number, height: (open.width as number) / 2 };
    expect(result(view).image).toMatchObject(expected);
    expect(view.payload?.byteLength).toBe(expected.width * expected.height * 4);
    const fit = await request(host, 'render_view', { ...p, geometry, long_edge: 12 });
    expect(result(fit).image).toMatchObject({ width: 12, height: 10 });
    expect(fit.payload?.byteLength).toBe(12 * 10 * 4);
    expect((await request(host, 'render_view', { ...p, display: 'prophoto' })).header).toMatchObject({ ok: false, error: { code: 'bad_request' } });
  });
  it('keeps source geometry before grading, invalidates cache and supports explicit identity reset', async () => {
    const { host, p } = await opened();
    const original = await request(host, 'render_view', p);
    const cut = { ...p.geometry, crop: { x: 0.25, y: 0, width: 0.5, height: 1 }, quarterTurns: 1 };
    const requestCut = { ...p, source_geometry: cut };
    const changed = await request(host, 'render_view', requestCut);
    expect(result(changed)).toMatchObject({ print_cached: false, image: { width: 24, height: 20, source_width: 24, source_height: 20 } });
    expect(result(await request(host, 'render_view', requestCut)).print_cached).toBe(true);
    const restored = await request(host, 'render_view', { ...p, source_geometry: GEOMETRY_DEFAULT });
    expect(restored.payload).toEqual(original.payload);
    expect(result(restored).print_cached).toBe(false);
  });

  it('exports an immutable snapshot as metadata only, with no image payload', async () => {
    const { host, open, p } = await opened();
    expect(result(await request(host, 'hello', {})).methods).toContain('export_frame');
    const snapshot = { session: p.session, path: '/test/result.png', format: 'png', color_space: 'display-p3', generation: 9,
      params: { film_stock: 'kodak_ektar_100', exposure_compensation_ev: 1.25 },
      adjustments: { ...p.adjustments, exposure: 0.5 }, geometry: { ...p.geometry, quarterTurns: 1 },
      decode: { raw_mode: 'compatible16' }, long_edge: 0, overwrite: false };
    const exported = await request(host, 'export_frame', snapshot);
    expect(exported.payload).toBeUndefined();
    expect(result(exported)).toMatchObject({ path: snapshot.path, width: open.height, height: open.width,
      generation: 9, color_space: 'display-p3', mock: true });
    expect(result(await request(host, 'get_params', { session: p.session })).params).toMatchObject(snapshot.params);
    expect((await request(host, 'export_frame', snapshot, new Uint8Array([1]))).header).toMatchObject({ ok: false, error: { code: 'bad_request' } });
  });

  it('can export an offline source without replacing or leaking an editor session', async () => {
    const { host, p } = await opened();
    const offline = await request(host, 'export_frame', { source_path: '/test/offline.NEF', path: '/test/offline.tif',
      format: 'tiff16', color_space: 'prophoto', geometry: p.geometry, adjustments: p.adjustments,
      params: { film_stock: 'kodak_ektar_100' }, long_edge: 16 });
    expect(offline.header.ok).toBe(true);
    expect(offline.payload).toBeUndefined();
    const out = result(offline);
    expect(Math.max(out.width as number, out.height as number)).toBe(16);
    expect((await request(host, 'get_params', { session: p.session })).header.ok).toBe(true);
    const next = result(await request(host, 'open', { path: '/test/next.ARW' }));
    expect(next.session).toBe('s2');
  });

  it('keeps a same-params print and isolates an export with a different decode snapshot', async () => {
    const { host, open, p } = await opened();
    await request(host, 'render_view', p);
    const unchanged = await request(host, 'export_frame', { session: p.session, path: '/test/unchanged.jpg',
      format: 'jpeg', params: open.params, decode: { raw_mode: 'compatible16' } });
    expect(result(unchanged).print_cached).toBe(true);
    const privateDecode = await request(host, 'export_frame', { session: p.session, path: '/test/custom.jpg',
      format: 'jpeg', params: { exposure_compensation_ev: 1 },
      decode: { white_balance: { mode: 'custom', temperature_k: 8000, tint: 30 } } });
    expect(result(privateDecode).print_cached).toBe(false);
    expect(result(await request(host, 'get_params', { session: p.session })).params).toEqual(open.params);
    expect(result(await request(host, 'render_view', p)).print_cached).toBe(true);
  });
});

describe("Don't Apply Film Simulation in the mock protocol (PROTOCOL-REQUESTS R4)", () => {
  it('answers render_source with the decode, and proofs the decode instead of the print under no_film', async () => {
    const { host, p } = await opened();
    const hello = result(await request(host, 'hello', {}));
    expect(hello.methods).toContain('render_source');
    expect(hello.frame_options).toEqual(['no-film']);
    const source = await request(host, 'render_source', { session: p.session, display: 'srgb', long_edge: 20, generation: 3 });
    expect(result(source)).toMatchObject({ generation: 3, source: 'decoded', image: { width: 20, height: 12 } });
    await request(host, 'set_params', { session: p.session, delta: { exposure_compensation_ev: 2 } });
    const proof = (noFilm?: boolean) => request(host, 'render_proof', { session: p.session, generation: 1, proof_long_edge: 40,
      display: 'srgb', format: 'jpeg', adjustments: p.adjustments, geometry: p.geometry, no_film: noFilm });
    const print = await proof(), decode = await proof(true);
    expect(decode.payload).not.toEqual(print.payload);
    expect((await request(host, 'render_proof', { session: p.session, generation: 1, proof_long_edge: 40, display: 'srgb',
      format: 'di', no_film: true })).header.ok).toBe(false);
    expect((await request(host, 'render_proof', { session: p.session, generation: 1, proof_long_edge: 40, display: 'srgb',
      format: 'jpeg', no_film: 'yes' })).header.ok).toBe(false);
  });
});
