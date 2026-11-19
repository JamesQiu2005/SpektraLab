import { describe, expect, it } from 'vitest';
import { SCENE_LAYER_DEFAULT, decodeSceneLayers, maskPlane, planeSize, sceneLayersRequest, sceneLayersStamp } from './sceneLayers';
import { FILM_PARAMS_DEFAULT, wire } from './params';

describe('local exposure layers', () => {
  it('a graduated mask at 0 degrees covers the top and fades by the bottom', () => {
    const p = maskPlane({ ...SCENE_LAYER_DEFAULT, y: 0.5, feather: 0.2 }, 64, 40);
    expect(p[0]).toBe(65535);
    expect(p[39 * 64]).toBe(0);
    const inv = maskPlane({ ...SCENE_LAYER_DEFAULT, y: 0.5, feather: 0.2, invert: true }, 64, 40);
    expect(inv[0]).toBe(0);
  });
  it('a radial mask is full at its centre and empty beyond its radius', () => {
    const p = maskPlane({ ...SCENE_LAYER_DEFAULT, kind: 'radial', x: 0.5, y: 0.5, radius: 0.25, feather: 0.5 }, 100, 100);
    expect(p[50 * 100 + 50]).toBe(65535);
    expect(p[0]).toBe(0);
  });
  it('no active layer: an empty stamp and nothing on the wire', () => {
    expect(sceneLayersStamp([])).toBe('');
    expect(sceneLayersStamp([{ ...SCENE_LAYER_DEFAULT, enabled: false }])).toBe('');
    expect(sceneLayersStamp([{ ...SCENE_LAYER_DEFAULT, exposure: 0 }])).toBe('');
    const f = wire(FILM_PARAMS_DEFAULT).find((x) => x.name === 'scene_layers');
    expect(f?.value).toBe('');
  });
  it('the stamp follows the settings and the request carries one plane per active layer', () => {
    const a = [{ ...SCENE_LAYER_DEFAULT }];
    const b = [{ ...SCENE_LAYER_DEFAULT, exposure: -0.5 }];
    expect(sceneLayersStamp(a)).not.toBe(sceneLayersStamp(b));
    const r = sceneLayersRequest([...a, { ...SCENE_LAYER_DEFAULT, warmth: 100, exposure: 0 }], 1.5);
    const { w, h } = planeSize(1.5);
    expect(r.layers).toHaveLength(2);
    expect(r.payload.byteLength).toBe(2 * w * h * 2);
    expect(r.layers[0]!.log_gain[1]).toBeCloseTo(-Math.LN2);
    expect(r.layers[1]!.log_gain[0]).toBeGreaterThan(0);
    expect(r.layers[1]!.log_gain[2]).toBeLessThan(0);
  });
  it('decodes safely', () => {
    expect(decodeSceneLayers('x')).toEqual([]);
    expect(decodeSceneLayers([{ exposure: 9, kind: 'nope' }])[0]).toMatchObject({ exposure: 3, kind: 'linear' });
  });
});
