package com.jegly.developcamera.engine

import android.content.Context
import android.graphics.Bitmap
import com.jegly.developcamera.develop.DevelopSettings
import com.jegly.developcamera.develop.Format
import com.jegly.developcamera.develop.Leak
import com.jegly.developcamera.develop.pushGamma
import com.jegly.developcamera.film.Film
import kotlinx.coroutines.asCoroutineDispatcher
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.sqrt
import kotlin.random.Random

/** One RAW frame as Camera2 delivered it, with Camera2's own corrections for that frame. */
class RawFrame(
    val data: ByteBuffer,          // direct, uint16 Bayer samples
    val width: Int,
    val height: Int,
    val rowStride: Int,            // bytes
    val cfa: Int,                  // SENSOR_INFO_COLOR_FILTER_ARRANGEMENT
    val black: FloatArray,         // 4, 2x2 position order (row * 2 + column)
    val white: Float,
    val neutral: FloatArray,       // 3, as-shot camera neutral
    val forward: FloatArray,       // 9, white-balanced camera RGB -> XYZ D50
    val shading: FloatArray,       // gw x gh x 4 (R, G even, G odd, B), or empty
    val shadingW: Int,
    val shadingH: Int,
    val distortion: FloatArray?,   // k1 k2 k3 p1 p2
    val intrinsics: FloatArray?,   // fx fy cx cy s
)

/**
 * Develop's engine (GPL-3.0-or-later; app/src/main/cpp/develop) on the phone's GPU through Vulkan. One engine
 * for the app's life, used only from [dispatcher]'s single thread.
 */
