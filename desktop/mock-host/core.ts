// core.ts — a stand-in for `spektralab-host` (HOST-PROTOCOL.md), for
// development without the C++ engine.
//
// Pure TypeScript with no Node imports, so the same handler runs behind the
// stdio wrapper (`main.ts`, spawned by the Tauri core under
// `SPEKTRALAB_MOCK_HOST=1`) and in the browser shim the Playwright layout
// harness uses (`src/host/browserShim.ts`).
//
// It is honest about being a mock: `hello.build_info` says so, pictures are
// synthetic (a deterministic landscape per path, so different frames look
// different), and every parameter the interface sends visibly moves the
// picture so a broken wire is a picture that does not change. It speaks only
// erasable TypeScript so `node main.ts` runs it without a build step.

import schemaFields from './schema-fields.json' with { type: 'json' };

export interface MockRequest {
  id: number;
  method: string;
  params: Record<string, unknown>;
}

export interface MockReply {
  header: Record<string, unknown>;
  payload?: Uint8Array;
}

export interface MockOptions {
  /** Report the real host's `unsupported_features` list (default true). */
  realisticUnsupported?: boolean;
  /** Native size of every synthetic frame. */
  nativeWidth?: number;
  nativeHeight?: number;
  /** A fixed delay per render, ms (to exercise the tiers). */
  renderDelayMs?: number;
  /** Paths `probe`/`open` treat as missing (tests). */
  missing?: (path: string) => boolean;
}

type Value = number | boolean | string;

interface SchemaField {
  name: string;
  path: string;
  type: string;
  layer: string;
  live: boolean;
  range?: number[];
}

const FIELDS = schemaFields as SchemaField[];

const DEFAULTS: Record<string, Value> = {
  film_stock: 'kodak_portra_400',
  print_stock: 'kodak_portra_endura',
  exposure_compensation_ev: 0,
  auto_exposure: true,
  auto_exposure_method: 'center_weighted',
  film_format_mm: 36,
  print_exposure: 1,
  filter_shift_scale: 1,
  grain_active: true,
  grain_sublayers_active: true,
  halation_active: true,
  halation_amount: 1,
  dir_couplers_active: true,
  dir_couplers_amount: 1,
  glare_active: true,
  glare_amount: 1,
  grain_amount: 1,
  halation_scatter_amount: 1,
  density_curve_gamma: 1,
  input_color_space: 'ProPhoto RGB',
  output_color_space: 'ProPhoto RGB',
  output_cctf_encoding: true,
  geometry_crop_w: 1,
  geometry_crop_h: 1,
  contrast_mask_core: 1,
  contrast_mask_scale: 0.03,
  contrast_mask_scheme: 'gaussian',
  scene_latitude_norm: 'power',
  scene_latitude_highlight_knee: 2,
  scene_latitude_shadow_knee: -2,
  scene_latitude_rolloff: 2,
  scene_latitude_max_lift: 4,
  preview_long_edge: 2560,
  overscan_format: '135',
  overscan_mode: 'strip',
  date_imprint_ev: 3.5,
  date_imprint_size: 1,
  date_imprint_style: 'lcd',
  date_imprint_placement: 'frame',
  date_imprint_corner: 'br',
};

function defaultFor(f: SchemaField): Value {
  if (f.name in DEFAULTS) return DEFAULTS[f.name]!;
  switch (f.type) {
    case 'bool':
      return false;
    case 'str':
      return '';
    default:
      return f.range ? Math.max(f.range[0]!, Math.min(0, f.range[1]!)) : 0;
  }
}

export const UNSUPPORTED_ON_PORT = [
  'digital_intermediate',
  'scene_latitude_mapping',
  'contrast_mask',
  'overscan',
  'date_imprint',
];

const STOCKS: Record<string, number> = {};
function stockHue(id: string): number {
  if (!(id in STOCKS)) STOCKS[id] = (hash(id) % 360) / 360;
  return STOCKS[id]!;
}

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

interface Session {
  id: string;
  path: string;
  width: number;
  height: number;
  params: Record<string, Value>;
  seed: number;
}

class HostError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export class MockHost {
  private sessions = new Map<string, Session>();
  private next = 1;
  private opts: Required<Omit<MockOptions, 'missing'>> & { missing?: (p: string) => boolean };

