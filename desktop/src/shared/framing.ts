// framing.ts — HOST-PROTOCOL.md §1, both directions.
//
//   u32 LE header_len · u32 LE payload_len · JSON header · binary payload
//
// Pure (no Node imports) so the mock host, the main process and the tests use
// the same codec. A decoder is fed arbitrary chunks — stdout delivers whatever
// the pipe had, which is routinely half a frame or three frames at once.

export interface Frame {
  header: unknown;
  payload: Uint8Array;
}

/** Bounds a frame may not exceed; a corrupt length must not allocate 4 GB. */
export const MAX_HEADER_BYTES = 64 * 1024 * 1024;
export const MAX_PAYLOAD_BYTES = 2 * 1024 * 1024 * 1024 - 1;

const enc = new TextEncoder();
const dec = new TextDecoder('utf-8', { fatal: true });

export function encodeFrame(header: unknown, payload?: Uint8Array): Uint8Array {
  const json = enc.encode(JSON.stringify(header));
  const body = payload ?? new Uint8Array(0);
  const out = new Uint8Array(8 + json.length + body.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, json.length, true);
  view.setUint32(4, body.length, true);
  out.set(json, 8);
  out.set(body, 8 + json.length);
  return out;
}

export class FrameError extends Error {}

/**
 * Incremental decoder. `push` returns every frame completed by the chunk.
 * Chunks are kept as a list and only concatenated when a frame completes, so
 * a 180 MB full-resolution payload arriving in 64 KB pieces is copied once,
 * not once per piece.
 */
export class FrameDecoder {
  private chunks: Uint8Array[] = [];
  private buffered = 0;
  private need: { header: number; payload: number } | null = null;

  push(chunk: Uint8Array): Frame[] {
    if (chunk.length) {
      this.chunks.push(chunk);
      this.buffered += chunk.length;
    }
    const frames: Frame[] = [];
    for (;;) {
      if (!this.need) {
        if (this.buffered < 8) break;
        const head = this.take(8);
        const view = new DataView(head.buffer, head.byteOffset, 8);
        const header = view.getUint32(0, true);
        const payload = view.getUint32(4, true);
        if (header > MAX_HEADER_BYTES) throw new FrameError(`header length ${header} exceeds bound`);
        if (payload > MAX_PAYLOAD_BYTES) throw new FrameError(`payload length ${payload} exceeds bound`);
        this.need = { header, payload };
      }
      const total = this.need.header + this.need.payload;
      if (this.buffered < total) break;
      const body = this.take(total);
      const jsonBytes = body.subarray(0, this.need.header);
      let parsed: unknown;
      try {
        parsed = JSON.parse(dec.decode(jsonBytes));
      } catch (e) {
        throw new FrameError(`malformed JSON header: ${(e as Error).message}`);
      }
      frames.push({ header: parsed, payload: body.subarray(this.need.header) });
      this.need = null;
    }
    return frames;
  }

  get pendingBytes(): number {
    return this.buffered;
  }

  private take(n: number): Uint8Array {
    if (n === 0) return new Uint8Array(0);
    const first = this.chunks[0]!;
    if (first.length >= n) {
      const out = first.subarray(0, n);
      if (first.length === n) this.chunks.shift();
      else this.chunks[0] = first.subarray(n);
      this.buffered -= n;
      return out;
    }
    const out = new Uint8Array(n);
    let off = 0;
    while (off < n) {
      const c = this.chunks[0]!;
      const k = Math.min(c.length, n - off);
      out.set(c.subarray(0, k), off);
      off += k;
      if (k === c.length) this.chunks.shift();
      else this.chunks[0] = c.subarray(k);
    }
    this.buffered -= n;
    return out;
  }
}

/** Split one complete frame held in memory (a reply from the Tauri core). */
export function decodeFrame(bytes: Uint8Array): Frame {
  if (bytes.length < 8) throw new FrameError('frame shorter than its length prefix');
  const view = new DataView(bytes.buffer, bytes.byteOffset, 8);
  const h = view.getUint32(0, true);
  const p = view.getUint32(4, true);
  if (bytes.length !== 8 + h + p) throw new FrameError(`frame length mismatch: ${bytes.length} != 8 + ${h} + ${p}`);
  const header: unknown = JSON.parse(dec.decode(bytes.subarray(8, 8 + h)));
  return { header, payload: bytes.subarray(8 + h) };
}
