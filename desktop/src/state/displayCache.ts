// Persist display pictures only. Cached pixels never replace an engine source,
// neutral-picker sample or export render. Native key generation stats sources
// and fingerprints the actual engine/resources; no mutable version label.
import { invoke } from '@tauri-apps/api/core';
import { inTauri } from '../host/transport';
import type { RgbaImage } from '../host/client';
import { decodeFrame, encodeFrame } from '@shared/framing';

export interface DisplayCacheDescriptor {
  kind: 'print' | 'original';
  sources: string[];
  configuration: unknown;
}
export interface DisplayCacheStatus {
  cap_bytes: number; bytes: number; entries: number; max_entry_bytes: number; path: string;
}
export interface DisplayCacheOptions {
  /** Background whole-folder previews must not evict recently viewed frames. */
  retain?: boolean;
}

const MAX_IMAGE_BYTES = 64 * 1024 * 1024;
const DEFAULT_MEMORY_BYTES = 128 * 1024 * 1024;
let memoryCap = DEFAULT_MEMORY_BYTES;
let memoryBytes = 0;
let memoryGeneration = 0;
const recent = new Map<string, { image: RgbaImage; bytes: number }>();
const reading = new Map<string, Promise<RgbaImage | null>>();
type Writeback = { key: string; image: RgbaImage; done: (stored: boolean) => void };
let pendingWrite: Writeback | null = null;
let writer: Promise<void> | null = null;
let clearing: Promise<void> | null = null;

const validKey = (key: string | null): key is string => !!key && /^[0-9a-f]{64}$/i.test(key);
function validImage(image: RgbaImage): boolean {
  const bpp = image?.format === 'rgba16' ? 8 : image?.format === 'rgba8' ? 4 : 0;
  return !!bpp && image.data instanceof Uint8Array
    && Number.isInteger(image.width) && image.width > 0 && image.width <= 16384
    && Number.isInteger(image.height) && image.height > 0 && image.height <= 16384
    && image.width * image.height * bpp === image.data.byteLength && image.data.byteLength <= MAX_IMAGE_BYTES
    && (image.colorSpace === 'sRGB' || image.colorSpace === 'Display P3');
}
function trimMemory() {
  for (const [key, entry] of recent) {
    if (memoryBytes <= memoryCap) break;
    recent.delete(key); memoryBytes -= entry.bytes;
  }
}
function remember(key: string, image: RgbaImage) {
  // A small subarray can retain a much larger transport buffer. Charge the
  // actual retained allocation, including its framing bytes, not just pixels.
  const bytes = image.data.buffer.byteLength;
  if (bytes > memoryCap || memoryCap === 0) return;
  const previous = recent.get(key);
  if (previous) { recent.delete(key); memoryBytes -= previous.bytes; }
  recent.set(key, { image, bytes }); memoryBytes += bytes;
  trimMemory();
}

/** Display buffers are immutable after publication; no pixel copy on a hit. */
export function peekDisplayCache(key: string | null): RgbaImage | null {
  if (!key) return null;
  const entry = recent.get(key);
  if (!entry) return null;
  recent.delete(key); recent.set(key, entry);
  return entry.image;
}
/** Drop a superseded live preview once its full picture is retained. Its
 * immutable disk entry and any writeback remain available for future use. */
export function forgetDisplayMemoryCache(key: string | null): void {
  if (!key) return;
  const entry = recent.get(key);
  if (!entry) return;
  recent.delete(key); memoryBytes -= entry.bytes;
}
export function clearDisplayMemoryCache(): void {
  memoryGeneration++;
  recent.clear(); reading.clear(); memoryBytes = 0;
}
/** Kept injectable so memory-pressure paths and small-budget tests use the
 * same eviction policy as the default 128 MiB recent-picture cache. */
export function configureDisplayMemoryCache(capBytes = DEFAULT_MEMORY_BYTES): void {
  if (!Number.isSafeInteger(capBytes) || capBytes < 0 || capBytes > DEFAULT_MEMORY_BYTES)
    throw new RangeError('Display memory cache must be between 0 and 128 MiB');
  memoryCap = capBytes;
  if (capBytes === 0) clearDisplayMemoryCache(); else trimMemory();
}
export function displayMemoryCacheStatus(): { cap_bytes: number; bytes: number; entries: number } {
  return { cap_bytes: memoryCap, bytes: memoryBytes, entries: recent.size };
}

