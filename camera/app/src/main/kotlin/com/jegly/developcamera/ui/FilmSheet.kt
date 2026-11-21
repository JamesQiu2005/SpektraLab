package com.jegly.developcamera.ui

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.film.Film
import com.jegly.developcamera.ui.theme.SheetTheme
import com.jegly.developcamera.ui.theme.Vintage
import kotlinx.coroutines.launch
import kotlin.math.abs

private val BRANDS = listOf("Kodak", "Fujifilm", "Ilford", "CineStill")
private val KINDS = listOf("Colour negative", "Slide", "Cine", "B&W")

/**
 * The film picker: swipe the canisters, filter by brand and type, star favourites, load one. The film in the
 * middle is previewed live in the viewfinder ([onPreview]); Load film keeps it, closing the sheet goes back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilmSheet(
    films: List<Film>,
    current: Film,
    favourites: Set<String>,
    onFavourite: (Film) -> Unit,
    onPreview: (Film) -> Unit,
    onLoad: (Film) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    SheetTheme {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = MaterialTheme.colorScheme.surface,
            scrimColor = Color.Transparent,   // keep the viewfinder clear: it shows the film being previewed
        ) {
            var brand by remember { mutableStateOf<String?>(null) }
            var kind by remember { mutableStateOf<String?>(null) }
            val shown = remember(films, brand, kind, favourites) {
                films.filter { (brand == null || it.brand == brand) && (kind == null || it.kindLabel == kind) }
                    .sortedBy { if (it.id in favourites) 0 else 1 }
            }
            Column(Modifier.padding(bottom = 28.dp)) {
                Text(
                    "Film",
                    Modifier.padding(horizontal = 20.dp),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(8.dp))
                ChipRow(listOf<String?>(null) + BRANDS, brand) { brand = it }
                ChipRow(listOf<String?>(null) + KINDS, kind) { kind = it }
                Spacer(Modifier.height(8.dp))
                if (shown.isEmpty()) {
                    Text("No film matches", Modifier.fillMaxWidth().padding(32.dp), textAlign = TextAlign.Center)
                } else {
                    Carousel(shown, current, favourites, onFavourite, onPreview, onLoad = { onLoad(it); onDismiss() })
                }
            }
        }
    }
}

@Composable
private fun ChipRow(options: List<String?>, selected: String?, onSelect: (String?) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (o in options) {
            FilterChip(selected = o == selected, onClick = { onSelect(o) }, label = { Text(o ?: "All") })
        }
    }
}

@Composable
private fun Carousel(
    shown: List<Film>,
    current: Film,
    favourites: Set<String>,
    onFavourite: (Film) -> Unit,
    onPreview: (Film) -> Unit,
    onLoad: (Film) -> Unit,
) {
    val start = shown.indexOfFirst { it.id == current.id }.coerceAtLeast(0)
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = start)
    val fling = rememberSnapFlingBehavior(lazyListState = listState)
    val scope = rememberCoroutineScope()
    val centre by remember(listState) {
        derivedStateOf {
            val info = listState.layoutInfo
            val mid = (info.viewportStartOffset + info.viewportEndOffset) / 2
            info.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - mid) }?.index ?: start
        }
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        LazyRow(
            state = listState,
            flingBehavior = fling,
            contentPadding = PaddingValues(horizontal = maxWidth / 2 - 31.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Bottom,
            modifier = Modifier.fillMaxWidth().height(160.dp),
        ) {
            itemsIndexed(shown, key = { _, f -> f.id }) { i, f ->
                Canister(f, focused = i == centre) { scope.launch { listState.animateScrollToItem(i) } }
            }
        }
    }
    val f = shown.getOrNull(centre) ?: return
    LaunchedEffect(f.id) { onPreview(f) }
    Spacer(Modifier.height(14.dp))
    Text(
        f.name, Modifier.fillMaxWidth(), textAlign = TextAlign.Center,
        style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium,
    )
    Text(
        f.detail, Modifier.fillMaxWidth(), textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(12.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
        OutlinedButton(onClick = { onFavourite(f) }) { Text(if (f.id in favourites) "★ Favourite" else "☆ Favourite") }
        Spacer(Modifier.width(10.dp))
        Button(onClick = { onLoad(f) }) { Text("Load film") }
    }
}

@Composable
private fun Canister(film: Film, focused: Boolean, onClick: () -> Unit) {
    val w by animateDpAsState(if (focused) 62.dp else 46.dp, label = "canister width")
    val h by animateDpAsState(if (focused) 146.dp else 110.dp, label = "canister height")
    val ink = if (film.swatch.luminance() > 0.45f) Vintage.Ink else Vintage.Cream
    Box(
        Modifier.width(w).height(h).clip(RoundedCornerShape(8.dp)).background(film.swatch)
            .then(if (focused) Modifier.border(2.dp, Vintage.BrownText, RoundedCornerShape(8.dp)) else Modifier)
            .clickable(onClick = onClick),
    ) {
        Box(Modifier.fillMaxWidth().height(if (focused) 16.dp else 13.dp).background(Vintage.BrownText))
        Text(
            film.short,
            Modifier.align(Alignment.Center).padding(top = 14.dp).wrapContentSize(unbounded = true)
                .requiredWidth(h - 30.dp).rotate(-90f),
            color = ink,
            fontSize = if (focused) 12.sp else 10.sp,
            fontWeight = if (focused) FontWeight.Medium else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}
