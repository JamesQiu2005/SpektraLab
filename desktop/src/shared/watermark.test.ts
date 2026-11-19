import { describe, expect, it } from 'vitest';
import { WATERMARK_DEFAULT, decodeWatermark, watermarkShows } from './watermark';
import { ADJUSTMENTS_DEFAULT, decodeAdjustments, isNeutral } from './adjustments';

describe('the watermark', () => {
  it('shows only when on and with text', () => {
    expect(watermarkShows(WATERMARK_DEFAULT)).toBe(false);
    expect(watermarkShows({ ...WATERMARK_DEFAULT, enabled: true })).toBe(false);
    expect(watermarkShows({ ...WATERMARK_DEFAULT, enabled: true, text: '© J' })).toBe(true);
    expect(isNeutral({ ...ADJUSTMENTS_DEFAULT, watermark: { ...WATERMARK_DEFAULT, enabled: true, text: '© J' } })).toBe(false);
  });
  it('reads a sidecar tolerantly', () => {
    const w = decodeWatermark({ enabled: true, text: 'x', size: 99, position: 'nowhere', font: 'script', opacity: -1 });
    expect(w).toMatchObject({ enabled: true, text: 'x', size: 15, position: 'br', font: 'script', opacity: 0 });
    expect(decodeAdjustments({}).watermark).toEqual(WATERMARK_DEFAULT);
  });
});
