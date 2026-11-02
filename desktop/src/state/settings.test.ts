import { expect, it } from 'vitest';
import { createSettingsStore, loadSettings, SETTINGS_DEFAULT } from './settings';

it('migrates older settings without changing their existing preferences', () => {
  const loaded = loadSettings({ getItem: () => JSON.stringify({ language: 'simplifiedChinese', previewLongEdge: 1920 }) });
  expect(loaded).toMatchObject({ language: 'simplifiedChinese', previewLongEdge: 1920,
    newPhotoFilmStock: SETTINGS_DEFAULT.newPhotoFilmStock, newPhotoPrintStock: SETTINGS_DEFAULT.newPhotoPrintStock });
  expect(loadSettings({ getItem: () => '{"newPhotoFilmStock":null,"newPhotoPrintStock":42}' })).toMatchObject({
    newPhotoFilmStock: SETTINGS_DEFAULT.newPhotoFilmStock, newPhotoPrintStock: SETTINGS_DEFAULT.newPhotoPrintStock,
  });
});

it('persists and reloads a preferred stock pair using an isolated settings store', async () => {
  const documents = new Map<string, string>();
  const storage = { getItem: (key: string) => documents.get(key) ?? null, setItem: (key: string, value: string) => { documents.set(key, value); } };
  const store = createSettingsStore(storage);
  store.getState().set('newPhotoFilmStock', 'kodak_gold_200');
  store.getState().set('newPhotoPrintStock', 'kodak_2383');
  await Promise.resolve();
  expect(createSettingsStore(storage).getState()).toMatchObject({ newPhotoFilmStock: 'kodak_gold_200', newPhotoPrintStock: 'kodak_2383' });
});
