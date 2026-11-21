package com.jegly.developcamera.develop

import android.content.SharedPreferences

/**
 * What a frame is. Aspects are long side / short side of the frame on the film, laid along the sensor's long
 * side (the camera body's frame, as on a film camera: turn the phone and the frame turns with it).
 * filmMm is the frame's long edge, which sets how big grain and halation are against the picture.
 * overscan is Develop's film-edge format id (engine/src/pipeline/overscan.cpp).
 */
enum class Format(
    val id: String,
    val label: String,
    val group: String,
    val aspect: Double,
    val filmMm: Double,
    val overscan: String,
    val frames: Int,          // shots that make one picture (0 = the multiple-exposure count)
) {
    FULL("full", "Full", "35 mm", 1.5, 35.0, "135", 1),
    HALF_PAIR("half_pair", "Half pair", "35 mm", 1.5, 37.0, "135_half", 2),
    XPAN("xpan", "XPan", "35 mm", 65.0 / 24.0, 65.0, "135_xpan", 1),
    TRIPTYCH("triptych", "Triptych", "35 mm", 1.5, 35.0, "135", 3),
    MULTIPLE("multiple", "Multiple", "35 mm", 1.5, 35.0, "135", 0),
    F645("645", "6×4.5", "120", 56.0 / 41.5, 56.0, "120_645", 1),
    F66("6x6", "6×6", "120", 1.0, 56.0, "120_6x6", 1),
    F67("6x7", "6×7", "120", 69.5 / 56.0, 70.0, "120_6x7", 1),
    F69("6x9", "6×9", "120", 84.0 / 56.0, 84.0, "120_6x9", 1),
    F617("6x17", "6×17", "120", 168.0 / 56.0, 168.0, "120_6x17", 1);

    val medium: Boolean get() = group == "120"

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id } ?: FULL
    }
}

enum class Diffusion(val id: String, val label: String) {
    BLACK_PRO_MIST("black_pro_mist", "Black Pro-Mist"),
    PRO_MIST("pro_mist", "Pro-Mist"),
    GLIMMERGLASS("glimmerglass", "Glimmerglass"),
    CINEBLOOM("cinebloom", "CineBloom"),
}

enum class Leak(val id: String, val label: String) {
    OFF("off", "Off"), AUTO("auto", "Auto"), BAND("band", "Band"), WASH("wash", "Wash"), SPOT("spot", "Spot")
}

/** Colour filters for black-and-white film (engine camera_filters.hpp). */
enum class BwFilter(val id: String, val label: String) {
    YELLOW("w8", "Yellow"), DEEP_YELLOW("w15", "Deep yellow"), ORANGE("w21", "Orange"), RED("w25", "Red"), GREEN("w58", "Green")
}

/** Develop's lens characters (desktop params.ts LENS_PRESETS, from SpektraLab's LensCharacter.preset), at full amount. */
enum class LensCharacter(val id: String, val label: String, val fields: Map<String, Any>) {
    HELIOS("helios44", "Helios 44", mapOf("lens_field_curvature_um" to 45.0, "lens_astigmatism_um" to 70.0, "lens_field_exponent" to 2.0,
        "lens_coma_um" to 25.0, "lens_spherical_amount" to 0.08, "lens_spherical_um" to 60.0)),
    PETZVAL("petzval", "Petzval", mapOf("lens_field_curvature_um" to 70.0, "lens_astigmatism_um" to 100.0, "lens_field_exponent" to 3.0,
        "lens_sharp_radius" to 0.3)),
    VINTAGE_SOFT("vintage_soft", "Vintage soft", mapOf("lens_field_curvature_um" to 25.0, "lens_coma_um" to 60.0,
        "lens_spherical_amount" to 0.2, "lens_spherical_um" to 80.0)),
    PLASTIC("plastic", "Plastic", mapOf("lens_field_curvature_um" to 35.0, "lens_spherical_amount" to 0.25, "lens_spherical_um" to 120.0,
        "lens_lateral_ca_r" to 1.5, "lens_lateral_ca_b" to -1.5, "lens_loca_um" to 10.0, "lens_loca_sign" to "purple"));

    /** Every lens field, as Develop sends them (unset ones at their neutral value). */
    fun wire(): Map<String, Any> = mapOf<String, Any>(
        "lens_field_curvature_um" to 0.0, "lens_astigmatism_um" to 0.0, "lens_field_exponent" to 2.0, "lens_sharp_radius" to 0.0,
        "lens_coma_um" to 0.0, "lens_spherical_amount" to 0.0, "lens_spherical_um" to 60.0, "lens_lateral_ca_r" to 0.0,
        "lens_lateral_ca_b" to 0.0, "lens_loca_um" to 0.0, "lens_loca_sign" to "purple", "lens_loca_highlight_gate" to 1.0,
    ) + fields
}

