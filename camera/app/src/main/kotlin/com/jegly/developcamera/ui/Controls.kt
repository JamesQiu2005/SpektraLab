package com.jegly.developcamera.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.ui.theme.Vintage

// The mockup's controls, on cream paper: brown ink, mustard for what is on, burnt orange for what is chosen.

/** The mockup's small toggle: mustard track with a dark knob when on. */
@Composable
fun VintageToggle(on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Box(
        Modifier.size(34.dp, 18.dp).clip(RoundedCornerShape(9.dp))
            .background(if (on) Vintage.Mustard else Color(0xFF4F3D2F))
            .clickable(enabled = enabled) { onChange(!on) },
    ) {
        Box(
            Modifier.align(Alignment.CenterStart).offset(x = if (on) 18.dp else 2.dp).size(14.dp).clip(CircleShape)
                .background(if (on) Vintage.Ink else Color(0xFFA8977D)),
        )
    }
}

@Composable
fun SectionLabel(text: String) {
    Spacer(Modifier.height(14.dp))
    Text(text, color = Vintage.MutedOnCream, fontSize = 12.sp, modifier = Modifier.padding(bottom = 4.dp))
}

/** A row: label on the left, a control on the right. */
@Composable
fun LabelRow(label: String, detail: String? = null, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, color = Vintage.BrownText, fontSize = 14.sp)
            if (detail != null) Text(detail, color = Vintage.MutedOnCream, fontSize = 11.sp)
        }
        trailing()
    }
}

@Composable
fun ToggleRow(label: String, on: Boolean, detail: String? = null, onChange: (Boolean) -> Unit) =
    LabelRow(label, detail, onClick = { onChange(!on) }) { VintageToggle(on, onChange = onChange) }

/** Chips to pick one of; [enabled] false greys them. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun <T> ChoiceChips(options: List<T>, selected: T, label: (T) -> String, enabled: Boolean = true, onPick: (T) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (o in options) {
            val on = o == selected
            Text(
                label(o),
                Modifier.clip(RoundedCornerShape(11.dp))
                    .background(if (on) Vintage.BurntOrange else Vintage.CreamDim)
                    .clickable(enabled = enabled) { onPick(o) }
                    .padding(horizontal = 11.dp, vertical = 5.dp),
                color = if (on) Vintage.Cream else if (enabled) Vintage.BrownText else Vintage.Sand,
                fontSize = 12.sp,
                fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,
            )
        }
    }
}

/** A labelled slider with its value. */
@Composable
fun ValueSlider(label: String, value: Float, range: ClosedFloatingPointRange<Float>, valueLabel: String, onChange: (Float) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, color = Vintage.BrownText, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(valueLabel, color = Vintage.MutedOnCream, fontSize = 12.sp)
        }
        Slider(
            value = value, onValueChange = onChange, valueRange = range,
            colors = SliderDefaults.colors(
                thumbColor = Vintage.Mustard, activeTrackColor = Vintage.Mustard,
                inactiveTrackColor = Vintage.Sand, activeTickColor = Vintage.Mustard, inactiveTickColor = Vintage.Sand,
            ),
        )
    }
}

/** A card of related settings, as in the mockup. */
@Composable
fun Group(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 4.dp).clip(RoundedCornerShape(14.dp))
            .background(Color(0xFFEADCC0)).padding(horizontal = 12.dp, vertical = 6.dp),
    ) { content() }
}
