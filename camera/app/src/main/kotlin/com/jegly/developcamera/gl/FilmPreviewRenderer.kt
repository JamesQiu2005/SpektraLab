package com.jegly.developcamera.gl

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import com.jegly.developcamera.film.FilmLut
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * The viewfinder: camera frames (an external OES texture, sRGB-encoded scene light) through the film's baked
 * 3D LUT. The LUT is Develop's engine output for each colour, so this is the developed picture minus what
 * spreads light (grain, halation, diffusion), which the engine adds to the real shot.
 *
 * Also: the display's rotation (so the picture stays upright on every screen of the Fold), focus peaking, and a
 * small luminance histogram read back every few frames.
 *
 * No constant arrays indexed at runtime in the shaders: the Fold's PowerVR driver skips such shaders
 * (found in Develop's lens kernels, 2026-11-20).
 */
class FilmPreviewRenderer(
    private val onSurfaceTexture: (SurfaceTexture) -> Unit,
    private val requestRender: () -> Unit,
) : GLSurfaceView.Renderer {

    @Volatile private var pendingLut: FilmLut? = null
    @Volatile private var lutChanged = false
    @Volatile var mirror = false
    /** The display's rotation in quarter turns (Display.getRotation()). */
    @Volatile var quarterTurns = 0
    @Volatile var peaking = false
    /** The film meter's gain on the camera's linear light (1 = as the camera exposed). */
    @Volatile var gain = 1f
    /** Viewfinder grain: amplitude (0 = none) and whether the film is black and white. */
    @Volatile var grain = 0f
    @Volatile var monoGrain = false
    /** Viewfinder grain clump size in screen pixels (coarser grain sizes are larger). */
    @Volatile var grainCell = 1f
    /**
     * Called on the GL thread every few frames: the camera picture's median luminance (linear, before the film
     * and the gain) and a 32-bin histogram of what the film is given (summing to 1).
     */
    @Volatile var onMeter: ((Float, FloatArray) -> Unit)? = null
    @Volatile var bufferWidth = 1440
    @Volatile var bufferHeight = 1080

    private var program = 0
    private var cameraTex = 0
    private var lutTex = 0
    private var lutSize = 0f
    private var surfaceTexture: SurfaceTexture? = null
    private val texMatrix = FloatArray(16)
    private var viewW = 1
    private var viewH = 1
    private var frame = 0
    private var histFbo = 0
    private var histTex = 0
    private val histPixels = ByteBuffer.allocateDirect(HIST_W * HIST_H * 4).order(ByteOrder.nativeOrder())

    /** Any thread. null shows the camera's picture as it is. */
    fun setLut(lut: FilmLut?) {
        pendingLut = lut
        lutChanged = true
        requestRender()
    }

    override fun onSurfaceCreated(unused: GL10?, config: EGLConfig?) {
        program = link(VERTEX, FRAGMENT)
        val ids = IntArray(3)
        GLES30.glGenTextures(3, ids, 0)
        cameraTex = ids[0]; lutTex = ids[1]; histTex = ids[2]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTex)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTex)
        for (p in intArrayOf(GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_TEXTURE_WRAP_R)) {
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, p, GLES30.GL_CLAMP_TO_EDGE)
        }
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        // A small target the histogram is read from.
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, histTex)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, HIST_W, HIST_H, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        val fbo = IntArray(1)
        GLES30.glGenFramebuffers(1, fbo, 0)
        histFbo = fbo[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, histFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, histTex, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        lutSize = 0f
        lutChanged = pendingLut != null
        surfaceTexture?.release()
        val st = SurfaceTexture(cameraTex)
        st.setOnFrameAvailableListener { requestRender() }
        surfaceTexture = st
        onSurfaceTexture(st)
    }

    override fun onSurfaceChanged(unused: GL10?, width: Int, height: Int) {
        viewW = width; viewH = height
        GLES30.glViewport(0, 0, width, height)
    }

    override fun onDrawFrame(unused: GL10?) {
        val st = surfaceTexture ?: return
        st.updateTexImage()
        st.getTransformMatrix(texMatrix)
        if (lutChanged) {
            lutChanged = false
            val lut = pendingLut
            if (lut == null) {
                lutSize = 0f
            } else {
                lut.rgb.position(0)
                GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTex)
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 2)
                GLES30.glTexImage3D(GLES30.GL_TEXTURE_3D, 0, GLES30.GL_RGB16F, lut.size, lut.size, lut.size, 0,
                    GLES30.GL_RGB, GLES30.GL_HALF_FLOAT, lut.rgb)
                lutSize = lut.size.toFloat()
            }
        }
        draw(meter = false)
        val meter = onMeter
        if (meter != null && (frame++ % 4) == 0) {
            // The camera's own picture, small, before the film: the film meter and the histogram read it.
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, histFbo)
            GLES30.glViewport(0, 0, HIST_W, HIST_H)
            draw(meter = true)
            histPixels.position(0)
            GLES30.glReadPixels(0, 0, HIST_W, HIST_H, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, histPixels)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            GLES30.glViewport(0, 0, viewW, viewH)
            val n = HIST_W * HIST_H
            val lum = FloatArray(n)
            val bins = FloatArray(32)
            val g = gain
            for (i in 0 until n) {
                val y = 0.2126f * LINEAR[histPixels.get(4 * i).toInt() and 255] +
                    0.7152f * LINEAR[histPixels.get(4 * i + 1).toInt() and 255] +
                    0.0722f * LINEAR[histPixels.get(4 * i + 2).toInt() and 255]
                lum[i] = y
                val shown = encode((y * g).coerceIn(0f, 1f))
                bins[(shown * 31.99f).toInt().coerceIn(0, 31)] += 1f / n
            }
            lum.sort()
            meter(lum[n / 2], bins)
        }
    }

    private fun draw(meter: Boolean) {
        val withPeaking = !meter && peaking
        GLES30.glUseProgram(program)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTex)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uCamera"), 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTex)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uLut"), 1)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uLutSize"), lutSize)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uUseLut"), if (lutSize > 0f) 1f else 0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uMirror"), if (mirror) 1f else 0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uPeaking"), if (withPeaking) 1f else 0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uMeter"), if (meter) 1f else 0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uGain"), gain)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uGrain"), if (meter) 0f else grain)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uMono"), if (monoGrain) 1f else 0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uGrainCell"), grainCell)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "uSeed"), (frame % 97).toFloat() * 7.31f)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "uTexel"), 1f / bufferWidth, 1f / bufferHeight)
        // Turn the picture back by the display's rotation (quarter turns are exact).
        val q = ((quarterTurns % 4) + 4) % 4
        val c = floatArrayOf(1f, 0f, -1f, 0f)[q]
        val s = floatArrayOf(0f, 1f, 0f, -1f)[q]
        GLES30.glUniformMatrix2fv(GLES30.glGetUniformLocation(program, "uTurn"), 1, false, floatArrayOf(c, s, -s, c), 0)
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(program, "uTexMatrix"), 1, false, texMatrix, 0)
        val aPos = GLES30.glGetAttribLocation(program, "aPos")
        GLES30.glEnableVertexAttribArray(aPos)
        GLES30.glVertexAttribPointer(aPos, 2, GLES30.GL_FLOAT, false, 0, QUAD)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glDisableVertexAttribArray(aPos)
    }

    private companion object {
        const val HIST_W = 48
        const val HIST_H = 64

        val LINEAR = FloatArray(256) { i ->
            val v = i / 255f
            if (v <= 0.04045f) v / 12.92f else Math.pow(((v + 0.055f) / 1.055f).toDouble(), 2.4).toFloat()
        }

        fun encode(v: Float): Float = if (v <= 0.0031308f) 12.92f * v else (1.055 * Math.pow(v.toDouble(), 1 / 2.4) - 0.055).toFloat()

        val QUAD = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0)
        }

        const val VERTEX = """#version 300 es
in vec2 aPos;
uniform mat4 uTexMatrix;
uniform mat2 uTurn;
uniform float uMirror;
out vec2 vTex;
void main() {
    vec2 uv = aPos * 0.5 + 0.5;
    if (uMirror > 0.5) uv.x = 1.0 - uv.x;
    uv = uTurn * (uv - 0.5) + 0.5;
    vTex = (uTexMatrix * vec4(uv, 0.0, 1.0)).xy;
    gl_Position = vec4(aPos, 0.0, 1.0);
}"""

        // The LUT is sampled at texel centres: input 0 -> 0.5 / N, input 1 -> (N - 0.5) / N. Peaking: a Sobel
        // edge measure on the camera's luminance, written out sample by sample (no arrays).
        const val FRAGMENT = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp sampler3D;