export async function displayCacheKey(descriptor: DisplayCacheDescriptor): Promise<string | null> {
  if (!inTauri()) return null;
  try { return await invoke<string>('frame_cache_key', { descriptor }); } catch { return null; }
}
export async function readDisplayCache(key: string | null, options: DisplayCacheOptions = {}): Promise<RgbaImage | null> {
  if (!validKey(key) || clearing) return null;
  const cached = peekDisplayCache(key);
  if (cached) return cached;
  if (!inTauri()) return null;
  const generation = memoryGeneration;
  const pending = reading.get(key);
  if (pending) {
    const image = await pending;
    if (image && options.retain !== false && generation === memoryGeneration) remember(key, image);
    return image;
  }
  const task = (async () => {
    try {
      const bytes = await invoke<ArrayBuffer>('frame_cache_read', { key });
      if (generation !== memoryGeneration || clearing) return null;
      // A fresh render may have arrived while disk I/O was pending.
      const newer = peekDisplayCache(key);
      if (newer) return newer;
      const { header, payload } = decodeFrame(new Uint8Array(bytes));
      const h = header as { hit: boolean; metadata?: { image: Omit<RgbaImage, 'data'> } };
      if (!h.hit || !h.metadata?.image) return null;
      const image = { ...h.metadata.image, data: payload };
      if (!validImage(image)) return null;
      if (options.retain !== false) remember(key, image);
      return image;
    } catch { return null; }
  })();
  reading.set(key, task);
  try { return await task; }
  finally { if (reading.get(key) === task) reading.delete(key); }
}
function pumpWrites() {
  if (writer || clearing || !pendingWrite) return;
  writer = (async () => {
    while (pendingWrite && !clearing) {
      const job = pendingWrite; pendingWrite = null;
      let stored = false;
      try {
        const { data, ...metadata } = job.image;
        stored = await invoke<boolean>('frame_cache_write', encodeFrame({ key: job.key, metadata: { image: metadata } }, data)) === true;
      } catch { /* A full/unwritable cache must not make a successful render fail. */ }
      finally { job.done(stored); }
    }
  })().finally(() => { writer = null; pumpWrites(); });
}
/** True means this write finished with a RAM entry or a confirmed disk copy. */
export function writeDisplayCache(key: string | null, image: RgbaImage, options: DisplayCacheOptions = {}): Promise<boolean> {
  const picture = { ...image, format: image.format ?? 'rgba8' };
  if (!validKey(key) || !validImage(picture) || clearing) return Promise.resolve(false);
  if (options.retain !== false) remember(key, picture);
  if (!inTauri()) return Promise.resolve(peekDisplayCache(key) !== null);
  // One active and one latest pending write, with no encoded copy until the
  // write begins. Reject views retaining a huge unrelated backing allocation.
  if (picture.data.buffer.byteLength > MAX_IMAGE_BYTES + 1024 * 1024) return Promise.resolve(peekDisplayCache(key) !== null);
  const generation = memoryGeneration;
  return new Promise<boolean>((resolve) => {
    // Queued writes can be displaced and their RAM entries can be evicted.
    // Inspect availability when the job settles, not when it was enqueued.
    const done = (stored: boolean) => resolve(generation === memoryGeneration && !clearing
      && (stored || peekDisplayCache(key) !== null));
    pendingWrite?.done(false);
    pendingWrite = { key, image: picture, done };
    pumpWrites();
  });
}
export async function displayCacheStatus(): Promise<DisplayCacheStatus | null> {
  if (!inTauri()) return null;
  return invoke('frame_cache_status');
}
export async function configureDisplayCache(capBytes: number): Promise<void> {
  if (inTauri()) await invoke('frame_cache_configure', { capBytes });
}
export async function clearDisplayCache(): Promise<void> {
  clearDisplayMemoryCache();
  pendingWrite?.done(false); pendingWrite = null;
  const previous = clearing, active = writer;
  const task = (async () => {
    await previous;
    await active;
    if (inTauri()) await invoke('frame_cache_clear');
  })();
  clearing = task;
  try { await task; }
  finally { if (clearing === task) clearing = null; }
}
