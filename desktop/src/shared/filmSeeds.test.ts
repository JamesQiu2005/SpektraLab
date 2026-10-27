import { expect, it } from 'vitest';
import { FILM_PARAMS_DEFAULT } from './params';
import { frameSeed, seedFilmEdge } from './filmSeeds';
import { decodeSidecar, encodeSidecar, newSidecar } from './sidecar';
import { createSettingsStore, filmEdgeBodySeed } from '../state/settings';

it('matches the Mac SHA256 first-four-byte seed, including Unicode paths', async () => {
  expect(await frameSeed('C:/Dev/roll/one.ARW')).toBe(177441561);
  expect(await frameSeed('C:/Dev/roll/two.ARW')).toBe(567939501);
  expect(await frameSeed('C:/照片/一.ARW')).toBe(1072973183);
  expect(await frameSeed('C:\\Dev\\roll\\one.ARW')).toBe(await frameSeed('C:/Dev/roll/one.ARW'));
});

it('persists the body in an injected profile and recovers invalid saved values', async () => {
  const values = new Map<string, string>();
  const storage = { getItem: (k: string) => values.get(k) ?? null, setItem: (k: string, v: string) => { values.set(k,v); } };
  const store = createSettingsStore(storage);
  const body = filmEdgeBodySeed(store);
  expect(body).toBeGreaterThanOrEqual(1); expect(body).toBeLessThanOrEqual(999);
  await Promise.resolve();
  expect(filmEdgeBodySeed(createSettingsStore(storage))).toBe(body);
  store.getState().set('filmEdgeBodySeed', 123456);
  expect(filmEdgeBodySeed(store)).toBe(123456);
  store.getState().set('filmEdgeBodySeed', NaN);
  expect(filmEdgeBodySeed(store)).toBeGreaterThan(0);
});

it('assigns a shared body and independent frames, numbers the roll and preserves saved edits on reopen', async () => {
  const first = await seedFilmEdge(FILM_PARAMS_DEFAULT, 'C:/Dev/roll/one.ARW', 0, 417);
  const second = await seedFilmEdge(FILM_PARAMS_DEFAULT, 'C:/Dev/roll/two.ARW', 100, 417);
  expect(first.filmEdge).toMatchObject({ cameraSeed: 417, frameNumber: 1, seeded: true });
  expect(second.filmEdge).toMatchObject({ cameraSeed: 417, frameNumber: 2, seeded: true });
  expect(first.filmEdge.frameSeed).not.toBe(second.filmEdge.frameSeed);
  const edited = { ...first, filmEdge: { ...first.filmEdge, cameraSeed: 777, frameNumber: 50 } };
  const reopened = decodeSidecar(encodeSidecar({ ...newSidecar(), params: edited })).params;
  expect(await seedFilmEdge(reopened, 'D:/moved.ARW', 5, 999)).toBe(reopened);
  expect(FILM_PARAMS_DEFAULT.filmEdge.seeded).toBe(false);
});