  constructor(opts: MockOptions = {}) {
    this.opts = {
      realisticUnsupported: opts.realisticUnsupported ?? true,
      nativeWidth: opts.nativeWidth ?? 3000,
      nativeHeight: opts.nativeHeight ?? 2000,
      renderDelayMs: opts.renderDelayMs ?? 0,
      missing: opts.missing,
    };
  }

  async handle(req: MockRequest): Promise<MockReply> {
    try {
      const { result, payload } = await this.dispatch(req.method, req.params ?? {});
      return { header: { id: req.id, ok: true, result }, payload };
    } catch (e) {
      const err = e instanceof HostError ? e : new HostError('internal', String((e as Error)?.message ?? e));
      return { header: { id: req.id, ok: false, error: { code: err.code, message: err.message } } };
    }
  }

  private session(params: Record<string, unknown>): Session {
    const s = this.sessions.get(String(params.session ?? ''));
    if (!s) throw new HostError('not_found', `no session ${String(params.session)}`);
    return s;
  }

  private capabilities() {
    return {
      version: 'mock-1.3.1',
      engine: 'spektrafilm.mock',
      max_mp: 200,
      max_pixels: 200e6,
      max_texture_dimension_2d: 16384,
      tiers: { live: 2560, preview: 2560, full: null },
      transport_version: 1,
      schema_version: 1,
      backend: {
        spectral: 'mock',
        gpu: 'Mock GPU (no engine)',
        gpu_available: true,
        render_core: 'mock',
        unsupported_features: this.opts.realisticUnsupported ? UNSUPPORTED_ON_PORT : [],
      },
    };
  }

  private dims(path: string): { width: number; height: number } {
    // Portrait for every third file, so turns and the filmstrip get exercised.
    const portrait = hash(path) % 3 === 0;
    const { nativeWidth: w, nativeHeight: h } = this.opts;
    return portrait ? { width: h, height: w } : { width: w, height: h };
  }

  private kind(path: string): string {
    const ext = path.split('.').pop()?.toLowerCase() ?? '';
    if (ext === 'tif' || ext === 'tiff') return 'tiff';
    if (ext === 'jpg' || ext === 'jpeg') return 'jpeg';
    if (ext === 'png') return 'png';
    return 'raw';
  }

  private metadata(path: string) {
    const h = hash(path);
    return {
      make: 'Mock',
      model: 'Synthetic ' + (100 + (h % 900)),
      lens: '50mm f/1.8',
      iso: [100, 200, 400, 800][h % 4],
      shutter_s: [1 / 60, 1 / 125, 1 / 250][h % 3],
      aperture: [2, 2.8, 4, 5.6][h % 4],
      focal_mm: 50,
      datetime_original: '2026:09:' + String(10 + (h % 18)).padStart(2, '0') + ' 12:34:56',
      orientation: 1,
    };
  }

