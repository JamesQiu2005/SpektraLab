package com.jegly.developcamera.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.ui.theme.Vintage

/** What Settings changes. Everything stays on the phone; there is no account and no network. */
data class AppSettings(
    val shutterSound: Boolean = false,     // off unless switched on
    val shutterHaptic: Boolean = false,
    val grid: Boolean = true,
    val level: Boolean = false,
    val peaking: Boolean = false,
    val histogram: Boolean = false,
)

/** Settings, laid out as in the mockup: a page of short rows with small toggles, grouped. */
@Composable
fun SettingsScreen(
    s: AppSettings,
    onChange: (AppSettings) -> Unit,
    galleryLabel: String,
    onGallery: () -> Unit,
    onClose: () -> Unit,
) {
    var licences by remember { mutableStateOf(false) }
    if (licences) { LicencesScreen { licences = false }; return }
    BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(Vintage.CreamDim).systemBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("‹", Modifier.clickable(onClick = onClose).padding(horizontal = 12.dp), color = Vintage.BrownText, fontSize = 26.sp)
            Text("Settings", color = Vintage.BrownText, fontSize = 18.sp, fontWeight = FontWeight.Medium)
        }
        Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
            SectionLabel("Shutter")
            Group {
                ToggleRow("Shutter sound", s.shutterSound) { onChange(s.copy(shutterSound = it)) }
                ToggleRow("Vibrate on shutter", s.shutterHaptic) { onChange(s.copy(shutterHaptic = it)) }
            }
            SectionLabel("Viewfinder")
            Group {
                ToggleRow("Grid", s.grid) { onChange(s.copy(grid = it)) }
                ToggleRow("Level", s.level) { onChange(s.copy(level = it)) }
                ToggleRow("Focus peaking", s.peaking, "Outlines what is in focus") { onChange(s.copy(peaking = it)) }
                ToggleRow("Histogram", s.histogram) { onChange(s.copy(histogram = it)) }
            }
            SectionLabel("Photos")
            Group {
                LabelRow("Open in", galleryLabel, onClick = onGallery) { Text("›", color = Vintage.MutedOnCream, fontSize = 18.sp) }
            }
            SectionLabel("About")
            Group {
                LabelRow("Licences", "Develop's engine is GPL-3.0-or-later", onClick = { licences = true }) {
                    Text("›", color = Vintage.MutedOnCream, fontSize = 18.sp)
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** The licence texts shipped in assets/licenses. */
@Composable
private fun LicencesScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val texts = remember {
        context.assets.list("licenses").orEmpty().sorted().map { name ->
            name to context.assets.open("licenses/$name").bufferedReader().use { it.readText() }
        }
    }
    Column(Modifier.fillMaxSize().background(Vintage.CreamDim).systemBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("‹", Modifier.clickable(onClick = onClose).padding(horizontal = 12.dp), color = Vintage.BrownText, fontSize = 26.sp)
            Text("Licences", color = Vintage.BrownText, fontSize = 18.sp, fontWeight = FontWeight.Medium)
        }
        Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
            for ((name, text) in texts) {
                Text(name, color = Vintage.BrownText, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(top = 14.dp))
                Spacer(Modifier.width(4.dp))
                Text(text, color = Vintage.BrownText, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
