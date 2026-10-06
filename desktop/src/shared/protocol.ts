// protocol.ts — the types of `desktop/HOST-PROTOCOL.md`, as the app reads them.
//
// The host owns the contract; this file is the frontend's reading of it. Every
// optional field here is optional because the protocol says so or because a
// request in `desktop/PROTOCOL-REQUESTS.md` has not landed yet — read the
// comment before making one required.

export type HostErrorCode =
  | 'bad_request'
  | 'not_found'
  | 'decode_failed'
  | 'engine_error'
  | 'unsupported'
  | 'cancelled'
  | 'io_error'
  | 'internal'
  // Frontend-side codes (never sent by the host):
  | 'host_exited'
  | 'timeout'
  | 'not_running';

export interface HostError {
  code: HostErrorCode | string;
  message: string;
}

export interface RequestHeader {
  id: number;
  method: string;
  params: Record<string, unknown>;
}

export interface ResponseHeaderOk {
  id: number;
  ok: true;
  result: Record<string, unknown>;
}
export interface ResponseHeaderErr {
  id: number;
  ok: false;
  error: HostError;
}
export type ResponseHeader = ResponseHeaderOk | ResponseHeaderErr;

export interface EventHeader {
  event: string;
  [k: string]: unknown;
}

export type PixelFormat = 'rgba8' | 'rgba16';
export type DisplaySpace = 'srgb' | 'display-p3';

export interface ImageInfo {
  width: number;
  height: number;
  format: PixelFormat;
  color_space: string;
  row_bytes: number;
}

export interface Capabilities {
  version?: string;
  engine?: string;
  max_mp?: number;
  max_pixels?: number;
  max_texture_dimension_2d?: number;
  tiers?: Record<string, number | null>;
  transport_version?: number;
  schema_version?: number;
  backend?: {
    spectral?: string;
    gpu?: string;
    gpu_available?: boolean;
    render_core?: string;
    unsupported_features?: string[];
    [k: string]: unknown;
  };
  [k: string]: unknown;
}

export interface HelloResult {
  protocol: number;
  host_version: string;
  build_info: string;
  backend: {
    api: string;
    device_name: string;
    driver?: string;
    vram_mb?: number;
    /** False when the engine could not start (no Vulkan device); `error` says why. */
    available?: boolean;
    error?: string;
    math_mode?: string;
    render_core?: string;
  };
  /** Null when the engine could not start. */
  capabilities: Capabilities | null;
  resources_dir: string;
  /** The methods this host answers (R1's `write_image` among them). */
  methods?: string[];
  /** Frontend-side: true when the mock host answered. */
  mock?: boolean;
}

export interface SchemaField {
  name: string;
  path: string;
  type: 'float' | 'bool' | 'str' | 'int' | string;
  layer: 'shoot' | 'print';
  default: number | boolean | string;
  live: boolean;
  range?: [number, number];
}
export interface ParamsSchema {
  schema_version: number;
  fields: SchemaField[];
}

export interface FileMetadata {
  make?: string;
  model?: string;
  lens?: string;
  iso?: number;
  shutter_s?: number;
  aperture?: number;
  focal_mm?: number;
  datetime_original?: string;
  orientation?: number;
  /** PROTOCOL-REQUESTS R2 — absent until it lands. */
  as_shot?: { temperature_k: number; tint: number };
}

export interface ProbeResult {
  kind: 'raw' | 'tiff' | 'jpeg' | 'png';
  width: number;
  height: number;
  metadata: FileMetadata;
}

export type WireValue = number | boolean | string;
export type WireParams = Record<string, WireValue>;

export interface OpenResult {
  session: string;
  width: number;
  height: number;
  metadata: FileMetadata;
  params: WireParams;
  timings_ms?: { decode?: number; open?: number };
}

export type Tier = 'live' | 'preview' | 'full';

export interface RenderResult {
  image: ImageInfo;
  tier: Tier;
  reprinted: boolean;
  timings_ms?: Record<string, number>;
}

export interface ExportImageParams {
  session: string;
  path: string;
  format: 'tiff16' | 'tiff8' | 'jpeg' | 'png';
  quality?: number;
  color_space?: 'sRGB' | 'display-p3' | 'prophoto';
  long_edge?: number;
  overwrite?: boolean;
}

export interface ProgressEvent {
  event: 'progress';
  session: string;
  progress_id: string;
  fraction: number;
  stage?: string;
}

/** A response as the renderer receives it: header result + optional pixels. */
export interface HostReply<T = Record<string, unknown>> {
  result: T;
  /** Binary payload, if the response carried one. */
  payload?: Uint8Array;
}

/** The host's lifecycle as the main process reports it to the renderer. */
export type HostState =
  | { phase: 'starting' }
  | { phase: 'ready'; hello: HelloResult }
  | { phase: 'restarting'; reason: string; attempt: number }
  | { phase: 'failed'; reason: string; detail?: string };
