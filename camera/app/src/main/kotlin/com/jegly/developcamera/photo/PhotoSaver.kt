package com.jegly.developcamera.photo

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.jegly.developcamera.camera.Shot
import com.jegly.developcamera.develop.DevelopSettings
import com.jegly.developcamera.develop.Format
import com.jegly.developcamera.engine.DevelopEngine
import com.jegly.developcamera.film.Film
import com.jegly.developcamera.film.LutLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** A saved photo: its MediaStore uri (the JPEG) and a small thumbnail for the camera screen. */
class SavedPhoto(val uri: Uri, val thumbnail: ImageBitmap)

/**
 * Saves pictures to DCIM/Develop Camera through MediaStore (no storage permission; every gallery sees them).
 *
 * A picture is one or more shots (a half-frame pair, a triptych, a multiple exposure), laid out on the sensor's
 * frame as on a film camera. Every frame is made from the RAW data when the lens has RAW (metered by the app's film
 * meter, as the viewfinder showed it), else from the camera's JPEG. [save] is instant: the film's LUT on the CPU.
 * [develop] then runs Develop's engine and replaces that JPEG in place. DNGs are kept when asked for, as the camera
 * wrote them. No location is ever written.
 */
object PhotoSaver {
    const val FOLDER = "DCIM/Develop Camera"
    const val SOFTWARE_DEVELOPED = "Develop Camera (developed)"
    const val SOFTWARE_QUICK = "Develop Camera (quick)"

    /** The frame's aspect (long/short along the sensor's long side) for shot [index] of a picture. */
    fun slotAspect(s: DevelopSettings, index: Int): Double = when (s.format) {
        Format.HALF_PAIR -> 0.75                         // an 18 x 24 mm half frame, upright in the body
        Format.TRIPTYCH -> if (index < 2) 1.5 else 3.0    // two frames above a long one
        else -> s.format.aspect
    }

