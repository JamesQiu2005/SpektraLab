package com.jegly.developcamera.film

import android.content.res.AssetManager
import android.util.Half
import androidx.compose.ui.graphics.Color
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer

/** One of Develop's 121 films (assets/films.json, written by tools/lut-bake/catalog.py). */
data class Film(
    val id: String,
    val name: String,
    val short: String,
    val brand: String,
    val kind: String,
    val iso: Int?,
    val swatch: Color,
    val print: String?,
    val lut: String,
    /** Black and white on Multigrade: the enlarger pack (magenta, yellow filter, print exposure). */
    val pack: List<Double>? = null,
    /** How grainy the film is in Develop's catalogue (about 0.3 fine to 2 coarse). */
    val grain: Double = 1.0,
) {
    val kindLabel: String
        get() = when {
            kind.startsWith("colour") -> "Colour negative"
            kind.startsWith("slide") -> "Slide"
            kind.startsWith("cine") -> "Cine"
            kind.startsWith("b&w") -> "B&W"
            else -> kind
        }

    /** "Colour negative · ISO 400 · on Portra Endura", or "Slide · ISO 50 · scanned". */
    val detail: String
        get() = listOfNotNull(kindLabel, iso?.let { "ISO $it" }, print?.let { "on ${paperName(it)}" } ?: "scanned")
            .joinToString(" · ")
}

/** "kodak_portra_endura" -> "Portra Endura", "kodak_2383" -> "Kodak 2383", "ilford_multigrade_iv_rc" -> "Multigrade". */
fun paperName(id: String): String = when (id) {
    "ilford_multigrade_iv_rc" -> "Multigrade"
    "kodak_2383", "kodak_2393" -> "Kodak " + id.substringAfter('_')
    else -> id.substringAfter('_').split('_').joinToString(" ") { it.replaceFirstChar(Char::uppercase) }
}

object FilmCatalog {
    fun load(assets: AssetManager): List<Film> {
        val text = assets.open("films.json").bufferedReader().use { it.readText() }
        val list = JSONObject(text).getJSONArray("films")
        return (0 until list.length()).map { i ->
            val o = list.getJSONObject(i)
            Film(
                id = o.getString("id"),
                name = o.getString("name"),
                short = o.optString("short", o.getString("name")),
                brand = o.getString("brand"),
                kind = o.getString("kind"),
                iso = if (o.isNull("iso")) null else o.getInt("iso"),
                swatch = Color(android.graphics.Color.parseColor(o.optString("swatch", "#c9b89a"))),
                print = if (o.isNull("print")) null else o.getString("print"),
                lut = o.getString("lut"),
                grain = o.optDouble("grain", 1.0).takeIf { !it.isNaN() } ?: 1.0,
                pack = o.optJSONArray("pack")?.let { a -> (0 until a.length()).map { a.getDouble(it) } },
            )
        }
    }
}

/** A baked film LUT as the GPU wants it: size^3 RGB half floats, red fastest (a GL_RGB16F 3D texture). */
class FilmLut(val size: Int, val rgb: ShortBuffer)

/** The last few films' LUTs, decoded, so previewing while scrolling the carousel is instant on the way back. */
class LutCache(private val capacity: Int = 12) {
    private val map = object : LinkedHashMap<String, FilmLut>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, FilmLut>?) = size > capacity
    }

    @Synchronized
    fun get(assets: AssetManager, film: Film): FilmLut = map.getOrPut(film.id) { LutLoader.load(assets, film) }
}

object LutLoader {
    /** The LUT as floats 0-1 (size^3 x RGB, red fastest), for developing a JPEG on the CPU. */
    fun loadFloats(assets: AssetManager, film: Film): Pair<Int, FloatArray> {
        val bytes = assets.open("luts/${film.lut}").use { it.readBytes() }
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(bytes.size > 8 && String(bytes, 0, 4, Charsets.US_ASCII) == "DCL1") { "${film.lut}: not a DCL1 LUT" }
        val n = bb.getInt(4)
        val count = n * n * n * 3
        require(bytes.size == 8 + count * 2) { "${film.lut}: wrong size" }
        return n to FloatArray(count) { (bb.getShort(8 + 2 * it).toInt() and 0xFFFF) / 65535f }
    }

    /** Reads assets/luts/<id>.lut: "DCL1", uint32 size, size^3 x uint16 RGB (0-65535), little-endian. */
    fun load(assets: AssetManager, film: Film): FilmLut {
        val bytes = assets.open("luts/${film.lut}").use { it.readBytes() }
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(bytes.size > 8 && String(bytes, 0, 4, Charsets.US_ASCII) == "DCL1") { "${film.lut}: not a DCL1 LUT" }
        val n = bb.getInt(4)
        val count = n * n * n * 3
        require(bytes.size == 8 + count * 2) { "${film.lut}: wrong size" }
        val out = ByteBuffer.allocateDirect(count * 2).order(ByteOrder.nativeOrder()).asShortBuffer()
        for (i in 0 until count) {
            val code = bb.getShort(8 + 2 * i).toInt() and 0xFFFF
            out.put(i, Half.toHalf(code / 65535f))
        }
        return FilmLut(n, out)
    }
}