/**
 * Grain size: Develop sizes grain against the negative (film_format_mm). A smaller negative enlarged to the same
 * print has coarser grain, which stays visible when the whole photo is on screen. Measured on a Fold DNG at grain 1
 * (grain seen whole on the screen, levels): 35 mm 2.0, 18 mm 3.4, 12 mm 4.9, 8 mm 7.2. Halation and diffusion grow
 * with it, as on a smaller negative.
 */
enum class GrainSize(val id: String, val label: String, val factor: Double) {
    FINE("fine", "Fine", 1.0), MEDIUM("medium", "Medium", 0.5), COARSE("coarse", "Coarse", 0.35), EXTRA("extra", "Extra coarse", 0.23)
}

/** Diffusion strengths in Develop's filter grades. */
val DIFFUSION_STRENGTHS = listOf(0.125, 0.25, 0.5, 1.0, 2.0)
fun strengthLabel(s: Double) = when (s) { 0.125 -> "1/8"; 0.25 -> "1/4"; 0.5 -> "1/2"; 1.0 -> "1"; else -> "2" }

/** Develop's development contrast for push/pull, −2..+2 stops (density_curve_gamma, range 0.5-2). */
fun pushGamma(push: Int) = when (push) { -2 -> 0.75; -1 -> 0.87; 1 -> 1.15; 2 -> 1.3; else -> 1.0 }

/** Everything the Develop sheet and the Format sheet set, kept on the phone. */
data class DevelopSettings(
    val grain: Double = 1.0,           // 0-2, 1 = as the film has it
    val halation: Double = 1.0,        // 0-4
    val diffusion: Diffusion? = null,
    val diffusionStrength: Double = 0.25,
    val push: Int = 0,                 // −2..+2 stops
    val paper: String? = null,         // null = the film's own paper
    val leak: Leak = Leak.OFF,
    val filmEdge: Boolean = false,
    val dateBack: Boolean = false,
    val format: Format = Format.FULL,
    val exposures: Int = 2,            // for Format.MULTIPLE, 2-9
    val bwFilter: BwFilter? = null,    // black-and-white films only
    val lens: LensCharacter? = null,
    val grainSize: GrainSize = GrainSize.FINE,
) {
    /** Shots that make one picture. */
    val frames: Int get() = if (format == Format.MULTIPLE) exposures else format.frames

    fun save(p: SharedPreferences) = p.edit()
        .putFloat("d_grain", grain.toFloat()).putFloat("d_halation", halation.toFloat())
        .putString("d_diffusion", diffusion?.id).putFloat("d_diffusion_strength", diffusionStrength.toFloat())
        .putInt("d_push", push).putString("d_paper", paper).putString("d_leak", leak.id)
        .putBoolean("d_edge", filmEdge).putBoolean("d_date", dateBack)
        .putString("d_format", format.id).putInt("d_exposures", exposures)
        .putString("d_bw_filter", bwFilter?.id).putString("d_lens", lens?.id).putString("d_grain_size", grainSize.id).apply()

    companion object {
        fun load(p: SharedPreferences) = DevelopSettings(
            grain = p.getFloat("d_grain", 1f).toDouble(),
            halation = p.getFloat("d_halation", 1f).toDouble(),
            diffusion = Diffusion.entries.firstOrNull { it.id == p.getString("d_diffusion", null) },
            diffusionStrength = p.getFloat("d_diffusion_strength", 0.25f).toDouble(),
            push = p.getInt("d_push", 0).coerceIn(-2, 2),
            paper = p.getString("d_paper", null),
            leak = Leak.entries.firstOrNull { it.id == p.getString("d_leak", "off") } ?: Leak.OFF,
            filmEdge = p.getBoolean("d_edge", false),
            dateBack = p.getBoolean("d_date", false),
            format = Format.of(p.getString("d_format", null)),
            exposures = p.getInt("d_exposures", 2).coerceIn(2, 9),
            bwFilter = BwFilter.entries.firstOrNull { it.id == p.getString("d_bw_filter", null) },
            lens = LensCharacter.entries.firstOrNull { it.id == p.getString("d_lens", null) },
            grainSize = GrainSize.entries.firstOrNull { it.id == p.getString("d_grain_size", null) } ?: GrainSize.FINE,
        )
    }
}

/** Develop's printing papers (engine catalogue, stage "printing"). */
data class Paper(val id: String, val label: String, val kind: String)

val PAPERS = listOf(
    Paper("kodak_portra_endura", "Portra Endura", "colour"),
    Paper("kodak_endura_premier", "Endura Premier", "colour"),
    Paper("kodak_supra_endura", "Supra Endura", "colour"),
    Paper("kodak_ultra_endura", "Ultra Endura", "colour"),
    Paper("kodak_ektacolor_edge", "Ektacolor Edge", "colour"),
    Paper("fujifilm_crystal_archive_typeii", "Crystal Archive II", "colour"),
    Paper("kodak_2383", "Kodak 2383", "cine"),
    Paper("kodak_2393", "Kodak 2393", "cine"),
    Paper("ilford_multigrade_iv_rc", "Multigrade IV", "bw"),
)
