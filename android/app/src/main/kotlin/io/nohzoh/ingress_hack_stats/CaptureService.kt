package io.nohzoh.ingress_hack_stats

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service that mirrors the screen into an [ImageReader], runs ML Kit
 * OCR on a throttled subset of frames and stores the frames whose text looks
 * like a hack result in [PendingStore]. Parsing proper happens on the Dart side
 * so it can be re-run on stored captures when the parser improves.
 */
class CaptureService : Service() {

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        private const val ACTION_STOP = "io.nohzoh.ingress_hack_stats.STOP"
        private const val TAG = "CaptureService"
        private const val CHANNEL_ID = "capture"
        private const val NOTIFICATION_ID = 1
        private const val RELAUNCH_CHANNEL_ID = "relaunch"
        private const val RELAUNCH_NOTIFICATION_ID = 2

        /**
         * Only this horizontal band of the screen is read: reward popups,
         * the glyph end screen and the AP gain all sit in it. A smaller image
         * makes OCR 2 to 3 times faster. The whole screen is read in
         * calibration mode.
         */
        private const val BAND_TOP = 0.20
        private const val BAND_BOTTOM = 0.65

        const val DEFAULT_OCR_INTERVAL_MS = 250L

        /** Same text seen again within this window is not stored twice. */
        private const val DEDUP_WINDOW_MS = 10_000L

        private val QUANTITY_TOKEN = Regex("(^|\\s)[x×]\\s?\\d{1,3}(\\s|$)", RegexOption.MULTILINE)

        private val AP_GAIN = Regex("\\+\\s?\\d[\\d,.]*\\s?ap(\\W|$)")

        /** Starts the capture with the screen-capture consent result. */
        fun start(context: Context, resultCode: Int, data: Intent, from: String): Boolean {
            ServiceLog.log(context, "$from : partage d'écran accepté, lancement du service")
            val intent = Intent(context, CaptureService::class.java)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (e: Exception) {
                ServiceLog.error(context, "lancement du service", e)
                false
            }
        }

        @Volatile var isRunning = false
            private set

        /** When true, every distinct OCR text is stored (for parser calibration). */
        @Volatile var debugMode = false

        /**
         * Minimum delay between two OCR passes, set from the app. Only one
         * pass runs at a time, so the real rate is also capped by OCR speed.
         */
        @Volatile var ocrIntervalMs = DEFAULT_OCR_INTERVAL_MS

        /** Set by [MainActivity]: OCR is paused while our own UI is on screen. */
        @Volatile var appVisible = false

