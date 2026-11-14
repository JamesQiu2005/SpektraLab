/** A scalar exposure estimate, not a replacement for the camera's tone curve.
 * Inputs must both be display-ready sRGB, before any film or user adjustment.
 * Quantiles tolerate small differences between the RAW and embedded crop.
 * Never guess from an empty, clipped, or differently shaped preview. */
export interface CameraExposureImage {
  width: number;
  height: number;
  data: Uint8Array;
}

const linear = Array.from({ length: 256 }, (_, code) => {
  const v = code / 255;
  return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4;
});

function luminances(image: CameraExposureImage): number[] | null {
  const { width, height, data } = image;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 8 || height < 8
    || data.length !== width * height * 4) return null;
  const values: number[] = [];
  const step = Math.max(1, Math.ceil(width * height / 100_000));
  for (let pixel = 0; pixel < width * height; pixel += step) {
    const i = pixel * 4;
    if (data[i + 3] !== 255) return null;
    values.push(.2126 * linear[data[i]!]! + .7152 * linear[data[i + 1]!]! + .0722 * linear[data[i + 2]!]!);
  }
  return values.sort((a, b) => a - b);
}

/** Positive EV brightens the linear source BEFORE scene placement and film.
 * Exclude tails: lifting a camera's black floor or fitting its clipped whites
 * would turn a display tone curve into an unjustified exposure correction.
 * null means no reliable reference; callers must retain the existing edit. */
export function cameraExposureEV(source: CameraExposureImage, camera: CameraExposureImage): number | null {
  const a = luminances(source), b = luminances(camera);
  if (!a || !b || Math.abs(Math.log((source.width / source.height) / (camera.width / camera.height))) > .025) return null;
  const estimates: number[] = [];
  for (let i = 0; i <= 24; i++) {
    const q = .2 + i * .025;
    const x = a[Math.floor(q * (a.length - 1))]!, y = b[Math.floor(q * (b.length - 1))]!;
    if (x > .005 && x < .7 && y > .02 && y < .7) estimates.push(Math.log2(y / x));
  }
  if (estimates.length < 8) return null;
  estimates.sort((a, b) => a - b);
  const ev = estimates[Math.floor(estimates.length / 2)]!;
  const spread = estimates[Math.floor(.8 * (estimates.length - 1))]! - estimates[Math.floor(.2 * (estimates.length - 1))]!;
  return Number.isFinite(ev) && Math.abs(ev) <= 6 && spread <= 2 ? ev : null;
}
