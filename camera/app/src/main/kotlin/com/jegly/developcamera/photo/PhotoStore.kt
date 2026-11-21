package com.jegly.developcamera.photo

import android.content.ContentUris
import android.content.Context
import android.graphics.ImageDecoder
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlin.math.max

/** One photo the app took: the JPEG, and its DNG when there is one. */
data class StoredPhoto(
    val uri: Uri,
    val name: String,
    val taken: Long,
    val width: Int,
    val height: Int,
    val dng: Uri?,
)

/** What the viewer shows under a photo, read from its EXIF. */
data class PhotoInfo(val film: String?, val exposure: String, val developed: Boolean?)

/**
 * The app's own photos in DCIM/Develop Camera. Android lets an app see the media it created without any photo
 * permission, so this asks for none (photos from before a reinstall belong to the old install and are not listed).
 */
object PhotoStore {
    fun list(context: Context): List<StoredPhoto> {
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.MIME_TYPE,
        )
        val jpegs = mutableListOf<StoredPhoto>()
        val dngs = mutableMapOf<String, Uri>()
        context.contentResolver.query(
            collection, projection, "${MediaStore.MediaColumns.RELATIVE_PATH} = ?", arrayOf("${PhotoSaver.FOLDER}/"),
            "${MediaStore.MediaColumns.DATE_TAKEN} DESC",
        )?.use { c ->
            val id = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val name = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val taken = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
            val w = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val h = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val mime = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            while (c.moveToNext()) {
                val uri = ContentUris.withAppendedId(collection, c.getLong(id))
                val n = c.getString(name) ?: continue
                when (c.getString(mime)) {
                    "image/jpeg" -> jpegs += StoredPhoto(uri, n, c.getLong(taken), c.getInt(w), c.getInt(h), null)
                    "image/x-adobe-dng" -> dngs[n.substringBeforeLast('.')] = uri
                }
            }
        }
        return jpegs.map { it.copy(dng = dngs[it.name.substringBeforeLast('.')]) }
    }

    /** Deletes the photo and its DNG. The app may delete what it created without asking for a permission. */
    fun delete(context: Context, photo: StoredPhoto) {
        context.contentResolver.delete(photo.uri, null, null)
        photo.dng?.let { context.contentResolver.delete(it, null, null) }
    }

    fun info(context: Context, photo: StoredPhoto): PhotoInfo {
        val exif = context.contentResolver.openInputStream(photo.uri)?.use { ExifInterface(it) }
            ?: return PhotoInfo(null, "", null)
        val parts = mutableListOf<String>()
        exif.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, 0.0).takeIf { it > 0 }?.let {
            parts += if (it < 0.3) "1/${Math.round(1 / it)}" else "%.1f″".format(it).replace(".0″", "″")
        }
        exif.getAttribute(ExifInterface.TAG_ISO_SPEED_RATINGS)?.let { parts += "ISO $it" }
        exif.getAttribute(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM)?.takeIf { it != "0" }?.let { parts += "$it mm" }
        exif.getAttribute(ExifInterface.TAG_F_NUMBER)?.let { parts += "ƒ$it" }
        val software = exif.getAttribute(ExifInterface.TAG_SOFTWARE)
        val developed = when (software) {
            PhotoSaver.SOFTWARE_DEVELOPED -> true
            PhotoSaver.SOFTWARE_QUICK -> false
            else -> null
        }
        return PhotoInfo(exif.getAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION), parts.joinToString(" · "), developed)
    }

    /** Decodes a photo upright (EXIF orientation applied), its long side at most [maxSide] px, or full size. */
    fun decode(context: Context, uri: Uri, maxSide: Int? = null): ImageBitmap =
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val long = max(info.size.width, info.size.height)
            if (maxSide != null && long > maxSide) {
                val s = maxSide.toFloat() / long
                decoder.setTargetSize((info.size.width * s).toInt().coerceAtLeast(1), (info.size.height * s).toInt().coerceAtLeast(1))
            }
        }.asImageBitmap()
}