        /**
         * Cheap pre-filter: frames without any of these words are dropped
         * before reaching storage. Keep in sync with lib/parsing/item_catalog.dart.
         */
        private val ITEM_KEYWORDS = listOf(
            "resonator", "xmp", "ultra strike", "power cube", "hypercube", "hyper cube",
            "portal key", "shield", "heat sink", "heatsink", "multi-hack", "multihack", "multi hack",
            "link amp", "ultra link", "force amp", "turret", "transmuter", "ada refactor",
            "jarvis", "fracker", "beacon", "capsule", "key locker",
        )
    }

    private lateinit var workerThread: HandlerThread
    private lateinit var handler: Handler
    // Discards callbacks arriving after shutdown instead of throwing.
    private val ocrExecutor = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, LinkedBlockingQueue(), ThreadPoolExecutor.DiscardPolicy(),
    )
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var recognizer: TextRecognizer? = null
    private var locationManager: LocationManager? = null

    private val ocrBusy = AtomicBoolean(false)
    @Volatile private var destroying = false
    private var lastOcrAt = 0L
    @Volatile private var lastStoredKey = ""
    @Volatile private var lastStoredAt = 0L
    @Volatile private var latestLocation: Location? = null
    private var width = 0
    private var height = 0

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            latestLocation = location
        }
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ServiceLog.installCrashHandler(this)
        ServiceLog.log(this, "service : créé")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            ServiceLog.log(this, "service : arrêt demandé depuis la notification")
            stopSelf()
            return START_NOT_STICKY
        }
        if (isRunning) return START_NOT_STICKY
        Diagnostics.reset()
        ServiceLog.log(this, "service : démarrage (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT})")

        try {
            // Must be in the foreground before getMediaProjection() (Android 14+).
            startInForeground()
        } catch (e: Exception) {
            ServiceLog.error(this, "startForeground", e)
            Diagnostics.lastError = "startForeground: ${e.message}"
            stopSelf()
            return START_NOT_STICKY
        }

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (data == null) {
            ServiceLog.log(this, "ERREUR : pas de jeton de capture reçu (intent ${if (intent == null) "nul" else "sans données"})")
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            startProjection(resultCode, data)
            ServiceLog.log(this, "capture : écran virtuel créé (${width}x$height)")
        } catch (e: Exception) {
            ServiceLog.error(this, "démarrage de la capture", e)
            Diagnostics.lastError = "start: ${e.message}"
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startLocationUpdates()
        } catch (e: Exception) {
            // GPS is a bonus: capture goes on without it.
            ServiceLog.error(this, "localisation", e)
        }
        isRunning = true
        CaptureTileService.requestUpdate(this)
        ServiceLog.log(this, "service : capture en cours")
        getSystemService(NotificationManager::class.java).cancel(RELAUNCH_NOTIFICATION_ID)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroying = true
        ServiceLog.log(
            this,
            "service : arrêté (images ${Diagnostics.frames}, OCR ${Diagnostics.ocrRuns}, gardées ${Diagnostics.kept})",
        )
        isRunning = false
        CaptureTileService.requestUpdate(this)
        locationManager?.removeUpdates(locationListener)
        virtualDisplay?.release()
        imageReader?.close()
        projection?.stop()
        recognizer?.close()
        if (::workerThread.isInitialized) workerThread.quitSafely()
        ocrExecutor.shutdown()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- setup

    /** Capture cut by the system (screen locked…): one tap to start again. */
    private fun showRelaunchNotification() {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(RELAUNCH_CHANNEL_ID, "Capture interrompue", NotificationManager.IMPORTANCE_DEFAULT)
            )
            val relaunch = PendingIntent.getActivity(
                this, 1,
                Intent(this, ProjectionRequestActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = NotificationCompat.Builder(this, RELAUNCH_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle("Capture interrompue")
                .setContentText("Le partage d'écran a été coupé. Toucher pour relancer.")
                .setContentIntent(relaunch)
                .setAutoCancel(true)
                .build()
            manager.notify(RELAUNCH_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            ServiceLog.error(this, "notification de relance", e)
        }
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Capture des hacks", NotificationManager.IMPORTANCE_LOW)
        )
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, CaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle("Ingress Hack Stats")
            .setContentText("Observation des résultats de hack en cours")
            .setOngoing(true)
            .addAction(0, "Arrêter", stopIntent)
            .build()

        val projectionOnly = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (hasLocationPermission()) {
            try {
                startForeground(NOTIFICATION_ID, notification, projectionOnly or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
                return
            } catch (e: Exception) {
                // Android may refuse the location type: carry on without GPS.
                ServiceLog.error(this, "startForeground avec localisation, nouvel essai sans", e)
            }
        }
        startForeground(NOTIFICATION_ID, notification, projectionOnly)
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        workerThread = HandlerThread("capture").apply { start() }
        handler = Handler(workerThread.looper)
        recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

        val metrics = DisplayMetrics()
        val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        width = metrics.widthPixels
        height = metrics.heightPixels

        val manager = getSystemService(MediaProjectionManager::class.java)
        val mp = manager.getMediaProjection(resultCode, data)
            ?: throw IllegalStateException("getMediaProjection returned null")
        // Callback must be registered before createVirtualDisplay (Android 14+).
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // Also called when we stop the projection ourselves.
                if (destroying) return
                ServiceLog.log(this@CaptureService, "capture : partage d'écran arrêté par le système")
                showRelaunchNotification()
                stopSelf()
            }

            override fun onCapturedContentVisibilityChanged(isVisible: Boolean) {
                ServiceLog.log(this@CaptureService, "capture : contenu partagé ${if (isVisible) "visible" else "masqué"}")
            }
        }, handler)
        projection = mp

        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        reader.setOnImageAvailableListener({ onFrame(it) }, handler)
        imageReader = reader

        virtualDisplay = mp.createVirtualDisplay(
            "ingress-hack-stats", width, height, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, handler,
        )
    }

    private fun startLocationUpdates() {
        if (!hasLocationPermission()) return
        val lm = getSystemService(LocationManager::class.java)
        locationManager = lm
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            try {
                if (!lm.isProviderEnabled(provider)) continue
                lm.getLastKnownLocation(provider)?.let { if (isBetter(it)) latestLocation = it }
                lm.requestLocationUpdates(provider, 5_000L, 0f, locationListener, workerThread.looper)
            } catch (e: SecurityException) {
                Log.w(TAG, "Location not available for $provider", e)
            }
        }
    }

    private fun isBetter(candidate: Location): Boolean {
        val current = latestLocation ?: return true
        return candidate.time > current.time
    }

    private fun hasLocationPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    // ---------------------------------------------------------------- frames

    private fun onFrame(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        Diagnostics.frames++
        try {
            val now = SystemClock.elapsedRealtime()
            if (appVisible) {
                Diagnostics.skippedAppVisible++
                return
            }
            if (now - lastOcrAt < ocrIntervalMs) return
            if (!ocrBusy.compareAndSet(false, true)) return
            lastOcrAt = now
            Diagnostics.ocrRuns++
            val full = image.toBitmap()
            val bandTop = if (debugMode) 0 else (full.height * BAND_TOP).toInt()
            val bandBottom = if (debugMode) full.height else (full.height * BAND_BOTTOM).toInt()
            val bitmap = if (bandTop == 0 && bandBottom == full.height) {
                full
            } else {
                Bitmap.createBitmap(full, 0, bandTop, full.width, bandBottom - bandTop).also { full.recycle() }
            }
            val capturedAt = System.currentTimeMillis()
            val ocrStart = SystemClock.elapsedRealtime()
            val client = recognizer
            if (client == null) {
                ocrBusy.set(false)
                bitmap.recycle()
                return
            }
            client.process(InputImage.fromBitmap(bitmap, 0))
                .addOnCompleteListener(ocrExecutor) { task ->
                    // One listener, so the bitmap is still there for the
                    // rarity marks and recycled only afterwards.
                    try {
                        Diagnostics.ocrTotalMs += SystemClock.elapsedRealtime() - ocrStart
                        if (task.isSuccessful) {
                            handleText(task.result, capturedAt, bitmap, bandTop)
                        } else {
                            Log.w(TAG, "OCR failed", task.exception)
                            Diagnostics.ocrErrors++
                            Diagnostics.lastError = "ocr: ${task.exception?.message}"
                        }
                    } catch (e: Exception) {
                        Diagnostics.lastError = "texte: ${e.message}"
                        ServiceLog.error(this, "analyse du texte", e)
                    } finally {
                        bitmap.recycle()
                        ocrBusy.set(false)
                    }
                }
        } catch (e: Exception) {
            Log.w(TAG, "Frame processing failed", e)
            if (Diagnostics.lastError.isEmpty()) ServiceLog.error(this, "traitement d'image", e)
            Diagnostics.lastError = "frame: ${e.message}"
            ocrBusy.set(false)
        } finally {
            image.close()
        }
    }

    private fun Image.toBitmap(): Bitmap {
        val plane = planes[0]
        val pixelStride = plane.pixelStride
        val rowPadding = plane.rowStride - pixelStride * width
        val padded = Bitmap.createBitmap(width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888)
        padded.copyPixelsFromBuffer(plane.buffer)
        if (rowPadding == 0) return padded
        val cropped = Bitmap.createBitmap(padded, 0, 0, width, height)
        padded.recycle()
        return cropped
    }

    /** [yOffset]: top of the analysed band, to store screen coordinates. */
    private fun handleText(text: Text, capturedAt: Long, bitmap: Bitmap, yOffset: Int) {
        val ocrLines = text.textBlocks.flatMap { it.lines }.filter { it.boundingBox != null }
        val lines = ocrLines.map { line ->
            val box = line.boundingBox!!
            OcrLine(line.text, box.left, box.top + yOffset, box.height())
        }
        if (lines.isEmpty()) return

        val fullText = lines.joinToString("\n") { it.text }.lowercase()
        Diagnostics.textFrames++
        Diagnostics.lastText = fullText.take(300)
        if (!debugMode && !looksLikeHackPopup(fullText)) return

        // The result popup stays on screen for several frames: drop exact repeats.
        val key = fullText.filter { it.isLetterOrDigit() }
        if (key == lastStoredKey && capturedAt - lastStoredAt < DEDUP_WINDOW_MS) return
        lastStoredKey = key
        lastStoredAt = capturedAt

        val json = JSONObject()
            .put("ts", capturedAt)
            .put("debug", debugMode)
            .put("w", width)
            .put("h", height)
        val array = JSONArray()
        for ((index, line) in lines.withIndex()) {
            array.put(
                JSONObject()
                    .put("t", RarityMarks.markedText(ocrLines[index], bitmap))
                    .put("x", line.x)
                    .put("y", line.y)
                    .put("h", line.h)
            )
        }
        json.put("lines", array)
        latestLocation?.let {
            json.put("lat", it.latitude)
                .put("lng", it.longitude)
                .put("acc", it.accuracy.toDouble())
                .put("locTs", it.time)
        }
        PendingStore.append(this, json.toString())
        Diagnostics.kept++
    }

    /** Frames worth keeping: hack popup items ("L1 x1 Resonator"), glyph end screen, AP gain. */
    private fun looksLikeHackPopup(text: String) =
        (QUANTITY_TOKEN.containsMatchIn(text) && ITEM_KEYWORDS.any { text.contains(it) }) ||
            // Glyph end screen and "+273 AP" floating after the hack.
            text.contains("hacking bonus") ||
            AP_GAIN.containsMatchIn(text)

    private data class OcrLine(val text: String, val x: Int, val y: Int, val h: Int)
}
