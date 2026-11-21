package com.jegly.developcamera.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.ui.theme.Vintage
import kotlin.math.roundToInt

/**
 * A cream panel over the camera, from just below the status bar to the bottom, in one slide. Used instead of
 * Material's ModalBottomSheet, which opened tall sheets in steps (part way, then full height, then slowly filling in
 * under the status bar) and could not be closed until it had finished. Closes with a swipe down on its top bar, the
 * close button, the back gesture or a tap above it.
 */
@Composable
fun Panel(title: String, subtitle: String? = null, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    BackHandler(onBack = onDismiss)
    val shown = remember { MutableTransitionState(false).apply { targetState = true } }
    var drag by remember { mutableFloatStateOf(0f) }
    val closeAt = with(LocalDensity.current) { 120.dp.toPx() }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f))
            .clickable(interactionSource = null, indication = null, onClick = onDismiss))
        AnimatedVisibility(shown, Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(220)) { it } + fadeIn(tween(120))) {
            Column(
                Modifier.statusBarsPadding().padding(top = 24.dp).widthIn(max = 640.dp).fillMaxSize()
                    .offset { IntOffset(0, drag.roundToInt()) }
                    .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).background(Vintage.Cream)
                    .clickable(interactionSource = null, indication = null) {}   // taps on the panel stay on it
                    .navigationBarsPadding()
            ) {
                Column(Modifier.fillMaxWidth().draggable(
                    rememberDraggableState { drag = (drag + it).coerceAtLeast(0f) }, Orientation.Vertical,
                    onDragStopped = { if (drag > closeAt) onDismiss() else drag = 0f },
                )) {
                    Box(Modifier.fillMaxWidth().padding(top = 10.dp), contentAlignment = Alignment.Center) {
                        Box(Modifier.size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Vintage.Sand))
                    }
                    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(title, color = Vintage.BrownText, fontSize = 20.sp, fontWeight = FontWeight.Medium)
                            if (subtitle != null) Text(subtitle, color = Vintage.MutedOnCream, fontSize = 12.sp)
                        }
                        Text("×", Modifier.clickable(onClick = onDismiss).padding(horizontal = 14.dp, vertical = 4.dp),
                            color = Vintage.BrownText, fontSize = 26.sp)
                    }
                    Spacer(Modifier.height(8.dp))
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp),
                    content = content)
            }
        }
    }
}
