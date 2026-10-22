/** App-wide switches that affect pixels, shared by GUI and local agents. */
export interface RenderPreferences {
  recalculateEffectsAfterCrop: boolean;
  diBlueCompensation: boolean;
}
export const RENDER_PREFERENCES_DEFAULT: RenderPreferences = {
  recalculateEffectsAfterCrop: false,
  diBlueCompensation: false,
};
export function renderPreferences(value: unknown): RenderPreferences {
  if (!value || typeof value !== 'object') throw new Error('Invalid saved rendering preferences');
  const v = value as Record<string, unknown>;
  if (typeof v.recalculateEffectsAfterCrop !== 'boolean' || typeof v.diBlueCompensation !== 'boolean')
    throw new Error('Invalid saved rendering preferences');
  return { recalculateEffectsAfterCrop: v.recalculateEffectsAfterCrop, diBlueCompensation: v.diBlueCompensation };
}
