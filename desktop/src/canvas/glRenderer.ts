// glRenderer.ts — the canvas, in WebGL2 (the Mac's `Canvas/Renderer.swift`
// + `canvasFragment` and `layer2` in Shaders.metal, folded into one pass).
//
// The host returns a display-encoded, graded and cropped frame. The canvas
// maps through source coordinates so crop gestures and stale frames remain
// aligned while a replacement is in flight. Legacy hosts retain Layer 2 here.
// sRGB originals and pending frames are converted to the current drawing
// buffer encoding before the browser performs display colour management.
// The geometry map is `geometryMap` from the Metal
// shader, transliterated; `src/shared/geometry.ts::shaderMap` is the same
// function in TypeScript and `geometry.test.ts` pins it to the model's
// `sourcePoint`, so the canvas, the export and the navigator agree (trap 33).
//
// The same program renders the *output* (geometry + Layer 2, no viewport) to
// an offscreen target for the navigator and the histogram, so those surfaces
// show exactly the canvas's frame.

import { type Adjustments, CURVE_TABLE_SIZE, SRGB_MID_GREY, curveTables, layer2Uniforms } from '@shared/adjustments';
import { type Geometry, type GeometryUniform, GEOMETRY_DEFAULT, outputPoint, uniform } from '@shared/geometry';
import type { DisplaySpace } from '@shared/protocol';
import type { RgbaImage } from '../host/client';
import { previewSpace } from './colorSpace';

/** Source UV → the geometry already baked into a host frame, column-major. */
export function processedImageMap(g: Geometry | undefined, native: { width: number; height: number }): Float32Array {
  if (!g) return new Float32Array([1, 0, 0, 0, 1, 0, 0, 0, 1]);
  const o = outputPoint(g, { x: 0, y: 0 }, native);
  const x = outputPoint(g, { x: 1, y: 0 }, native);
  const y = outputPoint(g, { x: 0, y: 1 }, native);
  return new Float32Array([x.x - o.x, x.y - o.y, 0, y.x - o.x, y.y - o.y, 0, o.x, o.y, 1]);
}