object DevelopEngine {
    /** Every engine call runs here, one at a time. */
    val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "develop-engine") }.asCoroutineDispatcher()

    /** The Fold's PowerVR refuses GPU buffers over 128 MiB: one 3-channel float plane, so at most this many pixels. */
    const val MAX_PIXELS = 134_217_728L / 12

    private var handle = 0L
    private var failure: String? = null
    private val library by lazy { System.loadLibrary("developcamera") }

    /** Extracts the engine's files and starts it, if not yet done. Call on [dispatcher]. */
    fun start(context: Context): Long {
        if (handle != 0L) return handle
        failure?.let { error(it) }
        val dir = EngineFiles.extract(context)
        library
        handle = nativeCreate(dir.absolutePath)
        if (handle == 0L) {
            failure = "Develop's engine could not start on this phone"
            error(failure!!)
        }
        return handle
    }

    /** The largest picture the GPU takes for these settings (a film edge makes the canvas larger). */
    fun pixelLimit(s: DevelopSettings): Long =
        if (!s.filmEdge) MAX_PIXELS else (MAX_PIXELS / if (s.format.medium) 1.35 else 1.6).toLong()

    /** Develops [input] (sRGB-encoded scene light). Call on [dispatcher]. Scales down and retries if the GPU refuses. */
    fun developBitmap(context: Context, input: Bitmap, params: String): Bitmap {
        val h = start(context)
        var src = input
        repeat(3) { attempt ->
            try {
                return nativeDevelopBitmap(h, src, params)
            } catch (e: RuntimeException) {
                if (attempt == 2 || e.message?.contains("maxStorageBufferRange") != true) throw e
                val smaller = Bitmap.createScaledBitmap(src, (src.width * 0.8).toInt(), (src.height * 0.8).toInt(), true)
                if (src !== input) src.recycle()
                src = smaller
            }
        }
        error("unreachable")
    }

    /**
     * Develops a RAW frame (see native-lib.cpp), metered as the viewfinder showed it: [gain] and [previewMedian]
     * are the film meter at the shot. Call on [dispatcher].
     */
    fun developRaw(context: Context, raw: RawFrame, cropAspect: Double, limit: Long, gain: Float, previewMedian: Float,
                   params: String): Bitmap {
        val h = start(context)
        var max = limit
        repeat(3) { attempt ->
            try {
                return nativeDevelopRaw(
                    h, raw.data, raw.width, raw.height, raw.rowStride, raw.cfa, raw.black, raw.white, raw.neutral,
                    raw.forward, raw.shading, raw.shadingW, raw.shadingH, raw.distortion, raw.intrinsics,
                    cropAspect.toFloat(), max.toInt(), gain, previewMedian, params,
                )
            } catch (e: RuntimeException) {
                if (attempt == 2 || e.message?.contains("maxStorageBufferRange") != true) throw e
                max = (max * 0.64).toLong()
            }
        }
        error("unreachable")
    }

    /** A RAW frame as an sRGB picture, metered and straightened, without film (any thread). */
    fun rawToBitmap(raw: RawFrame, gain: Float, previewMedian: Float): Bitmap {
        library
        return nativeRawToBitmap(
            raw.data, raw.width, raw.height, raw.rowStride, raw.cfa, raw.black, raw.white, raw.neutral, raw.forward,
            raw.shading, raw.shadingW, raw.shadingH, raw.distortion, raw.intrinsics, 0f, Int.MAX_VALUE, gain, previewMedian,
        )
    }

    /**
     * Develop's parameters for [film] with the Develop sheet's settings. A negative is printed on its paper (or
     * the one chosen; black and white on Multigrade with its grade-2 pack), a slide is scanned. Exposure is as
     * shot (no auto exposure). The film edge needs the picture cut to the gate's shape first (the engine refuses
     * otherwise); PhotoSaver crops every format to it.
     */
    fun params(film: Film, s: DevelopSettings, rawInput: Boolean, frameNumber: Int, taken: Long,
               engineMeter: Boolean = false, evThirds: Int = 0): String =
        JSONObject().apply {
            put("product_defaults", true)
            if (rawInput) {
                put("input_color_space", "ProPhoto RGB"); put("input_cctf_decoding", false)
            } else {
                put("input_color_space", "sRGB"); put("input_cctf_decoding", true)
            }
            put("output_color_space", "sRGB"); put("output_cctf_encoding", true)
            put("film_stock", film.id)
            // Exposure: the app's film meter has already set it (RAW and RAW-made frames). Only a picture from the
            // camera's JPEG (no RAW on that lens) is metered by Develop itself, its default "balanced" meter.
            put("auto_exposure", engineMeter)
            if (engineMeter) put("auto_exposure_method", "balanced")
            // Push/pull: the camera already exposed for the pushed speed (manual ISO follows it) and the lab prints
            // to normal brightness, so exposure stays; development contrast changes about the midtones (tested:
            // density_curve_gamma keeps the mean), and pushed film is grainier.
            put("exposure_compensation_ev", if (engineMeter) evThirds / 3.0 else 0.0)
            put("density_curve_gamma", pushGamma(s.push))
            put("film_format_mm", s.format.filmMm * s.grainSize.factor)   // grain size (Settings.kt GrainSize)
            val grain = s.grain * (if (s.push > 0) 1.0 + 0.2 * s.push else 1.0)
            put("grain_active", grain > 0.0); put("grain_amount", grain.coerceIn(0.0, 2.0))
            put("halation_active", s.halation > 0.0); put("halation_amount", s.halation.coerceIn(0.0, 4.0))
            val d = s.diffusion
            put("diffusion_filter_active", d != null)
            if (d != null) { put("diffusion_filter_family", d.id); put("diffusion_filter_strength", s.diffusionStrength) }
            if (film.print == null) {
                put("scan_film", true)
            } else {
                val paper = paperFor(film, s.paper)
                put("scan_film", false)
                put("print_stock", paper)
                if (paper == "ilford_multigrade_iv_rc") film.pack?.let { (m, y, e) ->
                    put("c_filter_neutral", 0.0); put("m_filter_neutral", m); put("y_filter_neutral", y); put("print_exposure", e)
                }
            }
            // A colour filter on the lens, for black-and-white film.
            if (film.kind.startsWith("b&w")) s.bwFilter?.let { put("camera_filter", it.id) }
            // A lens character (Develop's presets).
            put("lens_aberrations_active", s.lens != null)
            s.lens?.wire()?.forEach { (k, v) -> put(k, v) }
            put("leak_kind", s.leak.id)
            if (s.leak != Leak.OFF) { put("leak_amount", 1.0); put("leak_seed", Random.nextInt(1, Int.MAX_VALUE)) }
            put("overscan_format", s.format.overscan)
            put("overscan_active", s.filmEdge)
            if (s.filmEdge) {
                put("overscan_pair", s.format == Format.HALF_PAIR)
                put("overscan_frame_number", frameNumber.coerceIn(0, 99))
                put("overscan_camera_seed", 20261121)
                put("overscan_frame_seed", Random.nextInt(1, Int.MAX_VALUE))
            }
            put("date_imprint_active", s.dateBack)
            if (s.dateBack) put("date_imprint_text", SimpleDateFormat("''yy M d", Locale.ROOT).format(Date(taken)))
        }.toString()

    /** The paper a negative is printed on: the chosen one if it suits the film, else the film's own. */
    fun paperFor(film: Film, chosen: String?): String {
        val own = film.print ?: return ""
        if (chosen == null) return own
        val bw = film.kind.startsWith("b&w")
        val chosenBw = chosen == "ilford_multigrade_iv_rc"
        return if (bw == chosenBw) chosen else own
    }

    /** The target size for [w] x [h] under [limit] pixels. */
    fun fit(w: Int, h: Int, limit: Long): Pair<Int, Int> {
        val px = w.toLong() * h
        if (px <= limit) return w to h
        val s = sqrt(limit.toDouble() / px) * 0.999
        return (w * s).toInt() to (h * s).toInt()
    }

    private external fun nativeCreate(resources: String): Long
    private external fun nativeDestroy(engine: Long)
    private external fun nativeCapabilities(engine: Long): String
    private external fun nativeDevelopBitmap(engine: Long, input: Bitmap, params: String): Bitmap
    private external fun nativeDevelopRaw(
        engine: Long, raw: ByteBuffer, w: Int, h: Int, rowStride: Int, cfa: Int, black: FloatArray, white: Float,
        neutral: FloatArray, forward: FloatArray, shading: FloatArray, gw: Int, gh: Int, distortion: FloatArray?,
        intrinsics: FloatArray?, cropAspect: Float, maxPixels: Int, gain: Float, previewMedian: Float, params: String,
    ): Bitmap
    private external fun nativeRawToBitmap(
        raw: ByteBuffer, w: Int, h: Int, rowStride: Int, cfa: Int, black: FloatArray, white: Float, neutral: FloatArray,
        forward: FloatArray, shading: FloatArray, gw: Int, gh: Int, distortion: FloatArray?, intrinsics: FloatArray?,
        cropAspect: Float, maxPixels: Int, gain: Float, previewMedian: Float,
    ): Bitmap
}

/** The engine reads its resources from files (it maps them), so they are copied out of the APK once per version. */
private object EngineFiles {
    fun extract(context: Context): File {
        val dir = File(context.filesDir, "engine")
        val want = context.assets.open("engine/STAMP").use { it.readBytes().decodeToString().trim() }
        val have = File(dir, "STAMP").takeIf { it.exists() }?.readText()?.trim()
        if (have == want) return dir
        dir.deleteRecursively()
        copy(context, "engine", dir)
        return dir
    }

    private fun copy(context: Context, asset: String, to: File) {
        val children = context.assets.list(asset).orEmpty()
        if (children.isEmpty()) {
            to.parentFile?.mkdirs()
            context.assets.open(asset).use { input -> to.outputStream().use { input.copyTo(it) } }
        } else {
            to.mkdirs()
            for (c in children) copy(context, "$asset/$c", File(to, c))
        }
    }
}
