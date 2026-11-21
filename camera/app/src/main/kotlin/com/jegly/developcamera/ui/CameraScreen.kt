package com.jegly.developcamera.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.MediaActionSound
import android.net.Uri
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.OrientationEventListener
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.jegly.developcamera.camera.CameraController
import com.jegly.developcamera.camera.Exposure
import com.jegly.developcamera.camera.Lens
import com.jegly.developcamera.camera.Shot
import com.jegly.developcamera.camera.Stops
import com.jegly.developcamera.camera.WhiteBalance
import com.jegly.developcamera.develop.DevelopSettings
import com.jegly.developcamera.develop.Format
import com.jegly.developcamera.engine.DevelopEngine
import com.jegly.developcamera.film.Film
import com.jegly.developcamera.film.FilmCatalog
import com.jegly.developcamera.film.LutCache
import com.jegly.developcamera.gl.FilmPreviewRenderer
import com.jegly.developcamera.photo.PhotoSaver
import com.jegly.developcamera.photo.PhotoStore
import com.jegly.developcamera.photo.SavedPhoto
import com.jegly.developcamera.photo.StoredPhoto
import com.jegly.developcamera.ui.theme.SheetTheme
import com.jegly.developcamera.ui.theme.Vintage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.pow
import kotlin.math.roundToInt

private enum class Dial { EV, SHUTTER, ISO, WB }