const VERT = `#version 300 es
in vec2 aPos;
out vec2 vUv;
void main() {
  vUv = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5);
  gl_Position = vec4(aPos, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
precision highp usampler2D;
in vec2 vUv;
out vec4 outColor;

uniform sampler2D uImage;
uniform sampler2D uOriginal;
uniform usampler2D uImage16;
uniform usampler2D uOriginal16;
uniform bool uImageWide;
uniform bool uOriginalWide;
uniform sampler2D uCurves;
uniform bool uHasImage;
uniform bool uHasOriginal;
uniform bool uImageProcessed;
uniform mat3 uImageMap;
uniform int uImageSpace;
uniform int uOriginalSpace;
uniform int uOutputSpace;

// viewport: output uv = (fragPx - offset) / size
uniform vec2 uViewport;      // device px
uniform vec2 uOffset;        // device px, top-left of the output
uniform vec2 uOutSize;       // device px of the output on screen
uniform bool uOffscreen;     // render the output itself (navigator, histogram)
uniform float uSurround;

// geometry (display) — GeometryUniform
uniform vec2 gCentre;
uniform vec2 gHalf;
uniform vec2 gCosSin;
uniform vec2 gPixelRatio;
uniform int gTurns;
uniform int gFlips;
uniform bool gActive;

// crop being edited: dim outside it
uniform bool uEditingCrop;
uniform vec2 cCentre;
uniform vec2 cHalf;
uniform vec2 cCosSin;

uniform int uCompare;        // 0 off, 1 split, 2 original only
uniform float uSplit;

// layer 2
uniform bool lEnabled;
uniform vec3 lWb;
uniform float lExposure;
uniform float lContrast;
uniform float lBrightness;
uniform float lSaturation;
uniform float lHighlights;
uniform float lShadows;
uniform float lBlack;
uniform float lWhite;
uniform vec3 lCbMaster;
uniform vec3 lCbShadows;
uniform vec3 lCbMidtones;
uniform vec3 lCbHighlights;
uniform vec4 lCbLum;
uniform float lVignetteAmount;
uniform float lVignetteMid;
uniform float lMidGrey;
uniform bool lCurves;

// RGBA16UI is core WebGL2. Four exact integer fetches retain all 16 source
// bits, then interpolate in float; no full-image Uint16-to-Float32 CPU copy.
vec3 sample16(usampler2D image, vec2 uv) {
  ivec2 size = textureSize(image, 0);
  vec2 p = uv * vec2(size) - 0.5;
  ivec2 lo = ivec2(floor(p)); vec2 f = fract(p);
  vec3 a = vec3(texelFetch(image, clamp(lo, ivec2(0), size-1), 0).rgb);
  vec3 b = vec3(texelFetch(image, clamp(lo+ivec2(1,0), ivec2(0), size-1), 0).rgb);
  vec3 c = vec3(texelFetch(image, clamp(lo+ivec2(0,1), ivec2(0), size-1), 0).rgb);
  vec3 d = vec3(texelFetch(image, clamp(lo+ivec2(1,1), ivec2(0), size-1), 0).rgb);
  return mix(mix(a,b,f.x), mix(c,d,f.x), f.y) / 65535.0;
}

vec2 geometryMap(vec2 uv) {
  if (!gActive) return uv;
  vec2 u = uv;
  if ((gFlips & 1) != 0) u.x = 1.0 - u.x;
  if ((gFlips & 2) != 0) u.y = 1.0 - u.y;
  if (gTurns == 1) u = vec2(u.y, 1.0 - u.x);
  else if (gTurns == 2) u = vec2(1.0 - u.x, 1.0 - u.y);
  else if (gTurns == 3) u = vec2(1.0 - u.y, u.x);
  float px = (u.x - 0.5) * 2.0 * gHalf.x;
  float py = (u.y - 0.5) * 2.0 * gHalf.y * gPixelRatio.y;
  float rx = px * gCosSin.x - py * gCosSin.y;
  float ry = px * gCosSin.y + py * gCosSin.x;
  return vec2(gCentre.x + rx, gCentre.y + ry * gPixelRatio.x);
}

bool insideCrop(vec2 suv) {
  float dx = suv.x - cCentre.x;
  float dy = (suv.y - cCentre.y) * gPixelRatio.y;
  float lx =  dx * cCosSin.x + dy * cCosSin.y;
  float ly = -dx * cCosSin.y + dy * cCosSin.x;
  return abs(lx) <= cHalf.x && abs(ly) <= cHalf.y * gPixelRatio.y;
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

float tonePosition(float l, float m0) {
  float m = clamp(m0, 0.0, 1.0);
  if (m <= 0.0 || m >= 1.0) m = 0.5;
  return (l <= m) ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1.0 - m);
}

float curve(float x, int row) {
  float n = ${CURVE_TABLE_SIZE}.0;
  float u = (clamp(x, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
  return texture(uCurves, vec2(u, (float(row) + 0.5) / 5.0)).r;
}

vec3 layer2(vec3 c, vec2 suv) {
  if (!lEnabled) return c;
  c *= lWb;
  if (lExposure != 1.0) c = pow(pow(max(c, 0.0), vec3(2.2)) * lExposure, vec3(1.0 / 2.2));
  if (lContrast != 0.0) { float k = 1.0 + lContrast * 1.2; c = (c - lMidGrey) * k + lMidGrey; }
  if (lBrightness != 0.0) c = pow(max(c, 0.0), vec3(1.0 / (1.0 + lBrightness * 0.8)));
  float l = tonePosition(luma(c), lMidGrey);
  if (lShadows != 0.0) { float w = (1.0 - l); w = w * w; c += lShadows * 0.25 * w * (1.0 - c); }
  if (lHighlights != 0.0) { float w = l * l; c += lHighlights * 0.25 * w * (lHighlights > 0.0 ? (1.0 - c) : c); }
  c = (c - lBlack) / max(1.0 - lBlack - lWhite, 0.05);
  l = luma(c);
  c = l + (c - l) * lSaturation;
  float ls = clamp(tonePosition(l, lMidGrey), 0.0, 1.0);
  float wS = (1.0 - ls) * (1.0 - ls);
  float wH = ls * ls;
  float wM = max(1.0 - wS - wH, 0.0);
  c += lCbMaster + lCbShadows * wS + lCbMidtones * wM + lCbHighlights * wH;
  c *= 1.0 + lCbLum.x + lCbLum.y * wS + lCbLum.z * wM + lCbLum.w * wH;
  if (lCurves) {
    c = clamp(c, 0.0, 1.0);
    float ly = luma(c);
    float ly2 = curve(ly, 1);
    c *= (ly > 1e-4) ? (ly2 / ly) : 1.0;
    c = clamp(c, 0.0, 1.0);
    c = vec3(curve(c.r, 0), curve(c.g, 0), curve(c.b, 0));
    c = vec3(curve(c.r, 2), curve(c.g, 3), curve(c.b, 4));
  }
  if (lVignetteAmount != 0.0) {
    vec2 p = suv - 0.5;
    float d = length(p * 2.0);
    float fall = smoothstep(lVignetteMid * 1.2, 1.5, d);
    c *= 1.0 + lVignetteAmount * fall * 0.9;
  }
  return clamp(c, 0.0, 1.0);
}

vec3 displayConvert(vec3 c, int source) {
  if (source == uOutputSpace) return c;
  vec3 lin = mix(c / 12.92, pow((max(c, 0.0) + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
  // D65 Display P3 → linear sRGB (columns); inverse gives sRGB → P3.
  const mat3 p3ToSrgb = mat3(1.2249401763, -0.0420569547, -0.0196375546,
                           -0.2249401763, 1.0420569547, -0.0786360456,
                            0.0, 0.0, 1.0982736001);
  lin = source == 1 ? p3ToSrgb * lin : inverse(p3ToSrgb) * lin;
  lin = clamp(lin, 0.0, 1.0);
  return mix(12.92 * lin, 1.055 * pow(lin, vec3(1.0 / 2.4)) - 0.055, greaterThan(lin, vec3(0.0031308)));
}

void main() {
  vec2 ouv;
  if (uOffscreen) {
    ouv = vUv;
  } else {
    vec2 px = vUv * uViewport;
    ouv = (px - uOffset) / uOutSize;
    if (ouv.x < 0.0 || ouv.y < 0.0 || ouv.x > 1.0 || ouv.y > 1.0) {
      outColor = vec4(vec3(uSurround), 1.0);
      return;
    }
  }
  vec2 suv = geometryMap(ouv);
  if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
    outColor = vec4(vec3(uSurround), 1.0);
    return;
  }
  bool before = uCompare == 2 || (uCompare == 1 && ouv.x < uSplit);
  vec3 c;
  if (before && uHasOriginal) {
    c = displayConvert(uOriginalWide ? sample16(uOriginal16, suv) : texture(uOriginal, suv).rgb, uOriginalSpace);
  } else if (uHasImage) {
    vec2 imageUv = (uImageMap * vec3(suv, 1.0)).xy;
    if (any(lessThan(imageUv, vec2(0.0))) || any(greaterThan(imageUv, vec2(1.0)))) {
      outColor = vec4(vec3(uSurround), 1.0);
      return;
    }
    c = uImageWide ? sample16(uImage16, imageUv) : texture(uImage, imageUv).rgb;
    if (!uImageProcessed) c = layer2(c, suv);
    c = displayConvert(c, uImageSpace);
  } else {
    c = vec3(uSurround);
  }
  if (uEditingCrop && !insideCrop(suv)) c *= 0.4;
  outColor = vec4(c, 1.0);
}`;

