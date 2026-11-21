package com.jegly.developcamera.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.develop.DevelopSettings
import com.jegly.developcamera.develop.Format
import com.jegly.developcamera.ui.theme.SheetTheme
import com.jegly.developcamera.ui.theme.Vintage

/** The Format sheet: 35 mm frames (one, two or three on a print, or several exposures on one) and 120. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FormatSheet(s: DevelopSettings, onChange: (DevelopSettings) -> Unit, onDismiss: () -> Unit) {
    SheetTheme {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = Vintage.Cream,
        ) {
            // Kept below the status bar (see DevelopSheet).
            Column(Modifier.heightIn(max = (LocalConfiguration.current.screenHeightDp * 0.85f).dp)
                .padding(horizontal = 16.dp).padding(bottom = 28.dp).verticalScroll(rememberScrollState())) {
                Text("Format", color = Vintage.BrownText, fontSize = 20.sp, fontWeight = FontWeight.Medium)
                for (group in listOf("35 mm", "120")) {
                    SectionLabel(if (group == "120") "120 medium format" else group)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (f in Format.entries.filter { it.group == group }) {
                            Tile(f, f == s.format) { onChange(s.copy(format = f)) }
                        }
                    }
                }
                if (s.format == Format.MULTIPLE) {
                    SectionLabel("Exposures on one frame")
                    ChoiceChips((2..9).toList(), s.exposures, { "$it" }) { onChange(s.copy(exposures = it)) }
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    when {
                        s.format.medium -> "Grain and halation are scaled to a 56 mm wide negative."
                        s.format == Format.HALF_PAIR -> "Two shots, side by side on one 35 mm frame."
                        s.format == Format.TRIPTYCH -> "Three shots: two frames above a long one."
                        s.format == Format.MULTIPLE -> "Each shot is metered alone; their light is added on one frame."
                        else -> "One shot per frame."
                    },
                    color = Vintage.MutedOnCream, fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun Tile(f: Format, selected: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.width(100.dp).clip(RoundedCornerShape(8.dp))
            .border(1.5.dp, if (selected) Vintage.BurntOrange else Vintage.Sand, RoundedCornerShape(8.dp))
            .background(if (selected) Color(0xFFF6DCC7) else Color.Transparent)
            .clickable(onClick = onClick).padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(44.dp), contentAlignment = Alignment.Center) { Diagram(f, selected) }
        Spacer(Modifier.height(4.dp))
        Text(f.label, color = Vintage.BrownText, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
}

/** A small drawing of the frame(s), as in the mockup. */
@Composable
private fun Diagram(f: Format, selected: Boolean) {
    val c = if (selected) Vintage.BurntOrange else Vintage.Sand
    @Composable fun frame(w: Dp, h: Dp, color: Color = c) = Box(Modifier.size(w, h).clip(RoundedCornerShape(2.dp)).background(color))
    when (f) {
        Format.HALF_PAIR -> Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) { frame(20.dp, 28.dp); frame(20.dp, 28.dp) }
        Format.TRIPTYCH -> Column(verticalArrangement = Arrangement.spacedBy(2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) { frame(22.dp, 15.dp, Vintage.BurntOrange); frame(22.dp, 15.dp, Vintage.Mustard) }
            frame(46.dp, 13.dp, Vintage.Teal)
        }
        Format.MULTIPLE -> Box { frame(42.dp, 28.dp); Box(Modifier.padding(start = 8.dp, top = 5.dp)) { frame(28.dp, 22.dp, Vintage.Brick.copy(alpha = 0.5f)) } }
        else -> {
            val h = 30.0
            val w = (h * f.aspect).coerceAtMost(84.0)
            frame(w.dp, (w / f.aspect).dp)
        }
    }
}