@Composable
fun CameraScreen() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("camera", Context.MODE_PRIVATE) }
    val films = remember { FilmCatalog.load(context.assets) }
    var film by remember {
        mutableStateOf(
            films.firstOrNull { it.id == prefs.getString("film", null) }
                ?: films.firstOrNull { it.id == "kodak_portra_400" } ?: films.first()
        )
    }
    var favourites by remember { mutableStateOf(prefs.getStringSet("favourites", emptySet())!!.toSet()) }
    var develop by remember { mutableStateOf(DevelopSettings.load(prefs)) }
    var app by remember {
        mutableStateOf(
            AppSettings(
                shutterSound = prefs.getBoolean("shutter_sound", false), shutterHaptic = prefs.getBoolean("shutter_haptic", false),
                grid = prefs.getBoolean("grid", true), level = prefs.getBoolean("level", false),
                peaking = prefs.getBoolean("peaking", false), histogram = prefs.getBoolean("histogram", false),
            )
        )
    }
    val controller = remember { CameraController(context) }
    val backLenses = remember { controller.lenses.filter { !it.front } }
    val defaultLens = remember { backLenses.minByOrNull { abs(it.equivMm - 24) } ?: controller.lenses.first() }
    var lens by remember { mutableStateOf(defaultLens) }
    var exposure by remember { mutableStateOf(Exposure(iso = Stops.nearestIso(film.iso ?: 400))) }
    var dial by remember { mutableStateOf<Dial?>(null) }
    var status by remember { mutableStateOf("") }
    var note by remember { mutableStateOf<String?>(null) }
    var sheet by remember { mutableStateOf<String?>(null) }   // "film", "develop", "format", "settings", "galleries"
    var previewFilm by remember { mutableStateOf<Film?>(null) }
    val lutCache = remember { LutCache() }
    val shownFilm = previewFilm ?: film
    var raw by remember { mutableStateOf(prefs.getBoolean("raw", true)) }
    var capturing by remember { mutableStateOf(false) }
    var lastPhoto by remember { mutableStateOf<SavedPhoto?>(null) }
    var developing by remember { mutableIntStateOf(0) }
    var viewer by remember { mutableStateOf<List<StoredPhoto>?>(null) }
    val pending = remember { mutableStateListOf<Shot>() }
    var ghost by remember { mutableStateOf<ImageBitmap?>(null) }
    var flashTick by remember { mutableIntStateOf(0) }
    val flash = remember { Animatable(0f) }
    var histogram by remember { mutableStateOf<FloatArray?>(null) }
    // The film meter: the viewfinder and every picture get the camera's light x meterGain. In Auto it brings the
    // median to mid grey (with ± compensation), as Develop's own meter does (tested on the Fold's DNGs); AE-L holds it.
    var meterGain by remember { mutableFloatStateOf(1f) }
    var meterMedian by remember { mutableFloatStateOf(0f) }
    var tilt by remember { mutableFloatStateOf(0f) }
    var surfaceTexture by remember { mutableStateOf<SurfaceTexture?>(null) }
    val glView = remember { mutableStateOf<GLSurfaceView?>(null) }
    val main = remember { Handler(Looper.getMainLooper()) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val deviceDegrees = remember { intArrayOf(0) }
    val sound = remember { MediaActionSound().apply { load(MediaActionSound.SHUTTER_CLICK) } }
    val renderer = remember {
        FilmPreviewRenderer(
            onSurfaceTexture = { st -> main.post { surfaceTexture = st } },
            requestRender = { glView.value?.requestRender() },
        )
    }
    // The display's rotation, for an upright viewfinder on every screen and orientation of the Fold.
    val configuration = LocalConfiguration.current
    val view = LocalView.current
    val quarterTurns = remember(configuration) { view.display?.rotation ?: 0 }
    renderer.quarterTurns = quarterTurns
    renderer.peaking = app.peaking
    renderer.gain = meterGain
    // Calibrated on a developed photo (Portra 400, grain 1: 4.4 levels std at full size, 2.6 seen whole on the
    // screen, 2026-11-21): the viewfinder shows the grain as the whole photo shows it, not the 100 % grain.
    renderer.grain = (shownFilm.grain * develop.grain * (if (develop.push > 0) 1.0 + 0.2 * develop.push else 1.0) * 0.0235 *
        Math.pow(1.0 / develop.grainSize.factor, 0.83)).toFloat()   // grain size: measured visibility ~ (35 / mm)^0.83
    renderer.grainCell = (1.0 + (1.0 / develop.grainSize.factor - 1.0) * 0.3).toFloat()
    renderer.monoGrain = shownFilm.kind.startsWith("b&w")
    renderer.onMeter = { median, bins ->
        main.post {
            meterMedian = median
            if (app.histogram) histogram = bins
            meterGain = when {
                // Manual: the exposure is the photographer's; mid grey at 12.7 % of the sensor's white (saturation ISO)
                // is the film's 18 %.
                exposure.manual -> 1.41f
                exposure.aeLock -> meterGain
                else -> {
                    val target = (0.18 * 2.0.pow(exposure.evThirds / 3.0) / median.coerceAtLeast(1e-4f)).toFloat().coerceIn(0.125f, 16f)
                    kotlin.math.exp(kotlin.math.ln(meterGain) * 0.7f + kotlin.math.ln(target) * 0.3f)
                }
            }
        }
    }
    // Upright on this screen, is the camera's picture tall (3:4) or wide (4:3)?
    val pictureTall = ((lens.sensorOrientation / 90) + quarterTurns) % 2 == 1

    fun saveApp(a: AppSettings) {
        app = a
        prefs.edit().putBoolean("shutter_sound", a.shutterSound).putBoolean("shutter_haptic", a.shutterHaptic)
            .putBoolean("grid", a.grid).putBoolean("level", a.level).putBoolean("peaking", a.peaking)
            .putBoolean("histogram", a.histogram).apply()
    }

    // The camera follows the GL surface (recreated after every pause) and the chosen lens.
    LaunchedEffect(surfaceTexture, lens) {
        val st = surfaceTexture ?: return@LaunchedEffect
        renderer.mirror = lens.front
        controller.previewSize(lens).let { renderer.bufferWidth = it.width; renderer.bufferHeight = it.height }
        // Only problems are shown on the viewfinder; the normal "plain sRGB preview: yes" stays hidden.
        controller.open(st, lens, exposure) { status = if (it == "plain sRGB preview: yes") "" else it }
    }
    LaunchedEffect(exposure) { controller.setExposure(exposure) }
    // Switching Auto/Manual closes whatever value strip was open (it belonged to the other mode).
    LaunchedEffect(exposure.manual) { dial = null }
    LaunchedEffect(raw) { prefs.edit().putBoolean("raw", raw).apply() }
    LaunchedEffect(develop) { develop.save(prefs) }
    // Loading a film, or pushing/pulling it, sets the manual ISO to the speed it is shot at.
    LaunchedEffect(film, develop.push) {
        prefs.edit().putString("film", film.id).apply()
        film.iso?.let { exposure = exposure.copy(iso = Stops.nearestIso((it * 2.0.pow(develop.push)).roundToInt())) }
    }
    // A different format or film starts the picture again.
    LaunchedEffect(develop.format, develop.exposures, film) { pending.clear(); ghost = null }
    // Start the engine early (copies its files on first run), so the first shot does not wait for it.
    LaunchedEffect(Unit) {
        withContext(DevelopEngine.dispatcher) {
            runCatching { DevelopEngine.start(context) }.onFailure { note = it.message }
        }
    }
    // The latest photo in the corner from the start.
    LaunchedEffect(Unit) {
        val latest = withContext(Dispatchers.IO) {
            runCatching {
                PhotoStore.list(context).firstOrNull()?.let { SavedPhoto(it.uri, PhotoStore.decode(context, it.uri, 240)) }
            }.getOrNull()
        }
        if (lastPhoto == null) lastPhoto = latest
    }
    // The shown film's LUT. While previewing in the film sheet, wait a moment so a fast swipe does not load all.
    LaunchedEffect(shownFilm) {
        if (previewFilm != null) delay(90)
        val f = shownFilm
        val lut = withContext(Dispatchers.IO) { runCatching { lutCache.get(context.assets, f) }.getOrNull() }
        renderer.setLut(lut)
        if (lut == null) note = "No LUT for ${f.short}"
    }
    LaunchedEffect(flashTick) {
        if (flashTick > 0) { flash.snapTo(0.9f); flash.animateTo(0f, tween(220)) }
    }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> glView.value?.onResume()
                Lifecycle.Event.ON_PAUSE -> {
                    controller.close()
                    surfaceTexture = null
                    glView.value?.onPause()
                }
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(observer)
        val orientation = object : OrientationEventListener(context) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees != ORIENTATION_UNKNOWN) deviceDegrees[0] = degrees
            }
        }
        orientation.enable()
        onDispose {
            owner.lifecycle.removeObserver(observer)
            orientation.disable()
            controller.release()
            sound.release()
        }
    }
    // The level: how far the phone is turned from the nearest upright or sideways position.
    DisposableEffect(app.level) {
        if (!app.level) return@DisposableEffect onDispose {}
        val sm = context.getSystemService(SensorManager::class.java)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                val raw = Math.toDegrees(atan2(e.values[0].toDouble(), e.values[1].toDouble())).toFloat()
                tilt = ((raw + 45f) % 90f + 90f) % 90f - 45f
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) = Unit
        }
        sm.getDefaultSensor(Sensor.TYPE_GRAVITY)?.let { sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_UI) }
        onDispose { sm.unregisterListener(listener) }
    }

    /** The picture is complete: save it at once, then let Develop's engine develop it in place. */
    fun finish(shots: List<Shot>) {
        val filmNow = film
        val settingsNow = develop
        val frameNumber = (prefs.getInt("frame", 0) % (if (settingsNow.format.medium) 12 else 36)) + 1
        prefs.edit().putInt("frame", frameNumber).apply()
        scope.launch {
            val quick = try {
                PhotoSaver.save(context, shots, filmNow, settingsNow, keepDng = raw)
            } catch (t: Throwable) {
                note = "Not saved: ${t.message}"
                return@launch
            }
            lastPhoto = quick
            note = null
            developing++
            try {
                val developed = withContext(DevelopEngine.dispatcher) {
                    PhotoSaver.develop(context, shots, filmNow, settingsNow, quick.uri, frameNumber)
                }
                if (lastPhoto?.uri == quick.uri) lastPhoto = developed
            } catch (t: Throwable) {
                note = "Kept the quick version: ${t.message}"
            } finally {
                developing--
            }
        }
    }

    fun shoot() {
        if (capturing) return
        capturing = true
        if (app.shutterHaptic) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        if (app.shutterSound) sound.play(MediaActionSound.SHUTTER_CLICK)
        flashTick++
        // The meter as the viewfinder shows it now: this picture gets exactly that.
        val gainNow = meterGain
        val medianNow = meterMedian
        val evNow = exposure.evThirds
        controller.capture(
            withRaw = lens.raw,   // always: every picture is made from the RAW data; the chip decides if the DNG is kept
            deviceDegrees = deviceDegrees[0],
            onShot = { shot ->
                capturing = false
                shot.gain = gainNow
                shot.previewMedian = medianNow
                shot.evThirds = evNow
                pending += shot
                if (pending.size >= develop.frames) {
                    val shots = pending.toList()
                    pending.clear()
                    ghost = null
                    finish(shots)
                } else if (develop.format == Format.MULTIPLE) {
                    // A faint copy of the exposures so far, to line up the next one.
                    val shots = pending.toList()
                    scope.launch(Dispatchers.Default) {
                        runCatching {
                            val b = PhotoSaver.compose(shots, develop.copy(format = Format.MULTIPLE, exposures = shots.size))
                            ghost = PhotoSaver.thumbnail(b, shots.first().rotation).let { t ->
                                android.graphics.Bitmap.createScaledBitmap(t, t.width * 3, t.height * 3, true)
                            }.asImageBitmap()
                            b.recycle()
                        }
                    }
                }
            },
            onError = { capturing = false; note = it },
        )
    }

    // ------------------------------------------------------------------ the viewfinder and the controls

    val viewfinder: @Composable (Modifier) -> Unit = { modifier ->
        Box(modifier, contentAlignment = Alignment.Center) {
            Box(Modifier.aspectRatio(if (pictureTall) 3f / 4f else 4f / 3f).clip(RoundedCornerShape(4.dp))) {
                AndroidView(
                    factory = { ctx ->
                        GLSurfaceView(ctx).apply {
                            setEGLContextClientVersion(3)
                            setRenderer(renderer)
                            renderMode = GLSurfaceView.RENDERMODE_WHEN_DIRTY
                            glView.value = this
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                ghost?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.38f) }
                val slot = PhotoSaver.slotAspect(develop, pending.size)
                FrameMask(if (pictureTall) 1.0 / slot else slot, app.grid, Modifier.fillMaxSize())
                if (app.level) LevelLine(tilt, Modifier.fillMaxSize())
                if (develop.frames > 1) FrameDots(develop.frames, pending.size, Modifier.align(Alignment.TopCenter).padding(top = 10.dp))
                FilmChip(shownFilm, Modifier.align(Alignment.BottomStart).padding(10.dp))
                histogram?.takeIf { app.histogram }?.let { Histogram(it, Modifier.align(Alignment.BottomEnd).padding(10.dp)) }
                if (status.isNotEmpty()) Chip(status, Modifier.align(Alignment.TopStart).padding(10.dp))
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = flash.value)))
            }
        }
    }

    val controls: @Composable () -> Unit = {
        ExposureBar(exposure, lens, dial, onDial = { dial = if (dial == it) null else it }, onChange = { exposure = it })
        Spacer(Modifier.height(10.dp))
        LensRow(backLenses, lens) { lens = it }
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val photo = lastPhoto
            if (photo == null) {
                Spacer(Modifier.size(42.dp))
            } else {
                Image(
                    photo.thumbnail, "Last photo",
                    Modifier.size(42.dp).clip(RoundedCornerShape(10.dp))
                        // a quiet mustard edge while the engine develops
                        .then(if (developing > 0) Modifier.border(2.dp, Vintage.Mustard, RoundedCornerShape(10.dp)) else Modifier)
                        .clickable {
                            scope.launch { viewer = withContext(Dispatchers.IO) { runCatching { PhotoStore.list(context) }.getOrDefault(emptyList()) } }
                        },
                    contentScale = ContentScale.Crop,
                )
            }
            RoundButton({ sheet = "film" }) { CanisterIcon(Vintage.Cream) }
            Box(
                Modifier.size(70.dp).clip(RoundedCornerShape(24.dp))
                    .background(if (capturing) Vintage.Brick else Vintage.BurntOrange)
                    .clickable(enabled = !capturing, onClick = ::shoot),
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.size(54.dp).border(2.dp, Vintage.Cream, RoundedCornerShape(18.dp)))
            }
            RoundButton({ sheet = "develop" }) { ApertureIcon(Vintage.Cream) }
            RoundButton({ lens = if (lens.front) defaultLens else controller.lenses.firstOrNull { it.front } ?: lens }) {
                FlipIcon(Vintage.Cream)
            }
        }
        Text(
            note ?: "",
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            color = Vintage.Sand, fontSize = 12.sp, textAlign = TextAlign.Center,
        )
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Vintage.Brown).systemBarsPadding()) {
        val wide = maxWidth > maxHeight * 0.85f && maxWidth >= 560.dp
        val top: @Composable () -> Unit = {
            TopBar(
                raw = raw, rawPossible = lens.raw, onRaw = { raw = !raw },
                format = if (develop.format == Format.MULTIPLE) "${develop.exposures}× exposure" else develop.format.label,
                onFormat = { sheet = "format" }, onSettings = { sheet = "settings" },
            )
        }
        if (wide) {
            // The unfolded Fold: the viewfinder on one side, everything else beside it.
            Row(Modifier.fillMaxSize()) {
                viewfinder(Modifier.weight(1f).fillMaxHeight().padding(8.dp))
                Column(Modifier.width(380.dp).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
                    top()
                    Spacer(Modifier.weight(1f))
                    controls()
                    Spacer(Modifier.height(12.dp))
                }
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                top()
                viewfinder(Modifier.weight(1f).fillMaxWidth())
                Spacer(Modifier.height(8.dp))
                controls()
            }
        }
    }

    when (sheet) {
        "film" -> FilmSheet(
            films = films, current = film, favourites = favourites,
            onFavourite = { f ->
                favourites = if (f.id in favourites) favourites - f.id else favourites + f.id
                prefs.edit().putStringSet("favourites", favourites).apply()
            },
            onPreview = { previewFilm = if (it.id == film.id) null else it },
            onLoad = { film = it; previewFilm = null },
            onDismiss = { sheet = null; previewFilm = null },
        )
        "develop" -> DevelopSheet(film, develop, onChange = { develop = it }, onDismiss = { sheet = null })
        "format" -> FormatSheet(develop, onChange = { develop = it }, onDismiss = { sheet = null })
        "settings" -> SettingsScreen(
            s = app, onChange = ::saveApp,
            galleryLabel = galleryLabel(context, prefs.getString("gallery", null)),
            onGallery = { sheet = "galleries" },
            onClose = { sheet = null },
        )
        "galleries" -> GalleryPicker(
            current = prefs.getString("gallery", null),
            onPick = { pkg ->
                prefs.edit().apply { if (pkg == null) remove("gallery") else putString("gallery", pkg) }.apply()
                sheet = "settings"
            },
            onDismiss = { sheet = "settings" },
        )
    }
    viewer?.let { photos ->
        PhotoViewer(
            photos = photos,
            onOpenElsewhere = { openPhoto(context, it.uri, prefs.getString("gallery", null)) },
            onDeleted = { p ->
                scope.launch {
                    val left = withContext(Dispatchers.IO) {
                        runCatching { PhotoStore.delete(context, p) }
                        PhotoStore.list(context)
                    }
                    viewer = left.takeIf { it.isNotEmpty() }
                    if (lastPhoto?.uri == p.uri) {
                        lastPhoto = left.firstOrNull()?.let {
                            withContext(Dispatchers.IO) { runCatching { SavedPhoto(it.uri, PhotoStore.decode(context, it.uri, 240)) }.getOrNull() }
                        }
                    }
                }
            },
            onClose = { viewer = null },
        )
    }
}

