// messages.ts — the host's own English texts, in the interface language.
//
// The host (engine/host: lens_correction.cpp, image_io.cpp, input_formats.cpp,
// main.cpp) explains a refusal in English: a lens profile that did not match,
// a RAW the decoder cannot transform, a file that is not there. The
// interface shows these texts as they are, so a 简体中文 window carried
// English sentences in its rails, dialogs and status line. This table holds
// the texts people meet; anything else passes through unchanged, so an
// unknown host message is never hidden.

import { isChinese } from '../i18n';

const EXACT: Record<string, string> = {
  // lens_correction.cpp
  'camera profile was not matched uniquely': '没有唯一匹配到相机配置文件',
  'lens profile was not matched uniquely': '没有唯一匹配到镜头配置文件',
  'camera, lens or focal-length metadata is missing': '缺少相机、镜头或焦距元数据',
  'image is too small for lens correction': '图像太小，无法进行镜头校正',
  'profile has no calibration at this focal length and aperture': '镜头配置文件在此焦距和光圈下没有校准数据',
  'lens database is not configured': '未配置镜头数据库',
  'bundled lens database cannot be loaded': '无法加载内置的镜头数据库',
  'camera colour matrix is singular; TCA correction is unavailable': '相机颜色矩阵不可逆，无法校正横向色差',
  'lens correction requires a three-colour RAW decode': '镜头校正需要三通道 RAW 解码',
  'lens profile returned an invalid automatic crop': '镜头配置文件返回了无效的自动裁切',
  // image_io.cpp
  'lens correction applies to RAW sources only': '镜头校正仅适用于 RAW 文件',
  'white balance at decode applies to RAW files only': '解码白平衡仅适用于 RAW 文件',
  'embedded_only thumbnails require a RAW file': '嵌入式缩略图需要 RAW 文件',
  'RAW thumbnail: no usable embedded preview': 'RAW 缩略图：没有可用的嵌入式预览',
  'RAW thumbnail: decode failed': 'RAW 缩略图：解码失败',
  'RAW compatible16: no supported three-channel camera-to-ProPhoto transform': 'RAW compatible16：没有可用的三通道相机到 ProPhoto 变换',
  'TIFF too large': 'TIFF 文件过大',
  // input_formats.cpp
  'HEIC invalid file size': 'HEIC 文件大小无效',
  'unsupported HEIC transfer function; HDR PQ/HLG input is not yet calibrated for this SDR workflow':
    '不支持的 HEIC 传递函数；HDR PQ/HLG 输入尚未针对此 SDR 工作流校准',
  // main.cpp
  'neutral picking requires a RAW source': '吸取中性灰需要 RAW 文件',
  'operation cancelled': '操作已取消',
  'cancelled before it started': '尚未开始就已取消',
};

/** Texts the host completes with a path or a detail; the detail is translated in turn. */
const PREFIX: readonly [string, string][] = [
  ['not found: ', '找不到文件：'],
  ['unrecognised file type: ', '无法识别的文件类型：'],
  ['destination exists: ', '目标文件已存在：'],
  ['cannot read half-frame pair: ', '无法读取半格拼接文件：'],
  ['the engine did not start: ', '引擎未能启动：'],
  ['lens correction: ', '镜头校正：'],
];

/** A host message in the interface language; unknown texts are returned as they are. */
export function hostMessage(text: string): string {
  if (!isChinese()) return text;
  const exact = EXACT[text];
  if (exact) return exact;
  for (const [english, chinese] of PREFIX) {
    if (text.startsWith(english)) return chinese + hostMessage(text.slice(english.length));
  }
  return text;
}
