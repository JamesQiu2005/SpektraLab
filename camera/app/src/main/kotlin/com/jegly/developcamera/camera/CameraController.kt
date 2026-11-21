package com.jegly.developcamera.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.hardware.camera2.params.TonemapCurve
import com.jegly.developcamera.engine.RawFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.media.ExifInterface
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/** A lens the photographer can pick: a physical camera behind a logical one, or the logical camera itself. */
data class Lens(
    val cameraId: String,          // what openCamera() takes
    val physicalId: String?,       // the lens behind it, or null for the camera itself
    val equivMm: Int,              // 35 mm equivalent focal length
    val front: Boolean,
    val raw: Boolean,
    val aperture: Float,
    val isoMin: Int,
    val isoMax: Int,
    val shutterMinNs: Long,
    val shutterMaxNs: Long,
    val sensorOrientation: Int,
) {
    val label: String get() = if (front) "Selfie" else "$equivMm"
    val apertureLabel: String get() = "ƒ" + "%.1f".format(aperture).removeSuffix(".0")
}

/**
 * One shot as the camera delivered it: the JPEG (sRGB-encoded scene light), and with RAW the DNG and the Bayer
 * frame with Camera2's corrections. [rotation] is how far the picture turns to stand upright (JPEG_ORIENTATION).
 */
class Shot(
    val jpeg: ByteArray,
    val dng: ByteArray?,
    val raw: RawFrame?,
    val timeMillis: Long,
    val lens: Lens,
    val rotation: Int,
) {
    /** The film meter when it was taken: the viewfinder showed (preview linear) x [gain]; [previewMedian] then. */
    var gain = 0f
    var previewMedian = 0f
    /** Exposure compensation (thirds) in Auto, for a picture Develop meters itself (no RAW). */
    var evThirds = 0
}

/**
 * Camera2: the viewfinder stream and stills from the chosen lens. Preview and stills ask for a plain sRGB tone
 * curve (TONEMAP_MODE_CONTRAST_CURVE; the Fold has no preset curves) so frames are encoded scene light, the
 * same light the RAW path gives the engine. All camera work runs on one thread ("camera").
 */
class CameraController(context: Context) {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private val main = Handler(Looper.getMainLooper())

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewSurface: Surface? = null
    private var jpegReader: ImageReader? = null
    private var rawReader: ImageReader? = null
    private var lens: Lens? = null
    private var generation = 0

    /** Applied to the viewfinder at once and to the next shot. */
    @Volatile var exposure = Exposure()
        private set

    /** The back lenses (from the logical back camera's physical cameras), widest first, then the front camera. */
    val lenses: List<Lens> = findLenses()

