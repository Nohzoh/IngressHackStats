package io.nohzoh.ingress_hack_stats

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Small persistent journal of the capture lifecycle (start, consent, stop,
 * errors, crashes). Kept on disk so it survives a crash of the app process,
 * and shown in the app's Diagnostic card.
 */
object ServiceLog {
    private const val FILE_NAME = "service_log.txt"
    private const val MAX_LINES = 80
    private val lock = Any()
    private val format = SimpleDateFormat("dd/MM HH:mm:ss", Locale.FRANCE)

    @Volatile private var crashHandlerInstalled = false

    fun log(context: Context, message: String) {
        Log.i("IngressHackStats", message)
        synchronized(lock) {
            try {
                val file = File(context.filesDir, FILE_NAME)
                val lines = if (file.exists()) file.readLines() else emptyList()
                val line = "${format.format(Date())} $message".replace('\n', ' ')
                file.writeText((lines + line).takeLast(MAX_LINES).joinToString("\n") + "\n")
            } catch (_: Exception) {
                // Logging must never break the capture.
            }
        }
    }

    fun error(context: Context, where: String, e: Throwable) {
        val cause = generateSequence(e) { it.cause }.last()
        val frames = e.stackTrace.take(6).joinToString(" < ") {
            "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}"
        }
        log(
            context,
            "ERREUR $where : ${e.javaClass.simpleName}: ${e.message}" +
                (if (cause !== e) " (cause : ${cause.javaClass.simpleName}: ${cause.message})" else "") +
                " @ $frames",
        )
    }

    fun read(context: Context): String = synchronized(lock) {
        val file = File(context.filesDir, FILE_NAME)
        if (file.exists()) file.readText() else ""
    }

    fun clear(context: Context) = synchronized(lock) {
        File(context.filesDir, FILE_NAME).delete()
    }

    /** Records any crash of the app process before the default handler kills it. */
    fun installCrashHandler(context: Context) {
        if (crashHandlerInstalled) return
        crashHandlerInstalled = true
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            error(appContext, "plantage (thread ${thread.name})", e)
            previous?.uncaughtException(thread, e)
        }
    }
}
