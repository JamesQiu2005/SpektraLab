import { PillMenu } from '../controls/controls';
import { tz } from '../i18n';
import { useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { NEW_PHOTO_DEFAULTS, newPhotoStocks } from '@shared/newPhotoDefaults';

export function NewPhotoDefaultsSettings() {
  const catalog = useSession((s) => s.catalog);
  const film = useSettings((s) => s.newPhotoFilmStock);
  const paper = useSettings((s) => s.newPhotoPrintStock);
  const stocks = newPhotoStocks(catalog, { newPhotoFilmStock: film, newPhotoPrintStock: paper });
  const positive = catalog.isPositive(stocks.filmStock);
  const set = settingsStore.getState().set;
  const ready = catalog.films.length > 0;
  return <div className="settings-group" data-testid="new-photo-defaults">
    <h3>{tz('New photographs', '新照片')}</h3>
    <PillMenu label={tz('Default film', '默认胶片')} value={stocks.filmStock} disabled={!ready} testId="new-photo-film" scrollable
      options={catalog.filmGroups().flatMap((g) => g.films.map((s) => ({ value: s.id, label: s.name,
        group: g.title === 'Positive' ? tz('Positive', '反转片') : g.title === 'Negative' ? tz('Negative', '负片') : tz('Black & White', '黑白') })))}
      onChange={(value) => {
        const next = newPhotoStocks(catalog, { newPhotoFilmStock: value, newPhotoPrintStock: stocks.printStock });
        // Change preferences only. Applying these to the active sidecar
        // would replace the open photograph's own stock choices.
        set('newPhotoFilmStock', next.filmStock);
        set('newPhotoPrintStock', next.printStock);
      }} />
    <PillMenu label={tz('Default paper', '默认相纸')} value={stocks.printStock} disabled={!ready || positive} testId="new-photo-paper" scrollable
      display={positive ? tz('Direct scan (no paper)', '直接扫描（不使用相纸）') : undefined}
      reason={tz('Reversal films are scanned directly without a paper stage.', '反转片直接扫描，不经过相纸印相。')}
      options={catalog.papers.filter((s) => catalog.canPrint(stocks.filmStock, s.id)).map((s) => ({ value: s.id, label: s.name }))}
      onChange={(value) => set('newPhotoPrintStock', value)} />
    <p className="caption">{tz('Used when a photograph has no saved edits, including unedited photographs in a batch export. The current photograph and existing edits keep their settings.',
      '用于没有保存过编辑的新照片，也适用于批量导出中尚未编辑的照片。当前照片和已有编辑保留原设置。')}</p>
    <p className="caption">{tz('Black-and-white films use compatible black-and-white paper. Reversal films are scanned directly.', '黑白胶片使用兼容的黑白相纸；反转片直接扫描。')}</p>
    <button className="btn" disabled={!ready} onClick={() => {
      set('newPhotoFilmStock', NEW_PHOTO_DEFAULTS.newPhotoFilmStock);
      set('newPhotoPrintStock', NEW_PHOTO_DEFAULTS.newPhotoPrintStock);
    }}>{tz('Restore stock defaults', '恢复默认胶片和相纸')}</button>
  </div>;
}