    private fun findLenses(): List<Lens> {
        val out = mutableListOf<Lens>()
        for (id in manager.cameraIdList) {
            val c = manager.getCameraCharacteristics(id)
            val facing = c.get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                if (out.none { it.front }) out += lensOf(id, null, c, front = true)
                continue
            }
            if (facing != CameraCharacteristics.LENS_FACING_BACK || out.any { !it.front }) continue
            val physical = c.physicalCameraIds
            if (physical.isEmpty()) out += lensOf(id, null, c, front = false)
            else for (p in physical) out += lensOf(id, p, manager.getCameraCharacteristics(p), front = false)
        }
        return out.sortedWith(compareBy<Lens> { it.front }.thenBy { it.equivMm })
    }

    private fun lensOf(id: String, physical: String?, c: CameraCharacteristics, front: Boolean): Lens {
        val f = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: 0f
        val s = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val equiv = if (s == null) 0 else (f * 43.267 / hypot(s.width.toDouble(), s.height.toDouble())).roundToInt()
        val iso = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val exp = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        return Lens(
            cameraId = id, physicalId = physical, equivMm = equiv, front = front,
            raw = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW) == true,
            aperture = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)?.firstOrNull() ?: 0f,
            isoMin = iso?.lower ?: 100, isoMax = iso?.upper ?: 3200,
            shutterMinNs = exp?.lower ?: 100_000L, shutterMaxNs = exp?.upper ?: 1_000_000_000L,
            sensorOrientation = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90,
        )
    }

    private fun chars(lens: Lens) = manager.getCameraCharacteristics(lens.physicalId ?: lens.cameraId)

    private fun largest(lens: Lens, format: Int): Size? =
        chars(lens).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(format)
            ?.maxByOrNull { it.width.toLong() * it.height }

    /** The preview size for a lens: the largest 4:3 size up to 1920 x 1440. */
    fun previewSize(lens: Lens): Size {
        val sizes = chars(lens).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(SurfaceTexture::class.java).orEmpty()
        return sizes.filter { it.width * 3 == it.height * 4 && it.width <= 1920 }
            .maxByOrNull { it.width * it.height } ?: sizes.first()
    }

    /**
     * Opens [lens], streams it into [target] and gets ready for stills (JPEG, and RAW when the lens has it).
     * [onStatus] gets short status lines on the main thread.
     */
    @SuppressLint("MissingPermission")   // the screen only exists once the camera permission is granted
    fun open(target: SurfaceTexture, lens: Lens, exposure: Exposure, onStatus: (String) -> Unit) {
        val gen = ++generation
        this.exposure = exposure
        handler.post {
            closeNow()
            this.lens = lens
            val size = previewSize(lens)
            target.setDefaultBufferSize(size.width, size.height)
            val surface = Surface(target)
            previewSurface = surface
            manager.openCamera(lens.cameraId, executor, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    if (gen != generation) { d.close(); return }
                    device = d
                    startSession(d, surface, lens, gen, withRaw = lens.raw, onStatus)
                }
                override fun onDisconnected(d: CameraDevice) { d.close(); if (device == d) device = null }
                override fun onError(d: CameraDevice, error: Int) {
                    d.close(); if (device == d) device = null
                    main.post { onStatus("camera error $error") }
                }
            })
        }
    }

    private fun startSession(
        d: CameraDevice, surface: Surface, lens: Lens, gen: Int, withRaw: Boolean, onStatus: (String) -> Unit,
    ) {
        jpegReader?.close(); rawReader?.close()
        jpegReader = largest(lens, ImageFormat.JPEG)?.let { ImageReader.newInstance(it.width, it.height, ImageFormat.JPEG, 2) }
        rawReader = if (withRaw) largest(lens, ImageFormat.RAW_SENSOR)
            ?.let { ImageReader.newInstance(it.width, it.height, ImageFormat.RAW_SENSOR, 2) } else null
        val outs = listOfNotNull(surface, jpegReader?.surface, rawReader?.surface).map { s ->
            OutputConfiguration(s).apply { lens.physicalId?.let { setPhysicalCameraId(it) } }
        }
        val config = SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outs, executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    if (gen != generation) { s.close(); return }
                    session = s
                    s.setRepeatingRequest(previewRequest(d, surface, lens), statusCallback(onStatus), handler)
                }
                override fun onConfigureFailed(s: CameraCaptureSession) {
                    if (withRaw) {
                        main.post { onStatus("RAW refused on this lens; JPEG only") }
                        startSession(d, surface, lens, gen, withRaw = false, onStatus)
                    } else {
                        main.post { onStatus("preview refused by the camera") }
                    }
                }
            })
        d.createCaptureSession(config)
    }

    /** Any thread. Applies to the viewfinder now and to the next shot. */
    fun setExposure(e: Exposure) {
        exposure = e
        handler.post {
            val s = session ?: return@post
            val d = device ?: return@post
            val surface = previewSurface ?: return@post
            val l = lens ?: return@post
            s.setRepeatingRequest(previewRequest(d, surface, l), null, handler)
        }
    }

    private fun previewRequest(d: CameraDevice, surface: Surface, lens: Lens): CaptureRequest =
        d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(surface)
            common(this, lens, still = false)
        }.build()

    /** What preview and stills share: focus, white balance, exposure, the plain sRGB curve. */
    private fun common(b: CaptureRequest.Builder, lens: Lens, still: Boolean) {
        val e = exposure
        val logical = manager.getCameraCharacteristics(lens.cameraId)
        b.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
        b.set(CaptureRequest.CONTROL_AWB_MODE, e.wb.awbMode)
        if (!e.manual) {
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            b.set(CaptureRequest.CONTROL_AE_LOCK, e.aeLock)
            val step = logical.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toDouble() ?: (1.0 / 3)
            val range = logical.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            var steps = ((e.evThirds / 3.0) / step).roundToInt()
            if (range != null) steps = steps.coerceIn(range.lower, range.upper)
            b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, steps)
        } else {
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            var t = e.shutterNs.coerceIn(lens.shutterMinNs, lens.shutterMaxNs)
            var iso = e.iso.coerceIn(lens.isoMin, lens.isoMax)
            if (!still && t > PREVIEW_MAX_NS) {
                // Keep the viewfinder live on long exposures: shorter time, more gain, same brightness.
                iso = (iso * (t.toDouble() / PREVIEW_MAX_NS)).roundToInt().coerceIn(lens.isoMin, lens.isoMax)
                t = PREVIEW_MAX_NS
            }
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, t)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, iso)
            b.set(CaptureRequest.SENSOR_FRAME_DURATION, max(t, 33_333_333L))
        }
        // The plain sRGB curve for the viewfinder only. Full-size stills are processed in two parts by the Pixel's ISP
        // and only one got the curve (a split picture, 2026-11-21); stills develop from RAW, so they keep the camera's
        // own processing for the JPEG.
        val modes = logical.get(CameraCharacteristics.TONEMAP_AVAILABLE_TONE_MAP_MODES)
        if (!still && modes?.contains(CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE) == true) {
            val points = (logical.get(CameraCharacteristics.TONEMAP_MAX_CURVE_POINTS) ?: 32).coerceIn(2, 64)
            val curve = srgbCurve(points)
            b.set(CaptureRequest.TONEMAP_MODE, CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE)
            b.set(CaptureRequest.TONEMAP_CURVE, TonemapCurve(curve, curve, curve))
        }
    }

    private fun statusCallback(onStatus: (String) -> Unit) = object : CameraCaptureSession.CaptureCallback() {
        private var reported = false
        override fun onCaptureCompleted(s: CameraCaptureSession, r: CaptureRequest, result: TotalCaptureResult) {
            if (reported) return
            reported = true
            val text = when (val mode = result.get(CaptureResult.TONEMAP_MODE)) {
                CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE -> "plain sRGB preview: yes"
                null -> "plain sRGB preview: not reported"
                else -> "plain sRGB preview: no (mode $mode)"
            }
            main.post { onStatus(text) }
        }
    }

    /**
     * Takes one shot: JPEG, plus a DNG when [withRaw] and the session has RAW. [deviceDegrees] is how the phone
     * is held (0, 90, 180, 270, clockwise from upright), for the photo's orientation. Callbacks on the main thread.
     */
    fun capture(withRaw: Boolean, deviceDegrees: Int, onShot: (Shot) -> Unit, onError: (String) -> Unit) {
        handler.post {
            val s = session; val d = device; val l = lens; val jr = jpegReader
            if (s == null || d == null || l == null || jr == null) { main.post { onError("Camera not ready") }; return@post }
            val rr = if (withRaw) rawReader else null
            val rotation = jpegOrientation(l, deviceDegrees)
            var result: TotalCaptureResult? = null
            var jpeg: ByteArray? = null
            var raw: Image? = null
            var finished = false
            fun finish() {
                if (finished || result == null || jpeg == null || (rr != null && raw == null)) return
                finished = true
                jr.setOnImageAvailableListener(null, null); rr?.setOnImageAvailableListener(null, null)
                val r: CaptureResult = l.physicalId?.let { result!!.physicalCameraTotalResults[it] } ?: result!!
                var frame: RawFrame? = null
                val dng = raw?.let { image ->
                    try {
                        frame = rawFrame(image, chars(l), r)
                        ByteArrayOutputStream(image.width * image.height * 2 + 65536).use { os ->
                            DngCreator(chars(l), r).use { dc ->
                                dc.setOrientation(exifOrientation(rotation))
                                dc.writeImage(os, image)
                            }
                            os.toByteArray()
                        }
                    } catch (t: Exception) {
                        main.post { onError("RAW not kept: ${t.message}") }
                        null
                    } finally {
                        image.close()
                    }
                }
                val shot = Shot(jpeg!!, dng, frame, System.currentTimeMillis(), l, rotation)
                main.post { onShot(shot) }
            }
            jr.setOnImageAvailableListener({ r ->
                r.acquireNextImage()?.use { im ->
                    val b = im.planes[0].buffer
                    jpeg = ByteArray(b.remaining()).also { b.get(it) }
                }
                finish()
            }, handler)
            rr?.setOnImageAvailableListener({ r -> raw = r.acquireNextImage(); finish() }, handler)
            val request = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(jr.surface)
                rr?.let { addTarget(it.surface) }
                common(this, l, still = true)
                set(CaptureRequest.JPEG_ORIENTATION, rotation)
                set(CaptureRequest.JPEG_QUALITY, 100.toByte())
                // The lens shading map for this frame, for developing the RAW (Camera2 RAW devices support it).
                if (rr != null) set(CaptureRequest.STATISTICS_LENS_SHADING_MAP_MODE, CameraMetadata.STATISTICS_LENS_SHADING_MAP_MODE_ON)
            }.build()
            s.capture(request, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(cs: CameraCaptureSession, r: CaptureRequest, res: TotalCaptureResult) {
                    result = res; finish()
                }
                override fun onCaptureFailed(cs: CameraCaptureSession, r: CaptureRequest, f: CaptureFailure) {
                    finished = true
                    raw?.close()
                    main.post { onError("Shot failed (reason ${f.reason})") }
                }
            }, handler)
        }
    }

    /** The Bayer data and this frame's corrections, copied out before the Image is closed. */
    private fun rawFrame(image: Image, c: CameraCharacteristics, r: CaptureResult): RawFrame {
        val plane = image.planes[0]
        val src = plane.buffer
        val data = ByteBuffer.allocateDirect(src.remaining()).order(ByteOrder.nativeOrder())
        data.put(src.duplicate()); data.rewind()
        val black = r.get(CaptureResult.SENSOR_DYNAMIC_BLACK_LEVEL)?.takeIf { it.size == 4 }
            ?: c.get(CameraCharacteristics.SENSOR_BLACK_LEVEL_PATTERN)?.let { p ->
                floatArrayOf(p.getOffsetForIndex(0, 0).toFloat(), p.getOffsetForIndex(1, 0).toFloat(),
                    p.getOffsetForIndex(0, 1).toFloat(), p.getOffsetForIndex(1, 1).toFloat())
            } ?: floatArrayOf(64f, 64f, 64f, 64f)
        val white = (r.get(CaptureResult.SENSOR_DYNAMIC_WHITE_LEVEL) ?: c.get(CameraCharacteristics.SENSOR_INFO_WHITE_LEVEL) ?: 1023).toFloat()
        val neutral = r.get(CaptureResult.SENSOR_NEUTRAL_COLOR_POINT)?.map { it.toFloat() }?.toFloatArray()
            ?: floatArrayOf(1f, 1f, 1f)
        val fm = c.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX2) ?: c.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX1)
        val forward = FloatArray(9).also { f ->
            if (fm == null) { f[0] = 0.4361f; f[1] = 0.3851f; f[2] = 0.1431f; f[3] = 0.2225f; f[4] = 0.7169f; f[5] = 0.0606f; f[6] = 0.0139f; f[7] = 0.0971f; f[8] = 0.7141f }
            else for (i in 0 until 9) f[i] = fm.getElement(i % 3, i / 3).toFloat()
        }
        val map = r.get(CaptureResult.STATISTICS_LENS_SHADING_CORRECTION_MAP)
        val shading = map?.let { FloatArray(it.gainFactorCount).also { a -> it.copyGainFactors(a, 0) } } ?: FloatArray(0)
        return RawFrame(
            data = data, width = image.width, height = image.height, rowStride = plane.rowStride,
            cfa = c.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT) ?: 0,
            black = black, white = white, neutral = neutral, forward = forward,
            shading = shading, shadingW = map?.columnCount ?: 0, shadingH = map?.rowCount ?: 0,
            distortion = c.get(CameraCharacteristics.LENS_DISTORTION)?.takeIf { it.size == 5 },
            intrinsics = c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)?.takeIf { it.size == 5 },
        )
    }

    fun close() {
        ++generation
        handler.post { closeNow() }
    }

    private fun closeNow() {
        session?.close(); session = null
        device?.close(); device = null
        jpegReader?.close(); jpegReader = null
        rawReader?.close(); rawReader = null
        previewSurface?.release(); previewSurface = null
    }

    fun release() {
        close()
        thread.quitSafely()
    }

    private companion object {
        /** The longest exposure the viewfinder uses (1/15 s); longer manual shutters are matched with gain. */
        const val PREVIEW_MAX_NS = 66_666_667L

        /** Camera2's rule: sensor orientation plus how the phone is held (minus, for a front camera). */
        fun jpegOrientation(lens: Lens, deviceDegrees: Int): Int {
            val d = ((deviceDegrees + 45) / 90 * 90) % 360
            return ((lens.sensorOrientation + (if (lens.front) -d else d)) + 360) % 360
        }

        fun exifOrientation(degrees: Int) = when (degrees) {
            90 -> ExifInterface.ORIENTATION_ROTATE_90
            180 -> ExifInterface.ORIENTATION_ROTATE_180
            270 -> ExifInterface.ORIENTATION_ROTATE_270
            else -> ExifInterface.ORIENTATION_NORMAL
        }

        /** The sRGB encoding as (in, out) pairs, denser near black where the curve bends most. */
        fun srgbCurve(points: Int): FloatArray {
            val out = FloatArray(points * 2)
            for (i in 0 until points) {
                val t = i / (points - 1f)
                val x = t * t
                val y = if (x <= 0.0031308f) 12.92f * x else 1.055f * x.toDouble().pow(1 / 2.4).toFloat() - 0.055f
                out[2 * i] = x
                out[2 * i + 1] = y.coerceIn(0f, 1f)
            }
            return out
        }
    }
}