/** The chosen gallery app's name, for Settings. */
private fun galleryLabel(context: Context, pkg: String?): String {
    if (pkg == null) return "Phone's default"
    val pm = context.packageManager
    return runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))).toString() }
        .getOrDefault("Phone's default")
}

/** Opens a photo in the chosen gallery app, or the phone's default one. */
private fun openPhoto(context: Context, uri: Uri, pkg: String?) {
    val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "image/jpeg")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    if (pkg != null) view.setPackage(pkg)
    try {
        context.startActivity(view)
    } catch (_: ActivityNotFoundException) {
        context.startActivity(view.setPackage(null))   // the chosen app was removed
    }
}

/** "Open in": every app on the phone that can show a photo. */
@Composable
private fun GalleryPicker(current: String?, onPick: (String?) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val apps = remember {
        val pm = context.packageManager
        pm.queryIntentActivities(Intent(Intent.ACTION_VIEW).setType("image/*"), PackageManager.ResolveInfoFlags.of(0))
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .distinctBy { it.first }
            .filter { it.first != context.packageName }
            .sortedBy { it.second.lowercase() }
    }
    SheetTheme {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Open photos in") },
            text = {
                Column {
                    GalleryRow("Phone's default", current == null) { onPick(null) }
                    for ((pkg, label) in apps) GalleryRow(label, current == pkg) { onPick(pkg) }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        )
    }
}

@Composable
private fun GalleryRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        (if (selected) "● " else "○ ") + label,
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
    )
}

