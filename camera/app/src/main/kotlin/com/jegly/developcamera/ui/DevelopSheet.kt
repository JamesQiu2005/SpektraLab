package com.jegly.developcamera.ui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jegly.developcamera.develop.BwFilter
import com.jegly.developcamera.develop.DIFFUSION_STRENGTHS
import com.jegly.developcamera.develop.GrainSize
import com.jegly.developcamera.develop.LensCharacter
import com.jegly.developcamera.develop.DevelopSettings
import com.jegly.developcamera.develop.Diffusion
import com.jegly.developcamera.develop.Leak
import com.jegly.developcamera.develop.PAPERS
import com.jegly.developcamera.develop.strengthLabel
import com.jegly.developcamera.engine.DevelopEngine
import com.jegly.developcamera.film.Film
import com.jegly.developcamera.ui.theme.SheetTheme
import com.jegly.developcamera.ui.theme.Vintage
import kotlin.math.roundToInt

/**
 * The Develop sheet: how Develop's engine develops the next shots. Grain and halation as the film has them
 * (1 = Develop's default), a diffusion filter on the lens, push/pull, the paper, light leaks, the film edge and
 * the date back. Kept on the phone; applies from the next shot.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevelopSheet(film: Film, s: DevelopSettings, onChange: (DevelopSettings) -> Unit, onDismiss: () -> Unit) {
    SheetTheme {
        Panel("Develop", film.name, onDismiss) {
            run {
                Group {
                    ValueSlider("Grain", s.grain.toFloat(), 0f..2f, amountLabel(s.grain)) {
                        onChange(s.copy(grain = (it * 20).roundToInt() / 20.0))
                    }
                    Text("Grain size", color = Vintage.MutedOnCream, fontSize = 12.sp)
                    Spacer(Modifier.height(4.dp))
                    ChoiceChips(GrainSize.entries, s.grainSize, { it.label }) { onChange(s.copy(grainSize = it)) }
                    Spacer(Modifier.height(8.dp))
                    ValueSlider("Halation", s.halation.toFloat(), 0f..4f, amountLabel(s.halation)) {
                        onChange(s.copy(halation = (it * 20).roundToInt() / 20.0))
                    }
                }
                Group {
                    ToggleRow("Diffusion filter", s.diffusion != null) { on ->
                        onChange(s.copy(diffusion = if (on) (s.diffusion ?: Diffusion.BLACK_PRO_MIST) else null))
                    }
                    if (s.diffusion != null) {
                        ChoiceChips(Diffusion.entries, s.diffusion, { it.label }) { onChange(s.copy(diffusion = it)) }
                        Spacer(Modifier.height(8.dp))
                        Text("Strength", color = Vintage.MutedOnCream, fontSize = 12.sp)
                        Spacer(Modifier.height(4.dp))
                        ChoiceChips(DIFFUSION_STRENGTHS, s.diffusionStrength, ::strengthLabel) { onChange(s.copy(diffusionStrength = it)) }
                        Spacer(Modifier.height(6.dp))
                    }
                }
                Group {
                    LabelRow("Lens character", "The look of an old lens: softness, glow, fringes") {}
                    ChoiceChips(listOf<LensCharacter?>(null) + LensCharacter.entries, s.lens, { it?.label ?: "None" }) {
                        onChange(s.copy(lens = it))
                    }
                    if (film.kind.startsWith("b&w")) {
                        Spacer(Modifier.height(10.dp))
                        LabelRow("Filter", "A colour filter on the lens, for black-and-white film") {}
                        ChoiceChips(listOf<BwFilter?>(null) + BwFilter.entries, s.bwFilter, { it?.label ?: "None" }) {
                            onChange(s.copy(bwFilter = it))
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                }
                Group {
                    LabelRow("Push / pull", "Develop the film for a faster or slower speed") {}
                    ChoiceChips(listOf(-2, -1, 0, 1, 2), s.push, { if (it > 0) "+$it" else if (it < 0) "−${-it}" else "0" }) {
                        onChange(s.copy(push = it))
                    }
                    Spacer(Modifier.height(10.dp))
                    if (film.print == null) {
                        LabelRow("Paper", "Slides are scanned, not printed") {}
                    } else {
                        val bw = film.kind.startsWith("b&w")
                        val papers = PAPERS.filter { if (bw) it.kind == "bw" else it.kind != "bw" }
                        val current = DevelopEngine.paperFor(film, s.paper)
                        LabelRow("Paper", if (s.paper == null) "The film's own paper" else null) {}
                        ChoiceChips(papers.map { it.id }, current, { id -> PAPERS.first { it.id == id }.label }) { id ->
                            onChange(s.copy(paper = if (id == film.print) null else id))
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    LabelRow("Light leak") {}
                    ChoiceChips(Leak.entries, s.leak, { it.label }) { onChange(s.copy(leak = it)) }
                    Spacer(Modifier.height(6.dp))
                    ToggleRow("Film edge", s.filmEdge, "Sprocket holes, frame numbers and edge marks around the picture") {
                        onChange(s.copy(filmEdge = it))
                    }
                    ToggleRow("Date back", s.dateBack, "The date printed in the corner, like a camera's data back") {
                        onChange(s.copy(dateBack = it))
                    }
                }
                TextButton(onClick = { onChange(DevelopSettings(format = s.format, exposures = s.exposures)) }) {
                    Text("Back to the film's defaults", color = Vintage.BurntOrange)
                }
            }
        }
    }
}

private fun amountLabel(v: Double) = when {
    v == 0.0 -> "off"
    v == 1.0 -> "1.0 · as the film"
    else -> "%.2f".format(v).trimEnd('0').trimEnd('.')
}
