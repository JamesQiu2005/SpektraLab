package io.github.jegly.develop

import android.app.Activity
import android.content.ContentValues
import android.net.Uri
import android.provider.MediaStore
import app.tauri.Logger
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.io.File

@InvokeArg
class ExistsArgs {
  lateinit var dir: String
  lateinit var name: String
}

@InvokeArg
class PublishArgs {
  lateinit var path: String
  lateinit var dir: String
  lateinit var name: String
  lateinit var mime: String
  var overwrite: Boolean = false
}

/**
 * Export on Android (desktop/src-tauri/src/lib.rs, `shared_exists` / `shared_publish`). The engine host writes
 * the file into the app's own storage (files/Exporting); this moves it into shared storage through MediaStore:
 * pictures to Pictures/Develop (the gallery shows them), anything else (a .cube) to Download/Develop.
 * An app needs no permission to add files there or to find and replace the ones it added itself.
 */
@TauriPlugin
class SharedStoragePlugin(private val activity: Activity) : Plugin(activity) {

  private fun collection(dir: String): Uri =
    if (dir.startsWith("Download")) MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

  /** MediaStore keeps RELATIVE_PATH with a trailing slash. */
  private fun relative(dir: String) = dir.trim('/') + "/"

  /** The app's own file `name` in `dir`, if there is one (other apps' files are not visible without permission). */
  private fun find(dir: String, name: String): Uri? {
    val coll = collection(dir)
    activity.contentResolver.query(
      coll,
      arrayOf(MediaStore.MediaColumns._ID),
      "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
      arrayOf(relative(dir), name),
      null,
    )?.use { c -> if (c.moveToFirst()) return Uri.withAppendedPath(coll, c.getLong(0).toString()) }
    return null
  }

  @Command
  fun exists(invoke: Invoke) {
    val a = invoke.parseArgs(ExistsArgs::class.java)
    Thread {
      try {
        invoke.resolve(JSObject().apply { put("exists", find(a.dir, a.name) != null) })
      } catch (e: Exception) {
        invoke.reject(e.message ?: "Android could not look in ${a.dir}")
      }
    }.start()
  }

  @Command
  fun publish(invoke: Invoke) {
    val a = invoke.parseArgs(PublishArgs::class.java)
    // A full-size TIFF is a few hundred MB: off the main thread.
    Thread {
      val src = File(a.path)
      try {
        val resolver = activity.contentResolver
        val existing = if (a.overwrite) find(a.dir, a.name) else null
        val uri: Uri
        if (existing != null) {
          uri = existing
          resolver.openOutputStream(uri, "wt").use { out ->
            requireNotNull(out) { "Android could not open ${a.name}" }
            src.inputStream().use { it.copyTo(out, 1 shl 20) }
          }
        } else {
          val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, a.name)
            put(MediaStore.MediaColumns.MIME_TYPE, a.mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative(a.dir))
            put(MediaStore.MediaColumns.IS_PENDING, 1)   // hidden from other apps until it is whole
          }
          uri = requireNotNull(resolver.insert(collection(a.dir), values)) { "Android would not save ${a.name}" }
          try {
            resolver.openOutputStream(uri).use { out ->
              requireNotNull(out) { "Android could not open ${a.name}" }
              src.inputStream().use { it.copyTo(out, 1 shl 20) }
            }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
          } catch (e: Exception) {
            resolver.delete(uri, null, null)   // no half-written file left behind
            throw e
          }
        }
        // Android may have changed the name (another app's file of that name, or the extension): report its own.
        var stored = a.name
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
          if (c.moveToFirst()) c.getString(0)?.let { stored = it }
        }
        invoke.resolve(JSObject().apply { put("location", relative(a.dir) + stored) })
      } catch (e: Exception) {
        Logger.error("export to ${a.dir} failed: ${e.message}")
        invoke.reject(e.message ?: "Could not save ${a.name} to ${a.dir}")
      } finally {
        src.delete()
        // Each export has its own folder in files/Exporting: gone with its last file.
        src.parentFile?.takeIf { it.parentFile?.name == "Exporting" && it.list()?.isEmpty() == true }?.delete()
      }
    }.start()
  }
}
