package io.github.jegly.develop

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.result.ActivityResult
import app.tauri.Logger
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.io.File

/**
 * Import on Android (desktop/src-tauri/src/lib.rs, `pick_photos`). Android's picker hands out content:// links,
 * not paths, and the engine host, the sidecars and the folder list all work on files. So the picked photographs
 * are copied into the app's storage (files/Photos) under their own names, and their paths are returned.
 * Picking the same photograph again reuses its copy (same name and size), so its edits come back with it.
 */
@TauriPlugin
class PhotoImportPlugin(private val activity: Activity) : Plugin(activity) {

  @Command
  fun pickPhotos(invoke: Invoke) {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = "*/*"   // RAW files rarely have an image/* type on Android: the engine decides what it can open
      putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
    }
    startActivityForResult(invoke, intent, "picked")
  }

  @ActivityCallback
  fun picked(invoke: Invoke, result: ActivityResult) {
    if (result.resultCode != Activity.RESULT_OK || result.data == null) {
      invoke.resolve(JSObject().apply { put("paths", JSArray()) })   // cancelled: nothing to open
      return
    }
    val data = result.data!!
    val uris = mutableListOf<Uri>()
    val clip = data.clipData
    if (clip != null) for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) else data.data?.let(uris::add)
    // Copying a 60 MB RAW takes a moment: off the main thread.
    Thread {
      try {
        val dir = File(activity.filesDir, "Photos").apply { mkdirs() }
        val paths = JSArray()
        for (uri in uris) paths.put(copyIn(uri, dir).absolutePath)
        invoke.resolve(JSObject().apply { put("paths", paths) })
      } catch (e: Exception) {
        Logger.error("import failed: ${e.message}")
        invoke.reject(e.message ?: "Could not import the photographs")
      }
    }.start()
  }

  private fun copyIn(uri: Uri, dir: File): File {
    val resolver = activity.contentResolver
    var name = "photo"
    var size = -1L
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
      if (c.moveToFirst()) {
        c.getString(0)?.let { name = it }
        if (!c.isNull(1)) size = c.getLong(1)
      }
    }
    name = name.replace('/', '_').replace('\u0000', '_').ifBlank { "photo" }.let { if (it.startsWith(".")) "_$it" else it }
    val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
    var target = File(dir, name)
    var n = 2
    while (target.exists() && !(size >= 0 && target.length() == size)) {
      target = File(dir, name.substring(0, dot) + "-" + n++ + name.substring(dot))
    }
    if (target.exists()) return target   // already imported
    val part = File(dir, ".importing-" + target.name)
    resolver.openInputStream(uri).use { input ->
      requireNotNull(input) { "Android could not open $name" }
      part.outputStream().use { input.copyTo(it, 1 shl 20) }
    }
    if (!part.renameTo(target)) throw IllegalStateException("could not save $name")
    return target
  }
}
