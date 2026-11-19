import { describe, expect, it } from 'vitest';
import { ADJUSTMENTS_DEFAULT, HSL_DEFAULT, MIXER_DEFAULT, decodeAdjustments, isNeutral, layer2Tone, layer2Uniforms } from './adjustments';

const px = (r: number, g: number, b: number): [number, number, number] => [r, g, b];
const tone = (a: object, c: [number, number, number]) => layer2Tone(c, layer2Uniforms({ ...ADJUSTMENTS_DEFAULT, ...a }));
const close = (a: number[], b: number[], d = 1e-6) => a.forEach((v, i) => expect(v).toBeCloseTo(b[i]!, -Math.log10(d)));

describe('vibrance, HSL and the channel mixer (SpektraLab 2 Layer2Kernel.swift)', () => {
  const samples = [px(0.8, 0.3, 0.2), px(0.2, 0.6, 0.3), px(0.4, 0.4, 0.4), px(0.1, 0.2, 0.9)];
  it('leave every pixel alone at zero', () => {
    for (const c of samples) close(tone({}, c), tone({ vibrance: 0, hsl: HSL_DEFAULT, channelMixer: MIXER_DEFAULT }, c));
    expect(isNeutral(ADJUSTMENTS_DEFAULT)).toBe(true);
    expect(isNeutral({ ...ADJUSTMENTS_DEFAULT, vibrance: 10 })).toBe(false);
  });
  it('vibrance lifts a dull colour more than a vivid one, and leaves grey', () => {
    const dull = px(0.5, 0.45, 0.42), vivid = px(0.9, 0.1, 0.1), grey = px(0.4, 0.4, 0.4);
    const spread = (c: number[]) => Math.max(...c) - Math.min(...c);
    const gain = (c: [number, number, number]) => spread(tone({ vibrance: 50 }, c)) / spread(tone({}, c));
    expect(gain(dull)).toBeGreaterThan(gain(vivid));
    close(tone({ vibrance: 50 }, grey), tone({}, grey));
  });
  it('HSL moves the colour picked and not its opposite, and never a grey', () => {
    const red = px(0.8, 0.2, 0.2), cyan = px(0.2, 0.7, 0.7), grey = px(0.5, 0.5, 0.5);
    const hsl = { ...HSL_DEFAULT, red: { hue: 0, saturation: -100, luminance: 0 } };
    const r = tone({ hsl }, red);
    expect(Math.max(...r) - Math.min(...r)).toBeLessThan(1e-6);   // fully desaturated
    close(tone({ hsl }, cyan), tone({}, cyan));
    close(tone({ hsl }, grey), tone({}, grey));
    const turned = tone({ hsl: { ...HSL_DEFAULT, red: { hue: 100, saturation: 0, luminance: 0 } } }, red);
    expect(turned[1]).toBeGreaterThan(turned[2]);   // +hue turns red towards orange (green over blue)
  });
  it('the mixer adds the offsets to the identity', () => {
    const c = px(0.6, 0.3, 0.1);
    const out = tone({ channelMixer: { ...MIXER_DEFAULT, red: { red: 0, green: 50, blue: 0 } } }, c);
    const base = tone({}, c);
    expect(out[0]).toBeGreaterThan(base[0]);
    close([out[1], out[2]], [base[1], base[2]], 1e-3);
  });
  it('reads SpektraLab 2 sidecars, clamped', () => {
    const a = decodeAdjustments({ vibrance: 250, hsl: { aqua: { hue: -40 } }, channelMixer: { blue: { red: 12 } } });
    expect(a.vibrance).toBe(100);
    expect(a.hsl.aqua).toEqual({ hue: -40, saturation: 0, luminance: 0 });
    expect(a.channelMixer.blue).toEqual({ red: 12, green: 0, blue: 0 });
    expect(decodeAdjustments({}).hsl).toEqual(HSL_DEFAULT);
  });
});
