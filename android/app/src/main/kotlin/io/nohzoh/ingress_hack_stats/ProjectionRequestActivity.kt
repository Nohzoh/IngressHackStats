package io.nohzoh.ingress_hack_stats

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

/**
 * Invisible activity started from the quick settings tile: shows Android's
 * screen-capture consent over the game, starts the capture and closes, so
 * the player never leaves Ingress.
 */
class ProjectionRequestActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        ServiceLog.log(this, "tuile : demande de partage d'écran")
        val manager = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(manager.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                CaptureService.start(this, resultCode, data, from = "tuile")
            } else {
                ServiceLog.log(this, "tuile : partage d'écran refusé (code $resultCode)")
            }
        }
        finish()
    }

    companion object {
        private const val REQ_PROJECTION = 4301
    }
}
