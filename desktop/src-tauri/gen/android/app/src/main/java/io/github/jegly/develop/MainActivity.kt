package io.github.jegly.develop

import android.content.pm.PackageInfo
import android.os.Bundle
import android.system.Os
import android.util.Log
import androidx.activity.enableEdgeToEdge
import java.io.File

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // Before the Rust side starts (super.onCreate): tell it where the engine host and its resources are
    // (desktop/src-tauri/src/host.rs, resolve_launch on Android).
    prepareEngine()
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
  }

  /**
   * The engine host is a program shipped as a native library (lib/arm64-v8a/libspektralab_host.so, extracted
   * at install: android:extractNativeLibs). Its resources (film and paper profiles, LUTs, Vulkan kernels) are
   * APK assets under engine/, which the host cannot read in place: they are copied to app storage once per
   * installed version.
   */
  private fun prepareEngine() {
    val host = File(applicationInfo.nativeLibraryDir, "libspektralab_host.so")
    val engine = File(filesDir, "engine")
    val stamp = File(filesDir, "engine.version")
    val info: PackageInfo = packageManager.getPackageInfo(packageName, 0)
    val version = "${info.longVersionCode}/${info.lastUpdateTime}"
    if (!engine.isDirectory || !stamp.isFile || stamp.readText() != version) {
      val fresh = File(filesDir, "engine.new")
      fresh.deleteRecursively()
      copyAssets("engine", fresh)
      engine.deleteRecursively()
      if (!fresh.renameTo(engine)) Log.e(TAG, "could not move the engine resources into place")
      stamp.writeText(version)
    }
    Os.setenv("DEVELOP_ANDROID_HOST", host.absolutePath, true)
    Os.setenv("DEVELOP_ANDROID_ENGINE", engine.absolutePath, true)
  }

  private fun copyAssets(path: String, to: File) {
    val children = assets.list(path) ?: emptyArray()
    if (children.isEmpty()) {
      to.parentFile?.mkdirs()
      assets.open(path).use { input -> to.outputStream().use { input.copyTo(it) } }
      return
    }
    to.mkdirs()
    for (child in children) copyAssets("$path/$child", File(to, child))
  }

  companion object {
    private const val TAG = "Develop"
  }
}
