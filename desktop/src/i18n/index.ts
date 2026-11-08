// i18n — English and 简体中文, from the macOS string table.
//
// `en.json` / `zh-Hans.json` are generated from `Localization/Strings.swift`
// by `npm run gen:strings`. `t(key)` is the table; `tz(en, zh)` is the Mac
// app's `L(_:zh:)` — a string kept at its point of use, both languages side
// by side. Names (films, papers, cameras, formats, units, CINE/RAW/EV…) stay
// English, as the Mac's localisation spec says.

import i18next from 'i18next';
import { initReactI18next, useTranslation } from 'react-i18next';
import en from './en.json';
import zh from './zh-Hans.json';

export type StringKey = keyof typeof en;
export type LanguageSetting = 'system' | 'english' | 'simplifiedChinese';

export function resolveLanguage(setting: LanguageSetting, navigatorLanguages: readonly string[]): 'en' | 'zh-Hans' {
  if (setting === 'english') return 'en';
  if (setting === 'simplifiedChinese') return 'zh-Hans';
  return navigatorLanguages.some((l) => /^zh(-|_)?(hans|cn|sg)?/i.test(l) && !/hant|tw|hk|mo/i.test(l)) ? 'zh-Hans' : 'en';
}

void i18next.use(initReactI18next).init({
  resources: { en: { translation: en }, 'zh-Hans': { translation: zh } },
  lng: 'en',
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
  returnEmptyString: false,
  keySeparator: false,
  nsSeparator: false,
});

export function setLanguage(setting: LanguageSetting) {
  const lng = resolveLanguage(setting, typeof navigator !== 'undefined' ? navigator.languages ?? [navigator.language] : []);
  if (i18next.language !== lng) void i18next.changeLanguage(lng);
  document.documentElement.lang = lng;
}

export const t = (key: StringKey): string => i18next.t(key);
export const tz = (english: string, chinese: string): string =>
  i18next.language === 'zh-Hans' && chinese ? chinese : english;
export const isChinese = () => i18next.language === 'zh-Hans';

/** Re-render on a language change; returns the two lookups. */
export function useI18n() {
  const { i18n } = useTranslation();
  return { t, tz, lang: i18n.language };
}

export default i18next;
