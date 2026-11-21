package com.jegly.developcamera.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.photo.PhotoInfo
import com.jegly.developcamera.photo.PhotoStore
import com.jegly.developcamera.photo.StoredPhoto
import com.jegly.developcamera.ui.theme.SheetTheme
import com.jegly.developcamera.ui.theme.Vintage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * The app's own viewer for the photos it took: swipe between them, pinch or double-tap to zoom to 100 % (where
 * grain shows), see film and exposure, delete, or open in another app on request.
 */
@Composable
fun PhotoViewer(
    photos: List<StoredPhoto>,
    onOpenElsewhere: (StoredPhoto) -> Unit,
    onDeleted: (StoredPhoto) -> Unit,
    onClose: () -> Unit,
) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    var zoomed by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf<StoredPhoto?>(null) }
    val pager = rememberPagerState { photos.size }
    Box(Modifier.fillMaxSize().background(Color(0xFF15100C)).systemBarsPadding()) {
        if (photos.isEmpty()) {
            Text("No photos yet", Modifier.align(Alignment.Center), color = Vintage.Sand)
        } else {
            HorizontalPager(
                state = pager,
                userScrollEnabled = !zoomed,
                key = { photos[it].uri.toString() },
                modifier = Modifier.fillMaxSize(),
            ) { page ->
                ZoomableImage(photos[page]) { z -> if (page == pager.currentPage) zoomed = z }
            }
        }
        // Top: back, and the date of the photo.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "‹ Camera",
                Modifier.clip(RoundedCornerShape(12.dp)).background(Vintage.BrownRaised.copy(alpha = 0.85f))
                    .clickable(onClick = onClose).padding(horizontal = 12.dp, vertical = 6.dp),
                color = Vintage.Cream, fontSize = 13.sp,
            )
            Spacer(Modifier.weight(1f))
            photos.getOrNull(pager.currentPage)?.let {
                Text(DATE.format(Date(it.taken)), color = Vintage.Sand, fontSize = 12.sp)
            }
        }
        // Bottom: film, exposure, developed or quick, and actions.
        photos.getOrNull(pager.currentPage)?.let { photo ->
            var info by remember(photo.uri) { mutableStateOf<PhotoInfo?>(null) }
            LaunchedEffect(photo.uri) { info = withContext(Dispatchers.IO) { runCatching { PhotoStore.info(context, photo) }.getOrNull() } }
            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .background(Vintage.Brown.copy(alpha = 0.88f)).padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                val i = info
                Text(i?.film ?: "", color = Vintage.Cream, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                val line = listOfNotNull(
                    i?.exposure?.takeIf { it.isNotEmpty() },
                    if (photo.dng != null) "RAW" else null,
                    when (i?.developed) { true -> "developed"; false -> "quick colour only"; null -> null },
                ).joinToString(" · ")
                Text(line, color = Vintage.Sand, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Action("Open in…") { onOpenElsewhere(photo) }
                    Action("Delete") { confirmDelete = photo }
                }
            }
        }
    }
    confirmDelete?.let { photo ->
        SheetTheme {
            AlertDialog(
                onDismissRequest = { confirmDelete = null },
                title = { Text("Delete this photo?") },
                text = { Text(if (photo.dng != null) "The JPEG and its DNG are deleted from the phone." else "It is deleted from the phone.") },
                confirmButton = {
                    TextButton(onClick = { confirmDelete = null; onDeleted(photo) }) { Text("Delete") }
                },
                dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Keep") } },
            )
        }
    }
}

private val DATE = SimpleDateFormat("d MMM yyyy, HH:mm", Locale.getDefault())

@Composable
private fun Action(label: String, onClick: () -> Unit) {
    Text(
        label,
        Modifier.clip(RoundedCornerShape(12.dp)).background(Vintage.BrownRaised).clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        color = Vintage.Cream, fontSize = 13.sp,
    )
}

/**
 * One photo, fitted to the screen. Two fingers zoom and pan (one finger is left to the pager until zoomed);
 * double tap goes to 100 % and back. Past 1.4x the full-resolution picture is decoded, so grain is real pixels.
 */
@Composable
private fun ZoomableImage(photo: StoredPhoto, onZoomed: (Boolean) -> Unit) {
    val context = LocalContext.current
    var bitmap by remember(photo.uri) { mutableStateOf<ImageBitmap?>(null) }
    var full by remember(photo.uri) { mutableStateOf(false) }
    var scale by remember(photo.uri) { mutableFloatStateOf(1f) }
    var offset by remember(photo.uri) { mutableStateOf(Offset.Zero) }
    LaunchedEffect(photo.uri) { bitmap = withContext(Dispatchers.IO) { runCatching { PhotoStore.decode(context, photo.uri, 2400) }.getOrNull() } }
    val wantFull = scale > 1.4f
    LaunchedEffect(photo.uri, wantFull) {
        if (wantFull && !full) {
            withContext(Dispatchers.IO) { runCatching { PhotoStore.decode(context, photo.uri) }.getOrNull() }?.let { bitmap = it; full = true }
        }
    }
    LaunchedEffect(scale > 1.01f) { onZoomed(scale > 1.01f) }
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val img = bitmap ?: return@BoxWithConstraints
        val boxW = constraints.maxWidth.toFloat()
        val boxH = constraints.maxHeight.toFloat()
        val aspect = img.width.toFloat() / img.height
        val shownW = min(boxW, boxH * aspect)
        val shownH = shownW / aspect
        // 100 %: one photo pixel per screen pixel (the long side of the full photo over the shown long side).
        val oneToOne = max(2f, max(photo.width, photo.height) / max(shownW, shownH))
        fun clamp(o: Offset, s: Float): Offset {
            val mx = max(0f, (shownW * s - boxW) / 2)
            val my = max(0f, (shownH * s - boxH) / 2)
            return Offset(o.x.coerceIn(-mx, mx), o.y.coerceIn(-my, my))
        }
        Image(
            img, null,
            Modifier.fillMaxSize()
                .pointerInput(photo.uri) {
                    detectTapGestures(onDoubleTap = { tap ->
                        if (scale > 1.01f) { scale = 1f; offset = Offset.Zero } else {
                            scale = oneToOne
                            offset = clamp(Offset((boxW / 2 - tap.x) * oneToOne, (boxH / 2 - tap.y) * oneToOne), oneToOne)
                        }
                    })
                }
                .pointerInput(photo.uri) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        do {
                            val event = awaitPointerEvent()
                            if (event.changes.size > 1 || scale > 1.01f) {
                                val s = (scale * event.calculateZoom()).coerceIn(1f, oneToOne * 2)
                                offset = if (s <= 1.01f) Offset.Zero else clamp(offset + event.calculatePan(), s)
                                scale = s
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        } while (event.changes.any { it.pressed })
                    }
                }
                .graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y },
            contentScale = ContentScale.Fit,
            filterQuality = if (scale >= oneToOne * 0.9f) FilterQuality.None else FilterQuality.Medium,
        )
    }
}