@Composable
private fun TopBar(raw: Boolean, rawPossible: Boolean, onRaw: () -> Unit, format: String, onFormat: () -> Unit, onSettings: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Surface(
            onClick = onRaw, enabled = rawPossible, shape = RoundedCornerShape(12.dp),
            color = if (raw && rawPossible) Vintage.Mustard else Vintage.BrownRaised,
        ) {
            Text(
                if (!rawPossible) "JPEG" else if (raw) "RAW + JPEG" else "JPEG",
                Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                color = if (raw && rawPossible) Vintage.Ink else Vintage.Cream, fontSize = 12.sp, fontWeight = FontWeight.Medium,
            )
        }
        Surface(onClick = onFormat, shape = RoundedCornerShape(12.dp), color = Vintage.BrownRaised) {
            Text(format, Modifier.padding(horizontal = 12.dp, vertical = 4.dp), color = Vintage.Cream, fontSize = 12.sp)
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onSettings) { GearIcon(Vintage.Cream) }
    }
}

/** Auto/Manual, then the settings for that mode, white balance and the (fixed) aperture. Tap one to change it. */
@Composable
private fun ExposureBar(e: Exposure, lens: Lens, open: Dial?, onDial: (Dial) -> Unit, onChange: (Exposure) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        if (open != null) {
            when (open) {
                Dial.EV -> ValueStrip(Stops.evThirds.map { Exposure(evThirds = it).evLabel }, Stops.evThirds.indexOf(e.evThirds)) {
                    onChange(e.copy(evThirds = Stops.evThirds[it]))
                }
                Dial.SHUTTER -> if (e.manual) {
                    val options = Stops.shutter.filter { it in lens.shutterMinNs..lens.shutterMaxNs }
                    val at = options.indexOfFirst { it <= e.shutterNs }.let { if (it < 0) options.lastIndex else it }
                    ValueStrip(options.map(Stops::shutterLabel), at) { onChange(e.copy(shutterNs = options[it])) }
                }
                Dial.ISO -> if (e.manual) {
                    val options = Stops.iso.filter { it in lens.isoMin..lens.isoMax }
                    ValueStrip(options.map { "$it" }, options.indexOf(Stops.nearestIso(e.iso))) { onChange(e.copy(iso = options[it])) }
                }
                Dial.WB -> ValueStrip(WhiteBalance.entries.map { it.label }, e.wb.ordinal) {
                    onChange(e.copy(wb = WhiteBalance.entries[it]))
                }
            }
            Spacer(Modifier.height(6.dp))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            Pill(if (e.manual) "Manual" else "Auto", strong = true) { onChange(e.copy(manual = !e.manual, aeLock = false)) }
            if (e.manual) {
                Pill(Stops.shutterLabel(e.shutterNs), selected = open == Dial.SHUTTER) { onDial(Dial.SHUTTER) }
                Pill("ISO ${e.iso}", selected = open == Dial.ISO) { onDial(Dial.ISO) }
            } else {
                Pill(e.evLabel, selected = open == Dial.EV) { onDial(Dial.EV) }
                // Exposure lock: meter on what matters, then reframe.
                Pill("AE-L", selected = e.aeLock) { onChange(e.copy(aeLock = !e.aeLock)) }
            }
            Pill(e.wb.label, selected = open == Dial.WB) { onDial(Dial.WB) }
            Pill(lens.apertureLabel, enabled = false) {}
        }
    }
}

