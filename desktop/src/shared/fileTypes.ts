// Routing and picker extensions must agree with files.rs and native sniff_kind.
// An accepted RAW extension still requires a camera/compression supported by LibRaw.
export const RAW_EXTENSIONS = [
  '3fr', 'ari', 'arw', 'bay', 'cr2', 'cr3', 'crw', 'dcr', 'dng', 'erf', 'fff', 'gpr', 'iiq', 'k25', 'kdc', 'mef',
  'mos', 'mrw', 'nef', 'nrw', 'orf', 'pef', 'raf', 'raw', 'rw2', 'rwl', 'sr2', 'srf', 'srw', 'x3f',
] as const;
export const RASTER_EXTENSIONS = ['tif', 'tiff', 'jpg', 'jpeg', 'png', 'heic', 'heif', 'hif', 'exr'] as const;
export const PHOTO_PICKER_EXTENSIONS = [...RAW_EXTENSIONS, ...RASTER_EXTENSIONS].flatMap((ext) => [ext, ext.toUpperCase()]);
