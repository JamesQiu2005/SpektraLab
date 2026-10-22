import { clamp } from '@shared/params';

export const ZOOM_STEPS = [0.05, 0.0625, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 2, 3, 4, 8, 16];
export const MAX_ZOOM = 16;

// Fit is a separate command, not a manual-zoom floor. Even a very large
// image in a small window can shrink below fit without becoming invisible.
export function minimumZoom(fitZoom: number): number {
  return Math.min(0.05, fitZoom > 0 ? fitZoom / 2 : 0.05);
}

export function clampZoom(zoom: number, fitZoom: number): number {
  return clamp(zoom, minimumZoom(fitZoom), MAX_ZOOM);
}

export function steppedZoom(current: number, direction: 1 | -1, fitZoom: number): number {
  const next = direction > 0
    ? ZOOM_STEPS.find((z) => z > current * 1.001) ?? MAX_ZOOM
    : [...ZOOM_STEPS].reverse().find((z) => z < current * 0.999) ?? minimumZoom(fitZoom);
  return clampZoom(next, fitZoom);
}
