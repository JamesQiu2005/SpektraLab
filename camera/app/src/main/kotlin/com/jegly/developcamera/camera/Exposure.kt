package com.jegly.developcamera.camera

import android.hardware.camera2.CameraMetadata
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

enum class WhiteBalance(val label: String, val awbMode: Int) {
    AUTO("AWB", CameraMetadata.CONTROL_AWB_MODE_AUTO),
    DAYLIGHT("Daylight", CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT),
    CLOUDY("Cloudy", CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT),
    SHADE("Shade", CameraMetadata.CONTROL_AWB_MODE_SHADE),
    TUNGSTEN("Tungsten", CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT),
    FLUORESCENT("Fluorescent", CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT),
}

/**
 * How a shot is exposed. Auto: the camera meters, with compensation in thirds of a stop. Manual: shutter and ISO
 * as set. Aperture is not here: phone lenses have a fixed aperture.
 */
data class Exposure(
    val manual: Boolean = false,
    val evThirds: Int = 0,
    val shutterNs: Long = 8_000_000L,   // 1/125 s
    val iso: Int = 400,
    val wb: WhiteBalance = WhiteBalance.AUTO,
    /** Auto only: the camera's exposure and the film meter held where they are (AE-L). */
    val aeLock: Boolean = false,
) {
    val evLabel: String
        get() = when {
            evThirds == 0 -> "±0"
            else -> {
                val sign = if (evThirds > 0) "+" else "−"
                val whole = abs(evThirds) / 3
                val frac = when (abs(evThirds) % 3) { 1 -> "⅓"; 2 -> "⅔"; else -> "" }
                sign + (if (whole > 0) "$whole" else "") + frac
            }
        }
}

object Stops {
    /** Shutter speeds in third stops, 1/8000 s to 16 s, as nanoseconds. */
    val shutter: List<Long> = listOf(
        8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160,
        125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
    ).map { (1e9 / it).roundToLong() } + listOf(0.4, 0.5, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.0, 8.0, 10.0, 13.0, 16.0)
        .map { (it * 1e9).roundToLong() }

    /** ISO in third stops. */
    val iso: List<Int> = listOf(
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500,
        3200, 4000, 5000, 6400,
    )

    val evThirds: List<Int> = (-9..9).toList()

    fun shutterLabel(ns: Long): String {
        val s = ns / 1e9
        return if (s < 0.3) "1/${(1 / s).roundToInt()}" else {
            val t = if (s >= 10) "%.0f".format(s) else "%.1f".format(s).removeSuffix(".0")
            "$t″"
        }
    }

    /** The third stop nearest to [iso]. */
    fun nearestIso(iso: Int): Int = this.iso.minByOrNull { abs(it - iso) } ?: iso
}