@Composable
private fun Pill(text: String, selected: Boolean = false, strong: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val bg = when {
        strong -> Vintage.Teal
        selected -> Vintage.Mustard
        else -> Vintage.BrownRaised
    }
    Text(
        text,
        Modifier.clip(RoundedCornerShape(12.dp)).background(bg)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 5.dp),
        color = when {
            selected -> Vintage.Ink
            !enabled -> Vintage.Sand
            else -> Vintage.Cream
        },
        fontSize = 12.sp,
        fontWeight = if (selected || strong) FontWeight.Medium else FontWeight.Normal,
    )
}

/** A strip of values to pick from, scrolled to the current one. */
@Composable
private fun ValueStrip(labels: List<String>, selected: Int, onPick: (Int) -> Unit) {
    val state = rememberLazyListState(initialFirstVisibleItemIndex = (selected - 3).coerceAtLeast(0))
    LazyRow(
        state = state,
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        itemsIndexed(labels) { i, label -> Pill(label, selected = i == selected) { onPick(i) } }
    }
}

/**
 * The frame the picture will have, as on a viewfinder's frame lines: outside it darkened, its edge drawn, and
 * the thirds grid inside it. [aspect] is width / height on screen.
 */
@Composable
private fun FrameMask(aspect: Double, grid: Boolean, modifier: Modifier) = Canvas(modifier) {
    val boxAspect = size.width / size.height
    val (w, h) = if (aspect > boxAspect) size.width to (size.width / aspect).toFloat() else (size.height * aspect).toFloat() to size.height
    val left = (size.width - w) / 2
    val top = (size.height - h) / 2
    val shade = Color.Black.copy(alpha = 0.55f)
    if (top > 0.5f) {
        drawRect(shade, Offset(0f, 0f), Size(size.width, top))
        drawRect(shade, Offset(0f, top + h), Size(size.width, size.height - top - h))
    }
    if (left > 0.5f) {
        drawRect(shade, Offset(0f, 0f), Size(left, size.height))
        drawRect(shade, Offset(left + w, 0f), Size(size.width - left - w, size.height))
    }
    if (top > 0.5f || left > 0.5f) drawRect(Color.White.copy(alpha = 0.5f), Offset(left, top), Size(w, h), style = Stroke(1.5f))
    if (grid) {
        val c = Color.White.copy(alpha = 0.22f)
        for (i in 1..2) {
            val x = left + w * i / 3f
            val y = top + h * i / 3f
            drawLine(c, Offset(x, top), Offset(x, top + h), strokeWidth = 1f)
            drawLine(c, Offset(left, y), Offset(left + w, y), strokeWidth = 1f)
        }
    }
}