export interface DrawState {
  /** Device px of the canvas. */
  viewport: { width: number; height: number };
  /** Device px: where the output's top-left is and how big it is on screen. */
  offset: { x: number; y: number };
  outSize: { width: number; height: number };
  /** The geometry used to map output → source (identity-crop while cropping). */
  display: Geometry;
  /** The crop being edited (dims outside), or null. */
  editingCrop: Geometry | null;
  /** The source's size in pixels (the native frame's; the texture may be smaller). */
  sourceSize: { width: number; height: number };
  adjustments: Adjustments;
  compare: 0 | 1 | 2;
  split: number;
  surround: number;
}

export class GLRenderer {
  readonly gl: WebGL2RenderingContext;
  private program: WebGLProgram;
  private loc = new Map<string, WebGLUniformLocation | null>();
  private image: WebGLTexture;
  private original: WebGLTexture;
  private image16: WebGLTexture;
  private original16: WebGLTexture;
  private imageWide = false;
  private originalWide = false;
  private floatCanvas: boolean;
  private bufferSize = { width: 0, height: 0 };
  displayPrecision: 'float16' | 'unorm8' = 'unorm8';
  private curves: WebGLTexture;
  private hasImage = false;
  private hasOriginal = false;
  private imageInfo: Pick<RgbaImage, 'colorSpace' | 'processedGeometry'> | null = null;
  private originalSpace: DisplaySpace = 'srgb';
  displaySpace: DisplaySpace = 'srgb';
  private curvesKey = '';
  private fbo: WebGLFramebuffer | null = null;
  private fboTex: WebGLTexture | null = null;
  private fboSize = { width: 0, height: 0 };
  readonly maxTexture: number;