    suspend fun save(context: Context, shots: List<Shot>, film: Film, s: DevelopSettings, keepDng: Boolean): SavedPhoto =
        withContext(Dispatchers.Default) {
            val first = shots.first()
            val base = "DC_" + SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.ROOT).format(Date(first.timeMillis))
            val original = ExifInterface(ByteArrayInputStream(first.jpeg))
            val picture = compose(shots, s)
            val (n, lut) = LutLoader.loadFloats(context.assets, film)
            val px = IntArray(picture.width * picture.height)
            picture.getPixels(px, 0, picture.width, 0, 0, picture.width, picture.height)
            coroutineScope {
                val parts = max(1, Runtime.getRuntime().availableProcessors())
                val chunk = (px.size + parts - 1) / parts
                (0 until parts).map { k -> async { applyLut(px, k * chunk, min(px.size, (k + 1) * chunk), lut, n) } }.awaitAll()
            }
            picture.setPixels(px, 0, picture.width, 0, 0, picture.width, picture.height)
            val encoded = encode(picture)
            val uri = write(context, "$base.jpg", "image/jpeg", encoded, first.timeMillis) {
                writeExif(context, it, original, film, first.rotation, developed = false)
            }
            if (keepDng) shots.forEachIndexed { i, shot ->
                val name = if (shots.size == 1) "$base.dng" else "${base}_${i + 1}.dng"
                shot.dng?.let { write(context, name, "image/x-adobe-dng", it, shot.timeMillis) {} }
            }
            SavedPhoto(uri, thumbnail(picture, first.rotation).asImageBitmap()).also { picture.recycle() }
        }

    /**
     * Develops the picture with Develop's engine and puts it in place of the quick version at [uri]. A single
     * frame with RAW is developed from the RAW; otherwise from the composed camera JPEGs. Call on
     * DevelopEngine.dispatcher.
     */
    fun develop(context: Context, shots: List<Shot>, film: Film, s: DevelopSettings, uri: Uri, frameNumber: Int): SavedPhoto {
        val first = shots.first()
        val original = ExifInterface(ByteArrayInputStream(first.jpeg))
        val limit = DevelopEngine.pixelLimit(s)
        val raw = first.raw
        val developed = if (shots.size == 1 && raw != null) {
            // One frame with RAW: straight from the sensor into the engine, metered as the viewfinder showed it.
            DevelopEngine.developRaw(context, raw, s.format.aspect, limit, first.gain, first.previewMedian,
                DevelopEngine.params(film, s, rawInput = true, frameNumber = frameNumber, taken = first.timeMillis))
        } else {
            val picture = compose(shots, s)
            val (w, h) = DevelopEngine.fit(picture.width, picture.height, limit)
            val input = if (w == picture.width) picture else Bitmap.createScaledBitmap(picture, w, h, true).also { picture.recycle() }
            // Frames made from RAW are metered already; a picture from the camera's JPEG is metered by Develop.
            val fromJpeg = shots.any { it.raw == null }
            try {
                DevelopEngine.developBitmap(context, input,
                    DevelopEngine.params(film, s, rawInput = false, frameNumber = frameNumber, taken = first.timeMillis,
                        engineMeter = fromJpeg, evThirds = first.evThirds))
            } finally { input.recycle() }
        }
        context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(encode(developed)) } ?: error("Cannot rewrite the photo")
        writeExif(context, uri, original, film, first.rotation, developed = true)
        return SavedPhoto(uri, thumbnail(developed, first.rotation).asImageBitmap()).also { developed.recycle() }
    }

    // ------------------------------------------------------------------ composing frames

    /** The picture on the sensor's frame (sRGB-encoded scene light), from one or more shots. */
    fun compose(shots: List<Shot>, s: DevelopSettings): Bitmap {
        val frames = shots.mapIndexed { i, shot -> crop(frame(shot), slotAspect(s, i)) }
        return when {
            frames.size == 1 -> frames[0]
            s.format == Format.HALF_PAIR -> halfPair(frames)
            s.format == Format.TRIPTYCH -> triptych(frames)
            else -> multiple(frames)
        }
    }

    /** Two half frames side by side, 1 mm of unexposed film between them (18 + 1 + 18 mm). */
    private fun halfPair(frames: List<Bitmap>): Bitmap {
        val fh = frames.minOf { it.height }
        val fw = (fh * 0.75).roundToInt()
        val gap = (fw / 18.0).roundToInt()
        val out = Bitmap.createBitmap(fw * 2 + gap, fh, Bitmap.Config.ARGB_8888)
        val c = Canvas(out).apply { drawColor(Color.BLACK) }
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        frames.take(2).forEachIndexed { i, f ->
            c.drawBitmap(f, null, Rect(i * (fw + gap), 0, i * (fw + gap) + fw, fh), paint)
            f.recycle()
        }
        return out
    }

    /** Two frames above a long one, thin unexposed lines between them, all on one piece of film. */
    private fun triptych(frames: List<Bitmap>): Bitmap {
        val width = frames.maxOf { it.width }
        val height = (width / 1.5).roundToInt()          // exactly a 35 mm frame (3:2), the engine's 135 gate
        val gap = max(4, width / 160)
        val tw = (width - gap) / 2
        val th = (tw / 1.5).roundToInt()
        val bh = height - th - gap
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val c = Canvas(out).apply { drawColor(Color.BLACK) }
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        c.drawBitmap(frames[0], null, Rect(0, 0, tw, th), paint)
        c.drawBitmap(frames[1], null, Rect(tw + gap, 0, width, th), paint)
        c.drawBitmap(frames[2], null, Rect(0, th + gap, width, th + gap + bh), paint)
        frames.forEach { it.recycle() }
        return out
    }

    /**
     * Several exposures on one frame, Develop's way (engine/host pairing::added): each metered on its own, their
     * light added in linear light, each at an equal share so the sum is one exposure.
     */
    private fun multiple(frames: List<Bitmap>): Bitmap {
        val w = frames.minOf { it.width }
        val h = frames.minOf { it.height }
        val acc = FloatArray(w * h * 3)
        val px = IntArray(w * h)
        val share = 1f / frames.size
        for (f in frames) {
            val src = if (f.width == w && f.height == h) f else Bitmap.createScaledBitmap(f, w, h, true)
            src.getPixels(px, 0, w, 0, 0, w, h)
            for (i in px.indices) {
                val p = px[i]
                acc[3 * i] += LINEAR[(p shr 16) and 255] * share
                acc[3 * i + 1] += LINEAR[(p shr 8) and 255] * share
                acc[3 * i + 2] += LINEAR[p and 255] * share
            }
            if (src !== f) src.recycle()
            f.recycle()
        }
        for (i in px.indices) {
            px[i] = (0xFF shl 24) or (encode8(acc[3 * i]) shl 16) or (encode8(acc[3 * i + 1]) shl 8) or encode8(acc[3 * i + 2])
        }
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { setPixels(px, 0, w, 0, 0, w, h) }
    }

    /** One shot on the sensor's frame: from its RAW (metered, straightened) when it has one, else its JPEG. */
    private fun frame(shot: Shot): Bitmap {
        val raw = shot.raw ?: return sensorOriented(shot, 1)
        return runCatching { DevelopEngine.rawToBitmap(raw, shot.gain, shot.previewMedian) }.getOrElse { sensorOriented(shot, 1) }
    }

    /**
     * The camera JPEG decoded (at 1/[sample] size) on the sensor's frame. The camera either turned the pixels
     * (EXIF says normal) or tagged the turn (EXIF orientation); either way this undoes it, so every frame is laid
     * out the same before cropping and composing, and the saved picture carries the turn as its EXIF orientation.
     */
    fun sensorOriented(shot: Shot, sample: Int): Bitmap {
        val bmp = BitmapFactory.decodeByteArray(shot.jpeg, 0, shot.jpeg.size,
            BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888; inSampleSize = sample; inMutable = true })
            ?: error("The camera's JPEG could not be read")
        val tagged = when (ExifInterface(ByteArrayInputStream(shot.jpeg))
            .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
        val turned = (shot.rotation - tagged + 360) % 360
        if (turned == 0) return bmp
        val m = Matrix().apply { postRotate(-turned.toFloat()) }
        return Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true).also { if (it !== bmp) bmp.recycle() }
    }

    /** The centre of [b] at [aspect] (width / height). */
    fun crop(b: Bitmap, aspect: Double): Bitmap {
        val current = b.width.toDouble() / b.height
        if (kotlin.math.abs(current - aspect) < 0.005) return b
        val (w, h) = if (current > aspect) (b.height * aspect).roundToInt() to b.height else b.width to (b.width / aspect).roundToInt()
        val out = Bitmap.createBitmap(b, (b.width - w) / 2, (b.height - h) / 2, w, h)
        if (out !== b) b.recycle()
        return out
    }

    private val LINEAR = FloatArray(256) { i ->
        val v = i / 255f
        if (v <= 0.04045f) v / 12.92f else ((v + 0.055f) / 1.055f).toDouble().pow(2.4).toFloat()
    }

    private fun encode8(linear: Float): Int {
        val v = linear.coerceIn(0f, 1f)
        val e = if (v <= 0.0031308f) 12.92f * v else 1.055f * v.toDouble().pow(1 / 2.4).toFloat() - 0.055f
        return (e * 255f + 0.5f).toInt().coerceIn(0, 255)
    }

    // ------------------------------------------------------------------ files

    private fun encode(b: Bitmap): ByteArray = ByteArrayOutputStream(b.width * b.height / 2).use { os ->
        b.compress(Bitmap.CompressFormat.JPEG, 95, os)
        os.toByteArray()
    }

    /** The camera's facts (never location), the turn, the app and the film, into the JPEG at [uri]. */
    private fun writeExif(context: Context, uri: Uri, original: ExifInterface, film: Film, rotation: Int, developed: Boolean) {
        context.contentResolver.openFileDescriptor(uri, "rw")?.use { fd ->
            val exif = ExifInterface(fd.fileDescriptor)
            for (tag in COPIED_TAGS) original.getAttribute(tag)?.let { exif.setAttribute(tag, it) }
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, exifOrientation(rotation).toString())
            // "quick" = the film's LUT colour only; "developed" = Develop's engine (grain, halation, paper).
            exif.setAttribute(ExifInterface.TAG_SOFTWARE, if (developed) SOFTWARE_DEVELOPED else SOFTWARE_QUICK)
            exif.setAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION, film.name)
            exif.saveAttributes()
        }
    }

    private fun exifOrientation(degrees: Int) = when (degrees) {
        90 -> ExifInterface.ORIENTATION_ROTATE_90
        180 -> ExifInterface.ORIENTATION_ROTATE_180
        270 -> ExifInterface.ORIENTATION_ROTATE_270
        else -> ExifInterface.ORIENTATION_NORMAL
    }

    /** Inserts a pending MediaStore entry, writes [bytes], runs [after] on it, then publishes it. */
    private fun write(context: Context, name: String, mime: String, bytes: ByteArray, taken: Long, after: (Uri) -> Unit): Uri {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, FOLDER)
            put(MediaStore.MediaColumns.DATE_TAKEN, taken)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: error("MediaStore refused $name")
        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: error("Cannot write $name")
            after(uri)
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (t: Throwable) {
            resolver.delete(uri, null, null)
            throw t
        }
        return uri
    }

    /** A small upright copy for the camera screen. */
    fun thumbnail(bitmap: Bitmap, rotation: Int): Bitmap {
        val scale = 240f / max(bitmap.width, bitmap.height)
        val m = Matrix().apply { postScale(scale, scale); if (rotation != 0) postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }

    /** Trilinear lookup in an n^3 LUT (red fastest), ARGB pixels in place. */
    private fun applyLut(px: IntArray, from: Int, to: Int, lut: FloatArray, n: Int) {
        val s = (n - 1) / 255f
        val dr = 3
        val dg = n * 3
        val db = n * n * 3
        for (i in from until to) {
            val p = px[i]
            val rf = ((p shr 16) and 255) * s
            val gf = ((p shr 8) and 255) * s
            val bf = (p and 255) * s
            val r0 = min(rf.toInt(), n - 2)
            val g0 = min(gf.toInt(), n - 2)
            val b0 = min(bf.toInt(), n - 2)
            val fr = rf - r0
            val fg = gf - g0
            val fb = bf - b0
            val base = ((b0 * n + g0) * n + r0) * 3
            var out = 0
            for (c in 0..2) {
                val o = base + c
                val c00 = lut[o] + (lut[o + dr] - lut[o]) * fr
                val c10 = lut[o + dg] + (lut[o + dg + dr] - lut[o + dg]) * fr
                val c01 = lut[o + db] + (lut[o + db + dr] - lut[o + db]) * fr
                val c11 = lut[o + db + dg] + (lut[o + db + dg + dr] - lut[o + db + dg]) * fr
                val c0 = c00 + (c10 - c00) * fg
                val c1 = c01 + (c11 - c01) * fg
                val v = c0 + (c1 - c0) * fb
                val q = (v * 255f + 0.5f).toInt().coerceIn(0, 255)
                out = out or (q shl (16 - 8 * c))
            }
            px[i] = (p and 0xFF000000.toInt()) or out
        }
    }

    /** Camera facts copied from the camera's JPEG into the saved one. Never location; orientation is set apart. */
    private val COPIED_TAGS = listOf(
        ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL,
        ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_OFFSET_TIME, ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
        ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_ISO_SPEED_RATINGS,
        ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, ExifInterface.TAG_APERTURE_VALUE,
        ExifInterface.TAG_SHUTTER_SPEED_VALUE, ExifInterface.TAG_EXPOSURE_BIAS_VALUE, ExifInterface.TAG_WHITE_BALANCE,
        ExifInterface.TAG_FLASH, ExifInterface.TAG_EXPOSURE_PROGRAM, ExifInterface.TAG_METERING_MODE,
    )
}
