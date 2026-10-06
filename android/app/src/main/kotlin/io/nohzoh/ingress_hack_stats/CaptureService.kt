package io.nohzoh.ingress_hack_stats

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
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

        /** Minimum delay between two OCR passes. */
        private const val OCR_INTERVAL_MS = 1000L

        /** Same text seen again within this window is not stored twice. */
        private const val DEDUP_WINDOW_MS = 10_000L

        @Volatile var isRunning = false
            private set

        /** When true, every distinct OCR text is stored (for parser calibration). */
        @Volatile var debugMode = false

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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (isRunning) return START_NOT_STICKY

        // Must be in the foreground before getMediaProjection() (Android 14+).
        startInForeground()

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (data == null) {
            Log.w(TAG, "No projection data, stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            startProjection(resultCode, data)
            startLocationUpdates()
            isRunning = true
        } catch (e: Exception) {
            Log.e(TAG, "Unable to start capture", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
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
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Ingress Hack Stats")
            .setContentText("Observation des résultats de hack en cours")
            .setOngoing(true)
            .addAction(0, "Arrêter", stopIntent)
            .build()

        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (hasLocationPermission()) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        startForeground(NOTIFICATION_ID, notification, types)
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
                stopSelf()
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
        try {
            val now = SystemClock.elapsedRealtime()
            if (appVisible || now - lastOcrAt < OCR_INTERVAL_MS) return
            if (!ocrBusy.compareAndSet(false, true)) return
            lastOcrAt = now
            val bitmap = image.toBitmap()
            val capturedAt = System.currentTimeMillis()
            val client = recognizer
            if (client == null) {
                ocrBusy.set(false)
                bitmap.recycle()
                return
            }
            client.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener(ocrExecutor) { text -> handleText(text, capturedAt) }
                .addOnFailureListener(ocrExecutor) { e -> Log.w(TAG, "OCR failed", e) }
                .addOnCompleteListener(ocrExecutor) {
                    bitmap.recycle()
                    ocrBusy.set(false)
                }
        } catch (e: Exception) {
            Log.w(TAG, "Frame processing failed", e)
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

    private fun handleText(text: Text, capturedAt: Long) {
        val lines = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
            val box = line.boundingBox ?: return@mapNotNull null
            OcrLine(line.text, box.left, box.top, box.height())
        }
        if (lines.isEmpty()) return

        val fullText = lines.joinToString("\n") { it.text }.lowercase()
        if (!debugMode && ITEM_KEYWORDS.none { fullText.contains(it) }) return

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
        for (line in lines) {
            array.put(
                JSONObject()
                    .put("t", line.text)
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
    }

    private data class OcrLine(val text: String, val x: Int, val y: Int, val h: Int)
}
