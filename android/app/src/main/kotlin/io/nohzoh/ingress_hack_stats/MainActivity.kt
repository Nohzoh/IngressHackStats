package io.nohzoh.ingress_hack_stats

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Flutter and the capture service:
 *  - startCapture: asks runtime permissions, then the screen-capture consent,
 *    then starts [CaptureService].
 *  - stopCapture / isRunning / setDebug
 *  - drainPending: returns the OCR captures written by the service since the
 *    last call (one JSON object per string) and clears them.
 */
class MainActivity : FlutterActivity() {

    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ServiceLog.installCrashHandler(this)
        CaptureService.ocrIntervalMs = prefs().getLong(PREF_OCR_INTERVAL, CaptureService.DEFAULT_OCR_INTERVAL_MS)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> startCapture(result)
                    "stopCapture" -> {
                        stopService(Intent(this, CaptureService::class.java))
                        result.success(null)
                    }
                    "isRunning" -> result.success(CaptureService.isRunning)
                    "setDebug" -> {
                        CaptureService.debugMode = call.argument<Boolean>("enabled") == true
                        result.success(null)
                    }
                    "isDebug" -> result.success(CaptureService.debugMode)
                    "getOcrInterval" -> result.success(CaptureService.ocrIntervalMs)
                    "setOcrInterval" -> {
                        val ms = (call.argument<Number>("ms")?.toLong() ?: CaptureService.DEFAULT_OCR_INTERVAL_MS)
                            .coerceIn(100L, 5_000L)
                        CaptureService.ocrIntervalMs = ms
                        prefs().edit().putLong(PREF_OCR_INTERVAL, ms).apply()
                        result.success(null)
                    }
                    "drainPending" -> result.success(PendingStore.drain(this))
                    "diagnostics" -> result.success(Diagnostics.toMap())
                    "serviceLog" -> result.success(ServiceLog.read(this))
                    "clearServiceLog" -> {
                        ServiceLog.clear(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        // While our own UI is visible the service skips OCR, otherwise it would
        // read our stats screen (full of item names) as hack results.
        CaptureService.appVisible = true
    }

    override fun onPause() {
        CaptureService.appVisible = false
        super.onPause()
    }

    private fun startCapture(result: MethodChannel.Result) {
        if (CaptureService.isRunning) {
            result.success(true)
            return
        }
        if (pendingStartResult != null) {
            result.error("BUSY", "A start request is already in progress", null)
            return
        }
        pendingStartResult = result
        ServiceLog.log(this, "app : bouton Démarrer")
        if (!requestMissingPermissions()) requestProjection()
    }

    /** Returns true if a permission dialog was shown (flow continues in the callback). */
    private fun requestMissingPermissions(): Boolean {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !granted(Manifest.permission.POST_NOTIFICATIONS)) {
            missing += Manifest.permission.POST_NOTIFICATIONS
        }
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            missing += Manifest.permission.ACCESS_FINE_LOCATION
            missing += Manifest.permission.ACCESS_COARSE_LOCATION
        }
        if (missing.isEmpty()) return false
        requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Location and notifications are optional: capture works without them.
        if (requestCode != REQ_PERMISSIONS) return
        val summary = permissions.indices.joinToString { i ->
            "${permissions[i].substringAfterLast('.')}=${if (grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED) "oui" else "non"}"
        }
        ServiceLog.log(this, "app : autorisations $summary")
        if (pendingStartResult != null) requestProjection()
    }

    private fun requestProjection() {
        val manager = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(manager.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PROJECTION) return
        val result = pendingStartResult
        pendingStartResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            ServiceLog.log(this, "app : partage d'écran refusé (code $resultCode)")
            result?.success(false)
            return
        }
        ServiceLog.log(this, "app : partage d'écran accepté, lancement du service")
        val intent = Intent(this, CaptureService::class.java)
            .putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(CaptureService.EXTRA_DATA, data)
        try {
            ContextCompat.startForegroundService(this, intent)
            result?.success(true)
        } catch (e: Exception) {
            ServiceLog.error(this, "lancement du service", e)
            result?.success(false)
        }
    }

    private fun prefs() = getSharedPreferences("settings", MODE_PRIVATE)

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val CHANNEL = "ingresshackstats/capture"
        private const val PREF_OCR_INTERVAL = "ocrIntervalMs"
        private const val REQ_PERMISSIONS = 4201
        private const val REQ_PROJECTION = 4202
    }
}
