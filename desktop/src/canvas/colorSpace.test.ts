import { afterEach, describe, expect, it, vi } from 'vitest';
import { imageData, p3ToSrgb, paintOutput, previewSpace, resolveDisplaySpace } from './colorSpace';
import { createSettingsStore, loadSettings } from '../state/settings';

afterEach(() => vi.unstubAllGlobals());

function mockImageData(p3: 'supported' | 'ignored' | 'rejected') {
  vi.stubGlobal('ImageData', class {
    colorSpace: PredefinedColorSpace;
    constructor(public data: Uint8ClampedArray, public width: number, public height: number, settings?: ImageDataSettings) {
      if (p3 === 'rejected' && settings?.colorSpace === 'display-p3') throw new TypeError('unsupported gamut');
      this.colorSpace = p3 === 'supported' ? settings?.colorSpace ?? 'srgb' : 'srgb';
    }
  });
}

const colour = { width: 1, height: 1, colorSpace: 'Display P3', data: new Uint8Array([180, 120, 80, 192]) };

describe('preview gamut', () => {
  it('automatic requires both P3 API support and a wide-gamut screen', () => {
    expect(resolveDisplaySpace('auto', true, true)).toBe('display-p3');
    expect(resolveDisplaySpace('auto', true, false)).toBe('srgb');
    expect(resolveDisplaySpace('auto', false, true)).toBe('srgb');
    expect(resolveDisplaySpace('display-p3', true, false)).toBe('display-p3');
    expect(resolveDisplaySpace('display-p3', false, true)).toBe('srgb');
    expect(resolveDisplaySpace('srgb', true, true)).toBe('srgb');
  });

  it('normalises host tags and refuses to label ProPhoto as a display encoding', () => {
    expect(previewSpace('Display P3')).toBe('display-p3');
    expect(previewSpace('sRGB')).toBe('srgb');
    expect(previewSpace()).toBe('srgb');
    expect(() => previewSpace('ProPhoto RGB')).toThrow('Unsupported preview');
  });

  it('converts encoded P3 colours, preserves neutral colours and alpha', () => {
    // CSS Color 4 D65 matrices: P3(180,120,80) becomes sRGB(190,117,72).
    const px = new Uint8Array([180, 120, 80, 192, 128, 128, 128, 13, 255, 128, 0, 255, 0, 0, 0, 0]);
    expect(Array.from(p3ToSrgb(px))).toEqual([190, 117, 72, 192, 128, 128, 128, 13, 255, 119, 0, 255, 0, 0, 0, 0]);
    expect(Array.from(px.slice(0, 4))).toEqual([180, 120, 80, 192]);
  });

  it('tags supported P3 bytes without a second colour transform', () => {
    mockImageData('supported');
    const pixels = imageData(colour);
    expect(pixels.colorSpace).toBe('display-p3');
    expect(Array.from(pixels.data)).toEqual([180, 120, 80, 192]);
    pixels.data[0] = 0;
    expect(colour.data[0]).toBe(180);
  });

  it.each(['ignored', 'rejected'] as const)('numerically converts when P3 settings are %s', (support) => {
    mockImageData(support);
    const pixels = imageData(colour);
    expect(pixels.colorSpace).toBe('srgb');
    expect(Array.from(pixels.data)).toEqual([190, 117, 72, 192]);
  });

  it('draws tagged pixels into a matching 2D context', () => {
    mockImageData('supported');
    const putImageData = vi.fn();
    const getContext = vi.fn(() => ({ putImageData }));
    const canvas = { width: 0, height: 0, getContext };
    expect(paintOutput(canvas as unknown as HTMLCanvasElement, colour)).toBe(true);
    expect(getContext).toHaveBeenCalledWith('2d', { colorSpace: 'display-p3' });
    expect(putImageData.mock.calls[0]![0].colorSpace).toBe('display-p3');
    expect([canvas.width, canvas.height]).toEqual([1, 1]);
  });

  it('uses converted sRGB bytes when only legacy 2D canvas is available', () => {
    mockImageData('rejected');
    const putImageData = vi.fn();
    const getContext = vi.fn().mockImplementationOnce(() => { throw new TypeError('legacy canvas'); })
      .mockReturnValue({ putImageData });
    expect(paintOutput({ getContext } as unknown as HTMLCanvasElement, colour)).toBe(true);
    expect(getContext).toHaveBeenLastCalledWith('2d');
    expect(Array.from(putImageData.mock.calls[0]![0].data as Uint8ClampedArray)).toEqual([190, 117, 72, 192]);
  });

  it('upgrades existing preferences to auto and persists explicit choices', async () => {
    let stored = '{"language":"en","previewLongEdge":1920}';
    const storage = { getItem: () => stored, setItem: (_key: string, value: string) => { stored = value; } };
    const settings = createSettingsStore(storage);
    expect(settings.getState().previewGamut).toBe('auto');
    settings.getState().set('previewGamut', 'display-p3');
    await Promise.resolve();
    expect(loadSettings(storage).previewGamut).toBe('display-p3');
    expect(loadSettings({ getItem: () => '{"previewGamut":"prophoto"}' }).previewGamut).toBe('auto');
  });
});
