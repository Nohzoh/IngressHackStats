package io.nohzoh.ingress_hack_stats

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import com.google.mlkit.vision.text.Text
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Rarity of mods is not written in the popup: it is drawn as three slanted
 * bars left of the quantity ("/// x1 Portal Shield"), lit (coloured) for
 * common = 1, rare = 2, very rare = 3, the others grey.
 *
 * For each quantity word ("x1"), the pixels just left of it are scanned and
 * lit bars counted. The result is written into the line text as a token
 * "§r<bars>:<hue>" before the quantity, e.g. "§r1:160 x1 Portal Shield", so
 * the Dart parser (and the raw captures, for calibration) can use it.
 * Coloured level text ("L1") gives marks too; the parser ignores marks for
 * items that have levels.
 */
object RarityMarks {
    private val QUANTITY = Regex("^[x×]\\d{1,3}$", RegexOption.IGNORE_CASE)

    /** Line text with rarity marks inserted before quantity words. */
    fun markedText(line: Text.Line, bitmap: Bitmap): String {
        val elements = line.elements
        if (elements.isEmpty()) return line.text
        var marked = false
        val parts = elements.map { element ->
            val box = element.boundingBox
            val mark = if (box != null && QUANTITY.matches(element.text)) mark(bitmap, box) else null
            if (mark != null) {
                marked = true
                "$mark ${element.text}"
            } else {
                element.text
            }
        }
        return if (marked) parts.joinToString(" ") else line.text
    }

    /** "§r<bars>:<hue>" for the slot left of [quantityBox], or null. */
    fun mark(bitmap: Bitmap, quantityBox: Rect): String? {
        val h = quantityBox.height()
        if (h < 8) return null
        val right = quantityBox.left - (h * 0.15).roundToInt()
        val left = (quantityBox.left - (h * 1.7).roundToInt()).coerceAtLeast(0)
        if (right - left < 6 || right >= bitmap.width) return null

        // Bars are slanted: scan three lines and keep the median count.
        val scans = listOf(-0.2, 0.0, 0.2).map { dy ->
            val y = (quantityBox.centerY() + dy * h).roundToInt().coerceIn(0, bitmap.height - 1)
            scan(bitmap, left, right, y)
        }
        val bars = scans.map { it.runs }.sorted()[1]
        if (bars !in 1..3) return null
        val sin = scans.sumOf { it.sinSum }
        val cos = scans.sumOf { it.cosSum }
        val hue = ((Math.toDegrees(atan2(sin, cos)) + 360) % 360).roundToInt()
        return "§r$bars:$hue"
    }

    private class Scan(val runs: Int, val sinSum: Double, val cosSum: Double)

    /** Counts runs of vivid pixels on row [y], tolerating 2-pixel gaps. */
    private fun scan(bitmap: Bitmap, left: Int, right: Int, y: Int): Scan {
        val hsv = FloatArray(3)
        var runs = 0
        var gap = Int.MAX_VALUE
        var sinSum = 0.0
        var cosSum = 0.0
        for (x in left until right) {
            Color.colorToHSV(bitmap.getPixel(x, y), hsv)
            val lit = hsv[1] > 0.45f && hsv[2] > 0.45f
            if (lit) {
                if (gap > 2) runs++
                gap = 0
                val rad = Math.toRadians(hsv[0].toDouble())
                sinSum += sin(rad)
                cosSum += cos(rad)
            } else if (gap != Int.MAX_VALUE) {
                gap++
            }
        }
        return Scan(runs, sinSum, cosSum)
    }
}