  private async dispatch(method: string, p: Record<string, unknown>): Promise<{ result: unknown; payload?: Uint8Array }> {
    switch (method) {
      case 'hello':
        return {
          result: {
            protocol: 1,
            host_version: '1.3.1-mock',
            build_info: 'mock host (desktop/mock-host) — synthetic pictures, no engine',
            backend: { api: 'mock', device_name: 'Mock GPU', driver: 'none' },
            capabilities: this.capabilities(),
            resources_dir: '(mock)',
          },
        };
      case 'ping':
      case 'shutdown':
      case 'cancel':
        return { result: {} };
      case 'params_schema':
        return {
          result: {
            schema_version: 1,
            fields: FIELDS.map((f) => ({ ...f, default: defaultFor(f) })),
          },
        };
      case 'print_lut_catalog':
        return { result: { stocks: [] } };
      case 'memory_report':
        return { result: { persistent: { bytes: 0 }, sessions: [] } };
      case 'probe': {
        const path = String(p.path ?? '');
        if (this.opts.missing?.(path)) throw new HostError('not_found', `${path}: no such file`);
        return { result: { kind: this.kind(path), ...this.dims(path), metadata: this.metadata(path) } };
      }
      case 'thumbnail': {
        const path = String(p.path ?? '');
        if (this.opts.missing?.(path)) throw new HostError('not_found', `${path}: no such file`);
        const edge = Math.max(16, Math.min(1024, Number(p.long_edge ?? 256)));
        const { width, height } = this.dims(path);
        const s = edge / Math.max(width, height);
        const w = Math.max(1, Math.round(width * s));
        const h = Math.max(1, Math.round(height * s));
        const pixels = paint(w, h, hash(path), null);
        return { result: { image: imageInfo(w, h) }, payload: pixels };
      }
      case 'open': {
        const path = String(p.path ?? '');
        if (this.opts.missing?.(path)) throw new HostError('not_found', `${path}: no such file`);
        const params: Record<string, Value> = {};
        for (const f of FIELDS) params[f.name] = defaultFor(f);
        const incoming = (p.params ?? {}) as Record<string, unknown>;
        this.validate(incoming);
        Object.assign(params, incoming);
        const id = 's' + this.next++;
        const { width, height } = this.dims(path);
        this.sessions.set(id, { id, path, width, height, params, seed: hash(path) });
        return {
          result: {
            session: id,
            width,
            height,
            metadata: this.metadata(path),
            params,
            timings_ms: { decode: 12, open: 3 },
          },
        };
      }
      case 'close':
        this.sessions.delete(String(p.session ?? ''));
        return { result: {} };
      case 'set_params': {
        const s = this.session(p);
        const delta = (p.delta ?? {}) as Record<string, unknown>;
        this.validate(delta);
        Object.assign(s.params, delta);
        return { result: { params: s.params } };
      }
      case 'get_params':
        return { result: { params: this.session(p).params } };
      case 'solve': {
        const s = this.session(p);
        return {
          result: {
            solved_params: { c_filter_neutral: 0, m_filter_neutral: 55, y_filter_neutral: 65, exposure_compensation_ev: 0 },
            exposure_ev_by_method: { balanced: 0.3, center: 0.1, protect_highlights: -0.4, protect_shadows: 0.6 },
            session: s.id,
          },
        };
      }
      case 'render': {
        const s = this.session(p);
        const tier = String(p.tier ?? 'preview');
        const format = String(p.format ?? 'rgba8');
        if (format !== 'rgba8' && format !== 'rgba16') throw new HostError('bad_request', `format ${format}`);
        const preview = Number(s.params.preview_long_edge ?? 2560) || 2560;
        const scale = tier === 'full' ? 1 : Math.min(1, preview / Math.max(s.width, s.height));
        const w = Math.max(1, Math.round(s.width * scale));
        const h = Math.max(1, Math.round(s.height * scale));
        if (this.opts.renderDelayMs) await sleep(tier === 'full' ? this.opts.renderDelayMs * 3 : this.opts.renderDelayMs);
        const rgba8 = paint(w, h, s.seed, s.params);
        let payload: Uint8Array = rgba8;
        if (format === 'rgba16') {
          payload = new Uint8Array(w * h * 8);
          const dv = new DataView(payload.buffer);
          for (let i = 0; i < w * h * 4; i++) dv.setUint16(i * 2, rgba8[i]! * 257, true);
        }
        return {
          result: {
            image: {
              width: w,
              height: h,
              format,
              color_space: format === 'rgba8' ? (p.display === 'display-p3' ? 'Display P3' : 'sRGB') : 'ProPhoto RGB',
              row_bytes: w * (format === 'rgba8' ? 4 : 8),
            },
            tier,
            reprinted: Boolean(p.reprint),
            timings_ms: { render: 5 },
          },
          payload,
        };
      }
      case 'scene_latitude':
        return { result: latitude(this.session(p), (p.request ?? {}) as Record<string, unknown>) };
      case 'overscan_geometry':
        throw new HostError('unsupported', 'overscan is not available on this host');
      case 'preview_stock_lut': {
        const w = 64, h = 64;
        return { result: { image: imageInfo(w, h) }, payload: paint(w, h, hash(String(p.print_stock)), null) };
      }
      case 'progress':
        return { result: { fraction: 1, stage: 'done' } };
      case 'export_image': {
        const s = this.session(p);
        const le = Number(p.long_edge ?? 0);
        const k = le > 0 ? Math.min(1, le / Math.max(s.width, s.height)) : 1;
        return {
          result: {
            path: String(p.path),
            width: Math.round(s.width * k),
            height: Math.round(s.height * k),
            bytes: 0,
            mock: true,
          },
        };
      }
      case 'export_cube':
      case 'export_di':
        return { result: { path: String(p.path), mock: true } };
      default:
        throw new HostError('bad_request', `unknown method ${method}`);
    }
  }

