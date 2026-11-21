package com.jegly.developcamera.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

// Small hand-drawn icons, so the app needs no icon library. Line icons in the given colour.

@Composable
fun ApertureIcon(color: Color, size: Dp = 22.dp) = Canvas(Modifier.size(size)) {
    val r = this.size.minDimension / 2f
    val w = r * 0.14f
    drawCircle(color, r - w / 2, style = Stroke(w))
    // six blades: chords that leave a hexagonal opening in the middle
    for (i in 0 until 6) {
        val a = Math.toRadians(60.0 * i)
        val b = Math.toRadians(60.0 * i + 100.0)
        drawLine(
            color,
            Offset(center.x + (r * 0.92f * cos(a)).toFloat(), center.y + (r * 0.92f * sin(a)).toFloat()),
            Offset(center.x + (r * 0.32f * cos(b)).toFloat(), center.y + (r * 0.32f * sin(b)).toFloat()),
            strokeWidth = w,
        )
    }
}

@Composable
fun CanisterIcon(color: Color, size: Dp = 22.dp) = Canvas(Modifier.size(size)) {
    val s = this.size.minDimension
    val w = s * 0.08f
    drawRoundRect(color, Offset(s * 0.22f, s * 0.2f), Size(s * 0.46f, s * 0.68f), CornerRadius(s * 0.08f), style = Stroke(w))
    drawRect(color, Offset(s * 0.36f, s * 0.08f), Size(s * 0.18f, s * 0.12f))
    drawLine(color, Offset(s * 0.68f, s * 0.42f), Offset(s * 0.92f, s * 0.42f), strokeWidth = w)
    drawLine(color, Offset(s * 0.68f, s * 0.66f), Offset(s * 0.92f, s * 0.66f), strokeWidth = w)
}

@Composable
fun GearIcon(color: Color, size: Dp = 20.dp) = Canvas(Modifier.size(size)) {
    val r = this.size.minDimension / 2f
    val w = r * 0.18f
    drawCircle(color, r * 0.55f, style = Stroke(w))
    drawCircle(color, r * 0.18f)
    for (i in 0 until 8) {
        val a = Math.toRadians(45.0 * i)
        drawLine(
            color,
            Offset(center.x + (r * 0.62f * cos(a)).toFloat(), center.y + (r * 0.62f * sin(a)).toFloat()),
            Offset(center.x + (r * 0.95f * cos(a)).toFloat(), center.y + (r * 0.95f * sin(a)).toFloat()),
            strokeWidth = w * 1.3f,
        )
    }
}

@Composable
fun FlipIcon(color: Color, size: Dp = 20.dp) = Canvas(Modifier.size(size)) {
    val s = this.size.minDimension
    val w = s * 0.09f
    drawArc(color, 200f, 220f, false, Offset(s * 0.15f, s * 0.15f), Size(s * 0.7f, s * 0.7f), style = Stroke(w))
    // arrow head at the arc's end
    drawLine(color, Offset(s * 0.18f, s * 0.42f), Offset(s * 0.06f, s * 0.3f), strokeWidth = w)
    drawLine(color, Offset(s * 0.18f, s * 0.42f), Offset(s * 0.3f, s * 0.3f), strokeWidth = w)
}