uniform samplerExternalOES uCamera;
uniform sampler3D uLut;
uniform float uLutSize;
uniform float uUseLut;
uniform float uPeaking;
uniform float uMeter;
uniform float uGain;
uniform float uGrain;
uniform float uMono;
uniform float uGrainCell;
uniform float uSeed;
uniform vec2 uTexel;
in vec2 vTex;
out vec4 fragColor;
float lum(vec2 o) { return dot(texture(uCamera, vTex + o * uTexel).rgb, vec3(0.2126, 0.7152, 0.0722)); }
vec3 decode(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
vec3 encode(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c)); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void main() {
    vec3 c = clamp(texture(uCamera, vTex).rgb, 0.0, 1.0);
    if (uMeter > 0.5) { fragColor = vec4(c, 1.0); return; }
    // The film meter: the camera's light scaled in linear, as the developed picture will be.
    c = encode(clamp(decode(c) * uGain, 0.0, 1.0));
    if (uUseLut > 0.5) {
        vec3 coord = c * ((uLutSize - 1.0) / uLutSize) + 0.5 / uLutSize;
        c = texture(uLut, coord).rgb;
    }
    if (uPeaking > 0.5) {
        float tl = lum(vec2(-1.0, -1.0)); float t = lum(vec2(0.0, -1.0)); float tr = lum(vec2(1.0, -1.0));
        float l = lum(vec2(-1.0, 0.0)); float r = lum(vec2(1.0, 0.0));
        float bl = lum(vec2(-1.0, 1.0)); float b = lum(vec2(0.0, 1.0)); float br = lum(vec2(1.0, 1.0));
        float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
        float gy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
        float edge = smoothstep(0.35, 0.6, sqrt(gx * gx + gy * gy));
        c = mix(c, vec3(0.851, 0.643, 0.231), edge);
    }
    if (uGrain > 0.0) {
        // A preview of the film's grain: strongest in the midtones, fresh every frame; the engine makes the real one.
        vec2 q = floor(gl_FragCoord.xy / uGrainCell) + uSeed;
        float n = hash(q) + hash(q + 17.0) - 1.0;
        float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float a = uGrain * (0.3 + 2.8 * l * (1.0 - l));
        vec3 g = vec3(n);
        if (uMono < 0.5) g += 0.2 * vec3(hash(q + 3.1) - 0.5, hash(q + 5.7) - 0.5, hash(q + 9.3) - 0.5);
        c = clamp(c + g * a, 0.0, 1.0);
    }
    fragColor = vec4(c, 1.0);
}"""

        fun compile(type: Int, src: String): Int {
            val s = GLES30.glCreateShader(type)
            GLES30.glShaderSource(s, src)
            GLES30.glCompileShader(s)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: " + GLES30.glGetShaderInfoLog(s) }
            return s
        }

        fun link(vs: String, fs: String): Int {
            val p = GLES30.glCreateProgram()
            GLES30.glAttachShader(p, compile(GLES30.GL_VERTEX_SHADER, vs))
            GLES30.glAttachShader(p, compile(GLES30.GL_FRAGMENT_SHADER, fs))
            GLES30.glLinkProgram(p)
            val ok = IntArray(1)
            GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
            check(ok[0] != 0) { "program: " + GLES30.glGetProgramInfoLog(p) }
            return p
        }
    }
}
