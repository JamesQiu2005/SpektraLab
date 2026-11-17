// The status line's words (README §7), one per state, and the fit without "…".

import { describe, expect, it } from 'vitest';
import { cardName, fitParts, statusParts, canvasWhat, type StatusInput } from './words';
import { StockCatalog } from '@shared/stocks';
import { FILM_PARAMS_DEFAULT } from '@shared/params';
import type { JobSnapshot } from '../scheduler/types';
import { ADJUST_TILES } from './rails';

const catalog = new StockCatalog([
  { id: 'kodak_portra_400', name: 'Kodak Portra 400', stage: 'filming', use: 'still', hasPreviewLUT: false },
  { id: 'kodak_gold_200', name: 'Kodak Gold 200', stage: 'filming', use: 'still', hasPreviewLUT: false },
  { id: 'kodak_portra_endura', name: 'Kodak Portra Endura', stage: 'printing', use: 'still', hasPreviewLUT: false },
]);
const params = { ...FILM_PARAMS_DEFAULT, printStock: 'kodak_portra_endura' };
const base: StatusInput = { engine: 'ready', hasFrame: true, frameName: 'DSC', catalog, params, noFilm: false, edited: [], job: null,
  elapsedMs: 0, printed: true, exporting: null, crop: null, notice: null };
const job = (kind: JobSnapshot['job']['kind'], state: JobSnapshot['state'], what = 'Gold 200'): JobSnapshot =>
  ({ id: 'j1', job: { kind, frameId: '/a', what, tier: 'live', submitted: 0 }, state });

describe('the status line', () => {
  it('developed, edited, developing (with the elapsed time past a second), printing', () => {
    expect(statusParts(base).parts).toEqual(['Developed', 'Portra 400', 'Portra Endura']);
    expect(statusParts({ ...base, edited: ['Tone', 'Curve'] }).parts).toEqual(['Edited', 'Tone', 'Curve']);
    expect(statusParts({ ...base, job: job('canvasDevelop', { state: 'waiting', reason: 'settling' }) }).parts).toEqual(['Developing', 'Gold 200']);
    expect(statusParts({ ...base, elapsedMs: 1400, job: job('canvasDevelop', { state: 'running', stage: null, fraction: null, step: 1, steps: 2 }) }).parts)
      .toEqual(['Developing', 'Gold 200', '1.4 s']);
    expect(statusParts({ ...base, elapsedMs: 900, job: job('canvasDevelop', { state: 'running', stage: null, fraction: null, step: 1, steps: 2 }) }).parts)
      .toEqual(['Developing', 'Gold 200']);
    expect(statusParts({ ...base, job: job('canvasReprint', { state: 'queued' }, 'Yellow +0.10') }).parts).toEqual(['Printing', 'Yellow +0.10']);
  });
  it('a waiting job says why; a superseded one says nothing of its own', () => {
    expect(statusParts({ ...base, job: job('canvasDevelop', { state: 'waiting', reason: 'dialog' }) }).parts).toEqual(['Developing', 'Gold 200', 'Waiting for the dialog']);
    expect(statusParts({ ...base, job: { ...job('canvasDevelop', { state: 'running', stage: null, fraction: null, step: 0, steps: 1 }), superseded: true } }).parts[0]).toBe('Developed');
  });
  it('the engine, exporting, crop', () => {
    expect(statusParts({ ...base, engine: 'stopped' })).toEqual({ parts: ['Engine stopped'], tone: 'danger' });
    expect(statusParts({ ...base, engine: 'starting' }).parts).toEqual(['Starting the engine']);
    expect(statusParts({ ...base, exporting: { done: 2, total: 12, format: 'JPEG', colour: 'sRGB', file: 'a' } }).parts).toEqual(['Exporting 3 of 12', 'JPEG', 'sRGB']);
    expect(statusParts({ ...base, exporting: { done: 0, total: 1, format: 'JPEG', colour: 'sRGB', file: '_DSC0061' } }).parts).toEqual(['Exporting _DSC0061']);
    expect(statusParts({ ...base, crop: { ratio: '5:4', angle: 2.4 } }).parts).toEqual(['Crop', '5:4', '+2.4°']);
  });
  it('a print-side job names the moved control; a film-side one the film', () => {
    expect(canvasWhat(catalog, { ...params, yFilterShift: 0.1 }, { y_filter_shift: 0.1 }, true)).toBe('Yellow +0.10');
    expect(canvasWhat(catalog, { ...params, filmStock: 'kodak_gold_200' }, { film_stock: 'x' }, false)).toBe('Gold 200');
  });
  it('fits by dropping whole trailing parts, never "…"', () => {
    const m = (s: string) => s.length * 7;
    const parts = ['Edited', 'Tone', 'Curve', 'Enlarger'];
    expect(fitParts(parts, 1000, m)).toBe('Edited  ·  Tone  ·  Curve  ·  Enlarger');
    expect(fitParts(parts, 140, m)).toBe('Edited  ·  Tone');
    expect(fitParts(parts, 10, m)).toBe('Edited');
    expect(fitParts(parts, 140, m)).not.toContain('…');
  });
});

describe('the Adjust tiles', () => {
  it('ships only what the v1 Layer 2 can do (R7)', () => {
    expect(ADJUST_TILES.filter((t) => !t.built).map((t) => t.id)).toEqual(['hsl', 'channels', 'vibrance']);
    expect(ADJUST_TILES.filter((t) => t.built)).toHaveLength(8);
  });
});

describe("a stock card's name (PC-E1: two lines of a 92 epx card)", () => {
  const cards = new StockCatalog([
    { id: 'kodak_vision_premier_2393', name: 'Kodak Vision Premier 2393', stage: 'printing', use: 'cine', hasPreviewLUT: false },
    { id: 'kodak_vision_2383', name: 'Kodak Vision 2383', stage: 'printing', use: 'cine', hasPreviewLUT: false },
    { id: 'fujifilm_crystal_archive_typeii', name: 'Fujifilm Crystal Archive Type II', stage: 'printing', use: 'still', hasPreviewLUT: false },
    { id: 'kodak_endura_premier', name: 'Kodak Professional Endura Premier', stage: 'printing', use: 'still', hasPreviewLUT: false },
    { id: 'kodak_vision3_500t', name: 'Kodak Vision3 500T', stage: 'filming', use: 'cine', hasPreviewLUT: false },
  ]);
  it('drops the maker and the words a card does not need, and keeps a name that is the name', () => {
    expect(cardName(cards, 'kodak_vision_premier_2393')).toBe('Premier 2393');
    expect(cardName(cards, 'kodak_vision_2383')).toBe('Vision 2383');
    expect(cardName(cards, 'fujifilm_crystal_archive_typeii')).toBe('Crystal Archive II');
    expect(cardName(cards, 'kodak_endura_premier')).toBe('Endura Premier');
    expect(cardName(cards, 'kodak_vision3_500t')).toBe('Vision3 500T');
  });
});