  constructor(canvas: HTMLCanvasElement | OffscreenCanvas) {
    const gl = canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: true }) as WebGL2RenderingContext | null;
    if (!gl) throw new Error('WebGL2 is not available in this webview');
    this.gl = gl;
    this.floatCanvas = typeof (gl as WebGL2RenderingContext & { drawingBufferStorage?: unknown }).drawingBufferStorage === 'function'
      && !!gl.getExtension('EXT_color_buffer_float');
    this.maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE) as number;
    this.program = this.link();
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const a = gl.getAttribLocation(this.program, 'aPos');
    gl.enableVertexAttribArray(a);
    gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 0, 0);
    this.image = this.texture(gl.LINEAR);
    this.original = this.texture(gl.LINEAR);
    this.image16 = this.texture(gl.NEAREST);
    this.original16 = this.texture(gl.NEAREST);
    this.clearTexture(this.image, false); this.clearTexture(this.original, false);
    this.clearTexture(this.image16, true); this.clearTexture(this.original16, true);
    this.curves = this.texture(gl.LINEAR);
  }

  private link(): WebGLProgram {
    const gl = this.gl;
    const sh = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error('shader: ' + gl.getShaderInfoLog(s));
      return s;
    };
    const p = gl.createProgram()!;
    gl.attachShader(p, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error('program: ' + gl.getProgramInfoLog(p));
    return p;
  }

  private texture(filter: number): WebGLTexture {
    const gl = this.gl;
    const t = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  }

  private u(name: string) {
    if (!this.loc.has(name)) this.loc.set(name, this.gl.getUniformLocation(this.program, name));
    return this.loc.get(name)!;
  }

  private clearTexture(tex: WebGLTexture, wide: boolean) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, wide ? gl.RGBA16UI : gl.RGBA8, 1, 1, 0,
      wide ? gl.RGBA_INTEGER : gl.RGBA, wide ? gl.UNSIGNED_SHORT : gl.UNSIGNED_BYTE, null);
  }

  /** Top-first display pixels; integer textures preserve exact UNORM16 codes. */
  private upload(tex: WebGLTexture, integer: WebGLTexture, img: RgbaImage | null): boolean {
    const wide = img?.format === 'rgba16';
    this.clearTexture(wide ? tex : integer, !wide);
    if (!img) { this.clearTexture(tex, false); return false; }
    if (img.width > this.maxTexture || img.height > this.maxTexture) return false;
    if (img.data.byteLength !== img.width * img.height * (wide ? 8 : 4)) return false;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, wide ? integer : tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    const bytes = wide && img.data.byteOffset % 2 ? img.data.slice() : img.data;
    gl.texImage2D(gl.TEXTURE_2D, 0, wide ? gl.RGBA16UI : gl.RGBA8, img.width, img.height, 0,
      wide ? gl.RGBA_INTEGER : gl.RGBA, wide ? gl.UNSIGNED_SHORT : gl.UNSIGNED_BYTE,
      wide ? new Uint16Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 2) : bytes);
    return true;
  }

  setImage(img: RgbaImage | null) {
    this.hasImage = this.upload(this.image, this.image16, img);
    this.imageWide = img?.format === 'rgba16';
    this.imageInfo = img;
  }
  setOriginal(img: RgbaImage | null) {
    this.hasOriginal = this.upload(this.original, this.original16, img);
    this.originalWide = img?.format === 'rgba16';
    this.originalSpace = previewSpace(img?.colorSpace);
  }

  private drawingBuffer(width: number, height: number) {
    if (!this.floatCanvas) return;
    const gl = this.gl as WebGL2RenderingContext & {
      drawingBufferStorage(format: number, width: number, height: number): void;
      drawingBufferFormat?: number;
    };
    if (this.bufferSize.width === width && this.bufferSize.height === height && gl.drawingBufferFormat === gl.RGBA16F) return;
    try {
      gl.drawingBufferStorage(gl.RGBA16F, width, height);
      if (gl.getError() !== gl.NO_ERROR || gl.drawingBufferFormat !== gl.RGBA16F) throw new Error('float drawing buffer rejected');
      this.displayPrecision = 'float16'; this.bufferSize = { width, height };
    } catch {
      this.floatCanvas = false; this.displayPrecision = 'unorm8';
      try { gl.drawingBufferStorage(gl.RGBA8, width, height); } catch { /* Keep the browser's default buffer. */ }
    }
  }

  /** A property can exist yet silently reject P3; probe by writing and reading. */
  supportsP3(): boolean {
    const gl = this.gl as WebGL2RenderingContext & { drawingBufferColorSpace: DisplaySpace };
    if (!('drawingBufferColorSpace' in gl)) return false;
    const saved = gl.drawingBufferColorSpace;
    try {
      gl.drawingBufferColorSpace = 'display-p3';
      return gl.drawingBufferColorSpace === 'display-p3';
    } catch { return false; }
    finally { gl.drawingBufferColorSpace = saved; }
  }

  setDisplaySpace(space: DisplaySpace): DisplaySpace {
    const gl = this.gl as WebGL2RenderingContext & { drawingBufferColorSpace: DisplaySpace };
    if (gl.drawingBufferColorSpace === space) return this.displaySpace = space;
    try {
      if ('drawingBufferColorSpace' in gl) gl.drawingBufferColorSpace = space;
      this.displaySpace = gl.drawingBufferColorSpace === 'display-p3' ? 'display-p3' : 'srgb';
    } catch {
      if ('drawingBufferColorSpace' in gl) gl.drawingBufferColorSpace = 'srgb';
      this.displaySpace = 'srgb';
    }
    return this.displaySpace;
  }

  private setCurves(a: Adjustments) {
    const key = JSON.stringify(a.curves);
    if (key === this.curvesKey) return;
    this.curvesKey = key;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.curves);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16F, CURVE_TABLE_SIZE, 5, 0, gl.RED, gl.FLOAT, curveTables(a.curves));
  }

  private setGeometry(prefix: 'g', u: GeometryUniform) {
    const gl = this.gl;
    gl.uniform2f(this.u(prefix + 'Centre'), u.centre[0], u.centre[1]);
    gl.uniform2f(this.u(prefix + 'Half'), u.halfExtent[0], u.halfExtent[1]);
    gl.uniform2f(this.u(prefix + 'CosSin'), u.cosSin[0], u.cosSin[1]);
    gl.uniform2f(this.u(prefix + 'PixelRatio'), u.pixelRatio[0], u.pixelRatio[1]);
    gl.uniform1i(this.u(prefix + 'Turns'), u.quarterTurns);
    gl.uniform1i(this.u(prefix + 'Flips'), u.flips);
    gl.uniform1i(this.u(prefix + 'Active'), u.active ? 1 : 0);
  }

  private bind(s: DrawState, offscreen: boolean) {
    const gl = this.gl;
    gl.useProgram(this.program);
    this.setCurves(s.adjustments);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.image);
    gl.uniform1i(this.u('uImage'), 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.original);
    gl.uniform1i(this.u('uOriginal'), 1);
    gl.activeTexture(gl.TEXTURE2);
    gl.bindTexture(gl.TEXTURE_2D, this.curves);
    gl.uniform1i(this.u('uCurves'), 2);
    gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, this.image16); gl.uniform1i(this.u('uImage16'), 3);
    gl.activeTexture(gl.TEXTURE4); gl.bindTexture(gl.TEXTURE_2D, this.original16); gl.uniform1i(this.u('uOriginal16'), 4);
    gl.uniform1i(this.u('uImageWide'), this.imageWide ? 1 : 0);
    gl.uniform1i(this.u('uOriginalWide'), this.originalWide ? 1 : 0);
    gl.uniform1i(this.u('uHasImage'), this.hasImage ? 1 : 0);
    gl.uniform1i(this.u('uHasOriginal'), this.hasOriginal ? 1 : 0);
    gl.uniform1i(this.u('uImageProcessed'), this.imageInfo?.processedGeometry ? 1 : 0);
    gl.uniformMatrix3fv(this.u('uImageMap'), false, processedImageMap(this.imageInfo?.processedGeometry, s.sourceSize));
    gl.uniform1i(this.u('uImageSpace'), previewSpace(this.imageInfo?.colorSpace) === 'display-p3' ? 1 : 0);
    gl.uniform1i(this.u('uOriginalSpace'), this.originalSpace === 'display-p3' ? 1 : 0);
    gl.uniform1i(this.u('uOutputSpace'), this.displaySpace === 'display-p3' ? 1 : 0);
    gl.uniform2f(this.u('uViewport'), s.viewport.width, s.viewport.height);
    gl.uniform2f(this.u('uOffset'), s.offset.x, s.offset.y);
    gl.uniform2f(this.u('uOutSize'), s.outSize.width, s.outSize.height);
    gl.uniform1i(this.u('uOffscreen'), offscreen ? 1 : 0);
    gl.uniform1f(this.u('uSurround'), s.surround);
    this.setGeometry('g', uniform(s.display, s.sourceSize));
    const crop = s.editingCrop ? uniform(s.editingCrop, s.sourceSize) : uniform(GEOMETRY_DEFAULT, s.sourceSize);
    gl.uniform1i(this.u('uEditingCrop'), s.editingCrop && !offscreen ? 1 : 0);
    gl.uniform2f(this.u('cCentre'), crop.centre[0], crop.centre[1]);
    gl.uniform2f(this.u('cHalf'), crop.halfExtent[0], crop.halfExtent[1]);
    gl.uniform2f(this.u('cCosSin'), crop.cosSin[0], crop.cosSin[1]);
    gl.uniform1i(this.u('uCompare'), offscreen && s.compare !== 2 ? 0 : s.compare);
    gl.uniform1f(this.u('uSplit'), s.split);
    const l = layer2Uniforms(s.adjustments, SRGB_MID_GREY);
    gl.uniform1i(this.u('lEnabled'), l.enabled ? 1 : 0);
    gl.uniform3f(this.u('lWb'), ...l.wbGain);
    gl.uniform1f(this.u('lExposure'), l.exposureGain);
    gl.uniform1f(this.u('lContrast'), l.contrast);
    gl.uniform1f(this.u('lBrightness'), l.brightness);
    gl.uniform1f(this.u('lSaturation'), l.saturation);
    gl.uniform1f(this.u('lHighlights'), l.highlights);
    gl.uniform1f(this.u('lShadows'), l.shadows);
    gl.uniform1f(this.u('lBlack'), l.blackPoint);
    gl.uniform1f(this.u('lWhite'), l.whitePoint);
    gl.uniform3f(this.u('lCbMaster'), ...l.cbMaster);
    gl.uniform3f(this.u('lCbShadows'), ...l.cbShadows);
    gl.uniform3f(this.u('lCbMidtones'), ...l.cbMidtones);
    gl.uniform3f(this.u('lCbHighlights'), ...l.cbHighlights);
    gl.uniform4f(this.u('lCbLum'), ...l.cbLum);
    gl.uniform1f(this.u('lVignetteAmount'), l.vignetteAmount);
    gl.uniform1f(this.u('lVignetteMid'), l.vignetteMidpoint);
    gl.uniform1f(this.u('lMidGrey'), l.midGrey);
    gl.uniform1i(this.u('lCurves'), l.curvesActive ? 1 : 0);
  }

  draw(s: DrawState) {
    const gl = this.gl;
    this.drawingBuffer(s.viewport.width, s.viewport.height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, s.viewport.width, s.viewport.height);
    this.bind(s, false);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  /**
   * The output (geometry + Layer 2, no viewport, no compare) at `width` ×
   * `height`, read back as rgba8 top row first: the navigator's and the
   * histogram's picture.
   */
  renderOutput(s: DrawState, width: number, height: number): Uint8Array | null {
    if (!this.hasImage && !(s.compare === 2 && this.hasOriginal)) return null;
    const gl = this.gl;
    if (!this.fbo || this.fboSize.width !== width || this.fboSize.height !== height) {
      if (this.fbo) gl.deleteFramebuffer(this.fbo);
      if (this.fboTex) gl.deleteTexture(this.fboTex);
      this.fboTex = this.texture(gl.NEAREST);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      this.fbo = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.fboTex, 0);
      this.fboSize = { width, height };
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
    gl.viewport(0, 0, width, height);
    this.bind({ ...s, viewport: { width, height } }, true);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    const out = new Uint8Array(width * height * 4);
    gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, out);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    // GL's rows are bottom-up; the vertex shader's uv is top-down, so row 0
    // of the framebuffer is the output's *bottom*. Flip into top-first.
    const row = width * 4;
    const flipped = new Uint8Array(out.length);
    for (let y = 0; y < height; y++) flipped.set(out.subarray((height - 1 - y) * row, (height - y) * row), y * row);
    return flipped;
  }
}
