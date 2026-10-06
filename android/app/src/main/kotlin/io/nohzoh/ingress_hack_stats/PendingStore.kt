package io.nohzoh.ingress_hack_stats

import android.content.Context
import java.io.File

/**
 * Append-only JSONL queue between the capture service and the Flutter side.
 * The service may run while the Flutter UI is gone, so captures are written to
 * disk and picked up by Dart when the app comes back.
 */
object PendingStore {
    private const val FILE_NAME = "pending_captures.jsonl"
    private val lock = Any()

    fun append(context: Context, json: String) {
        synchronized(lock) {
            File(context.filesDir, FILE_NAME).appendText(json.replace('\n', ' ') + "\n")
        }
    }

    fun drain(context: Context): List<String> {
        synchronized(lock) {
            val file = File(context.filesDir, FILE_NAME)
            if (!file.exists()) return emptyList()
            val lines = file.readLines().filter { it.isNotBlank() }
            file.delete()
            return lines
        }
    }
}
