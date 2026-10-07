package io.nohzoh.ingress_hack_stats

/** Pipeline counters, shown in the app to see where frames get lost. */
object Diagnostics {
    @Volatile var startedAt = 0L
    @Volatile var frames = 0
    @Volatile var skippedAppVisible = 0
    @Volatile var ocrRuns = 0
    @Volatile var ocrErrors = 0
    @Volatile var ocrTotalMs = 0L
    @Volatile var textFrames = 0
    @Volatile var kept = 0
    @Volatile var lastText = ""
    @Volatile var lastError = ""

    fun reset() {
        startedAt = System.currentTimeMillis()
        frames = 0; skippedAppVisible = 0; ocrRuns = 0; ocrErrors = 0; ocrTotalMs = 0L
        textFrames = 0; kept = 0; lastText = ""; lastError = ""
    }

    fun toMap(): Map<String, Any> = mapOf(
        "running" to CaptureService.isRunning,
        "startedAt" to startedAt,
        "frames" to frames,
        "skippedAppVisible" to skippedAppVisible,
        "ocrRuns" to ocrRuns,
        "ocrErrors" to ocrErrors,
        "ocrTotalMs" to ocrTotalMs,
        "now" to System.currentTimeMillis(),
        "ocrIntervalMs" to CaptureService.ocrIntervalMs,
        "textFrames" to textFrames,
        "kept" to kept,
        "lastText" to lastText,
        "lastError" to lastError,
    )
}
