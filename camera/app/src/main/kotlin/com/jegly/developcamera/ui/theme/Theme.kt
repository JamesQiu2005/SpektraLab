package com.jegly.developcamera.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** The vintage palette. */
object Vintage {
    val Cream = Color(0xFFF1E6CF)
    val CreamDim = Color(0xFFE3D4B6)
    val Sand = Color(0xFFC9B89A)
    val Mustard = Color(0xFFD9A43B)
    val BurntOrange = Color(0xFFC4622D)
    val Teal = Color(0xFF3F7A74)
    val Brick = Color(0xFF9C3B2E)
    val Brown = Color(0xFF2B2019)
    val BrownRaised = Color(0xFF3D2E23)
    val BrownBorder = Color(0xFF4A3A2C)
    val BrownText = Color(0xFF3A2A1E)
    val Ink = Color(0xFF2B1D0C)
    val MutedOnCream = Color(0xFF7A6650)
}

/** The camera itself: dark brown, cream text, mustard for what is on. */
private val CameraColors = darkColorScheme(
    primary = Vintage.Mustard, onPrimary = Vintage.Ink,
    primaryContainer = Vintage.Mustard, onPrimaryContainer = Vintage.Ink,
    secondary = Vintage.BurntOrange, onSecondary = Vintage.Cream,
    tertiary = Vintage.Teal, onTertiary = Vintage.Cream,
    background = Vintage.Brown, onBackground = Vintage.Cream,
    surface = Vintage.Brown, onSurface = Vintage.Cream,
    surfaceVariant = Vintage.BrownRaised, onSurfaceVariant = Vintage.Sand,
    surfaceContainerLowest = Vintage.Brown, surfaceContainerLow = Vintage.Brown,
    surfaceContainer = Vintage.BrownRaised, surfaceContainerHigh = Vintage.BrownRaised,
    surfaceContainerHighest = Vintage.BrownBorder,
    outline = Vintage.Sand, outlineVariant = Vintage.BrownBorder,
    error = Vintage.Brick, onError = Vintage.Cream,
)

/** Sheets (film, develop, format, settings): cream paper, brown ink, burnt orange for what is chosen. */
private val SheetColors = lightColorScheme(
    primary = Vintage.BurntOrange, onPrimary = Vintage.Cream,
    primaryContainer = Vintage.Mustard, onPrimaryContainer = Vintage.Ink,
    secondary = Vintage.Mustard, onSecondary = Vintage.Ink,
    secondaryContainer = Vintage.Mustard, onSecondaryContainer = Vintage.Ink,
    tertiary = Vintage.Teal, onTertiary = Vintage.Cream,
    background = Vintage.Cream, onBackground = Vintage.BrownText,
    surface = Vintage.Cream, onSurface = Vintage.BrownText,
    surfaceVariant = Vintage.CreamDim, onSurfaceVariant = Vintage.MutedOnCream,
    surfaceContainerLowest = Vintage.Cream, surfaceContainerLow = Vintage.Cream,
    surfaceContainer = Vintage.CreamDim, surfaceContainerHigh = Vintage.CreamDim,
    surfaceContainerHighest = Vintage.Sand,
    outline = Vintage.Sand, outlineVariant = Vintage.CreamDim,
    error = Vintage.Brick, onError = Vintage.Cream,
)

private val VintageShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(22.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

@Composable
fun DevelopCameraTheme(content: @Composable () -> Unit) =
    MaterialTheme(colorScheme = CameraColors, shapes = VintageShapes, content = content)

@Composable
fun SheetTheme(content: @Composable () -> Unit) =
    MaterialTheme(colorScheme = SheetColors, shapes = VintageShapes, content = content)