/** A horizon line that turns mustard when the phone is level. */
@Composable
private fun LevelLine(tilt: Float, modifier: Modifier) {
    val level = abs(tilt) < 1f
    Canvas(modifier.rotate(tilt)) {
        val c = if (level) Vintage.Mustard else Color.White.copy(alpha = 0.7f)
        val y = size.height / 2
        drawLine(c, Offset(size.width * 0.3f, y), Offset(size.width * 0.45f, y), strokeWidth = 3f)
        drawLine(c, Offset(size.width * 0.55f, y), Offset(size.width * 0.7f, y), strokeWidth = 3f)
    }
}

/** Shots taken of the shots this picture needs. */
@Composable
private fun FrameDots(total: Int, taken: Int, modifier: Modifier) {
    Row(modifier.background(Vintage.BrownRaised.copy(alpha = 0.8f), RoundedCornerShape(10.dp)).padding(horizontal = 8.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        for (i in 0 until total) {
            Box(Modifier.size(7.dp).clip(CircleShape).background(if (i < taken) Vintage.Mustard else Vintage.Sand.copy(alpha = 0.4f)))
        }
    }
}

@Composable
private fun Histogram(bins: FloatArray, modifier: Modifier) {
    Canvas(modifier.size(96.dp, 44.dp).background(Vintage.Brown.copy(alpha = 0.6f), RoundedCornerShape(6.dp))) {
        val peak = bins.maxOrNull()?.takeIf { it > 0f } ?: return@Canvas
        val bw = size.width / bins.size
        for (i in bins.indices) {
            val h = size.height * 0.9f * (bins[i] / peak)
            drawRect(Vintage.Cream.copy(alpha = 0.8f), Offset(i * bw, size.height - h), Size(bw * 0.85f, h))
        }
    }
}

@Composable
private fun Chip(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier.background(Vintage.BrownRaised.copy(alpha = 0.85f), RoundedCornerShape(11.dp)).padding(horizontal = 9.dp, vertical = 3.dp),
        color = Vintage.Cream, fontSize = 11.sp,
    )
}

@Composable
private fun FilmChip(film: Film, modifier: Modifier) {
    Row(
        modifier.background(Vintage.BrownRaised.copy(alpha = 0.85f), RoundedCornerShape(11.dp)).padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(film.swatch, CircleShape))
        Spacer(Modifier.size(6.dp))
        Text(film.short, color = Vintage.Cream, fontSize = 11.sp)
    }
}

@Composable
private fun LensRow(lenses: List<Lens>, current: Lens, onPick: (Lens) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
        for (l in lenses) {
            val on = l == current
            Box(
                Modifier.padding(horizontal = 5.dp).size(40.dp).clip(CircleShape)
                    .background(if (on) Vintage.Mustard else Vintage.BrownRaised).clickable { onPick(l) },
                contentAlignment = Alignment.Center,
            ) {
                Text(l.label, color = if (on) Vintage.Ink else Vintage.Cream, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
private fun RoundButton(onClick: () -> Unit, icon: @Composable () -> Unit) {
    Box(
        Modifier.size(42.dp).clip(CircleShape).background(Vintage.BrownRaised).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { icon() }
}
