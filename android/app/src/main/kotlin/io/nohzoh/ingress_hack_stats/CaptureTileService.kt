package io.nohzoh.ingress_hack_stats

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick settings tile: starts or stops the capture without leaving the game. */
class CaptureTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        if (CaptureService.isRunning) {
            ServiceLog.log(this, "tuile : arrêt de la capture")
            stopService(Intent(this, CaptureService::class.java))
            refresh(running = false)
            return
        }
        val intent = Intent(this, ProjectionRequestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun refresh(running: Boolean = CaptureService.isRunning) {
        val tile = qsTile ?: return
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (running) "En cours" else "Arrêtée"
        }
        tile.updateTile()
    }

    companion object {
        /** Asks the system to refresh the tile (after a start or a stop). */
        fun requestUpdate(context: Context) {
            try {
                requestListeningState(context, ComponentName(context, CaptureTileService::class.java))
            } catch (_: Exception) {
                // Tile not added: nothing to refresh.
            }
        }
    }
}
