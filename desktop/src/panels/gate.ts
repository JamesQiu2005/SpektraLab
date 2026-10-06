// gate.ts — why a section is greyed: the host said it cannot do the feature
// (`capabilities.backend.unsupported_features`). Owner's decision for this
// version: the controls are present and disabled, so turning a feature on
// later is wiring, not design.

import { tz } from '../i18n';

const NAMES: Record<string, [string, string]> = {
  digital_intermediate: ['The Digital Intermediate', '数字中间片'],
  scene_latitude_mapping: ['Scene Placement', '场景定位'],
  contrast_mask: ['The Tone Mask', '影调蒙版'],
  overscan: ['Film Edge', '片边'],
  date_imprint: ['Date Back', '日期背'],
};

export function unsupportedReason(feature: string, supported: boolean): string | null {
  if (supported) return null;
  const [en, zh] = NAMES[feature] ?? [feature, feature];
  return tz(
    `${en} is not available with this engine yet (the Linux/Windows engine does not port it in this version).`,
    `此引擎暂不支持${zh}（Linux/Windows 引擎在此版本中尚未移植）。`,
  );
}
