package io.github.jegly.develop

import android.content.pm.PackageInfo
import android.os.Bundle
import android.system.Os
import android.util.Log
import android.view.View
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.activity.enableEdgeToEdge
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // Before the Rust side starts (super.onCreate): tell it where the engine host and its resources are
    // (desktop/src-tauri/src/host.rs, resolve_launch on Android).
    prepareEngine()
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    // Android 17 draws the app edge to edge and the page does not pad itself: keep it clear of the status
    // bar, the taskbar and the camera cutout, or the top bar sits under the status bar, where Android takes
    // the touches. Pad here, then pass the WebView those insets as zero (not CONSUMED: that would stop the
    // keyboard's insets reaching it too; Android's "Understand window insets in WebView").
    val content = findViewById<View>(android.R.id.content)
    val padded = WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
    ViewCompat.setOnApplyWindowInsetsListener(content) { v, insets ->
      val bars = insets.getInsets(padded)
      v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
      WindowInsetsCompat.Builder(insets).setInsets(padded, Insets.NONE).build()
    }
  }

  /**
   * Hardening on top of Tauri's own WebView settings (generated/RustWebView.kt, rewritten by every Tauri build,
   * so set here). The page is the app's own, served by Tauri from the APK: it needs JavaScript and nothing that
   * reaches files, content providers, location, other windows or Google's services.
   */
  override fun onWebViewCreate(webView: WebView) {
    webView.settings.apply {
      allowFileAccess = false                    // no file:// pages or reads
      allowContentAccess = false                 // no content:// reads from the page (Import is native)
      setGeolocationEnabled(false)               // Tauri's template turns it on; the app has no location
      javaScriptCanOpenWindowsAutomatically = false
      setSupportMultipleWindows(false)
      mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
      safeBrowsingEnabled = false                // Safe Browsing asks Google's servers about pages
    }
    if (!BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(false)
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