  private validate(delta: Record<string, unknown>) {
    for (const [k, v] of Object.entries(delta)) {
      const f = FIELDS.find((x) => x.name === k);
      if (!f) throw new HostError('bad_request', `unknown parameter '${k}'`);
      const t = typeof v;
      const ok =
        (f.type === 'bool' && t === 'boolean') ||
        (f.type === 'str' && t === 'string') ||
        ((f.type === 'float' || f.type === 'int') && t === 'number');
      if (!ok) throw new HostError('bad_request', `parameter '${k}' has the wrong type`);
      if (f.range && typeof v === 'number' && (v < f.range[0]! - 1e-9 || v > f.range[1]! + 1e-9))
        throw new HostError('bad_request', `parameter '${k}' = ${v} is outside ${f.range[0]}…${f.range[1]}`);
      // The real host refuses an explicit request for an unported feature.
      if (this.opts.realisticUnsupported && v === true) {
        const gate: Record<string, string> = {
          digital_intermediate: 'digital_intermediate',
          scene_latitude_active: 'scene_latitude_mapping',
          contrast_mask_active: 'contrast_mask',
          overscan_active: 'overscan',
          date_imprint_active: 'date_imprint',
        };
        if (gate[k]) throw new HostError('unsupported', `${gate[k]} is not available on this host`);
      }
    }
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function imageInfo(w: number, h: number) {
  return { width: w, height: h, format: 'rgba8', color_space: 'sRGB', row_bytes: w * 4 };
}

/**
 * A synthetic landscape: sky gradient, sun, hills, a few "buildings", per-path
 * colours. With params, a crude print: exposure, filters, stock tint, grain.
 * Deliberately has a distinct top-left corner (a small red square) so a flip
 * or a quarter turn is visible.
 */
export function paint(w: number, h: number, seed: number, params: Record<string, Value> | null): Uint8Array {
  const out = new Uint8Array(w * h * 4);
  const hue = (seed % 360) / 360;
  const sunX = 0.25 + ((seed >>> 8) % 50) / 100;
  const sunY = 0.2 + ((seed >>> 16) % 20) / 100;
  let gain = 1;
  let yShift = 0;
  let mShift = 0;
  let tint = 0;
  let grain = 0;
  let contrast = 1;
  let scanNeg = false;
  if (params) {
    const pe = Number(params.print_exposure ?? 1);
    gain = Math.pow(1 / Math.max(pe, 0.05), 0.6) * Math.pow(2, Number(params.exposure_compensation_ev ?? 0) * 0.15);
    const scale = Number(params.filter_shift_scale ?? 1) / 40;
    yShift = Number(params.y_filter_shift ?? 0) * scale;
    mShift = Number(params.m_filter_shift ?? 0) * scale;
    tint = stockHue(String(params.film_stock ?? '')) - 0.5 + (stockHue(String(params.print_stock ?? '')) - 0.5) * 0.5;
    grain = params.grain_active ? 0.05 * Number(params.grain_amount ?? 1) : 0;
    contrast = 0.9 + stockHue(String(params.print_stock ?? '')) * 0.4;
    scanNeg = Boolean(params.scan_film) && String(params.film_stock ?? '').length % 2 === 0;
  }
  let rnd = seed || 1;
  for (let y = 0; y < h; y++) {
    const v = y / h;
    for (let x = 0; x < w; x++) {
      const u = x / w;
      let r: number, g: number, b: number;
      const horizon = 0.62 + 0.06 * Math.sin(u * 9 + hue * 6) + 0.03 * Math.sin(u * 23);
      if (v < horizon) {
        // sky
        const t = v / horizon;
        r = 0.35 + 0.4 * t + 0.2 * Math.cos(hue * 6.28);
        g = 0.5 + 0.3 * t;
        b = 0.9 - 0.2 * t + 0.1 * Math.sin(hue * 6.28);
        const d = Math.hypot((u - sunX) * (w / h), v - sunY);
        const sun = Math.max(0, 1 - d / 0.08);
        r += sun * 1.2;
        g += sun * 1.0;
        b += sun * 0.6;
        // buildings
        const bx = Math.floor(u * 14);
        const bh = 0.15 + ((hash(String(bx + seed)) % 100) / 100) * 0.25;
        if (v > horizon - bh && (bx + (seed & 1)) % 3 !== 0) {
          const lit = (Math.floor(u * w / 9) + Math.floor(v * h / 11)) % 5 === 0;
          r = lit ? 0.95 : 0.2;
          g = lit ? 0.8 : 0.22;
          b = lit ? 0.45 : 0.28;
        }
      } else {
        const t = (v - horizon) / (1 - horizon);
        r = 0.2 + 0.25 * (1 - t) + 0.1 * Math.sin(hue * 6.28 + 1);
        g = 0.35 + 0.2 * (1 - t);
        b = 0.15 + 0.1 * t;
      }
      if (u < 0.04 && v < 0.04 * (w / h)) {
        r = 1;
        g = 0.1;
        b = 0.1;
      }
      if (params) {
        r *= gain * (1 + tint * 0.3) * (1 - yShift * 0.1 - mShift * 0.0);
        g *= gain * (1 - mShift * 0.25);
        b *= gain * (1 - tint * 0.3) * (1 + yShift * 0.25);
        r = 0.5 + (r - 0.5) * contrast;
        g = 0.5 + (g - 0.5) * contrast;
        b = 0.5 + (b - 0.5) * contrast;
        if (grain) {
          rnd = (Math.imul(rnd, 1664525) + 1013904223) >>> 0;
          const n = ((rnd >>> 8) / 16777216 - 0.5) * grain;
          r += n;
          g += n;
          b += n;
        }
        if (scanNeg) {
          r = 1 - r * 0.6;
          g = 0.85 - g * 0.6;
          b = 0.7 - b * 0.6;
        }
      }
      const i = (y * w + x) * 4;
      out[i] = clamp8(r);
      out[i + 1] = clamp8(g);
      out[i + 2] = clamp8(b);
      out[i + 3] = 255;
    }
  }
  return out;
}

function clamp8(v: number): number {
  return v <= 0 ? 0 : v >= 1 ? 255 : Math.round(v * 255);
}

function latitude(s: Session, req: Record<string, unknown>) {
  const n = 64;
  const lo = -10;
  const hi = 10;
  const fractions: number[] = [];
  let total = 0;
  for (let i = 0; i < n; i++) {
    const c = lo + ((i + 0.5) * (hi - lo)) / n;
    const v = Math.exp(-((c + 0.5) ** 2) / 6) + 0.3 * Math.exp(-((c - 3) ** 2) / 1.5) * ((s.seed % 7) / 7);
    fractions.push(v);
    total += v;
  }
  for (let i = 0; i < n; i++) fractions[i] = fractions[i]! / total;
  const hp = Number(req.highlight_pull_back ?? 0);
  const sp = Number(req.shadow_pull_back ?? 0);
  const rampEV: number[] = [];
  const rampY: number[] = [];
  for (let e = -8; e <= 8; e += 0.25) {
    rampEV.push(e);
    rampY.push(0.9 / (1 + Math.exp(-(e + 0.5) / 1.2)) + 0.01);
  }
  const side = (on: boolean, pull: number, extreme: number, boundary: number) => ({
    on,
    pull_back: pull,
    minimum_pull_back: Math.max(0, Math.abs(extreme - boundary) - 0.2),
    scene_extreme_ev: extreme,
    medium_boundary_ev: boundary,
    knee: on ? boundary - Math.sign(boundary) * 1.5 : null,
    room: on ? 0.5 : null,
    landing_ev: boundary,
    slope_at_extreme: 0.3,
  });
  return {
    medium: { shadow_ev: -3.6, highlight_ev: 2.1, latitude_stops: 5.7, y_black: 0.01, y_white: 0.91, ramp_ev: rampEV, ramp_y: rampY },
    scene: {
      norm: 'power',
      samples: 65536,
      p0_1: -7.2,
      p1: -5.5,
      p50: -0.5,
      p99: 3.2,
      p99_9: 4.1,
      histogram: { lo_ev: lo, hi_ev: hi, fractions },
    },
    suggested: { highlight_pull_back: 2, shadow_pull_back: 3.5, margin_used: 0.25, valid: true },
    fit: {
      valid: true,
      issues: [],
      warnings: [],
      highlight: side(hp > 0, hp, 4.1, 2.1),
      shadow: side(sp > 0, sp, -7.2, -3.6),
      core_stops: 3,
      params_delta: {
        scene_latitude_active: hp > 0 || sp > 0,
        scene_latitude_norm: 'power',
        scene_latitude_highlight_knee: 2 - hp * 0.2,
        scene_latitude_highlight_room: hp * 0.1,
        scene_latitude_shadow_knee: -2 + sp * 0.2,
        scene_latitude_shadow_room: sp * 0.1,
        scene_latitude_rolloff: Number(req.rolloff ?? 2),
        scene_latitude_max_lift: Number(req.max_lift ?? 4),
      },
    },
  };
}
