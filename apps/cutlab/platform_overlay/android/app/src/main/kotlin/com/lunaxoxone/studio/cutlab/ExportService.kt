package com.lunaxoxone.studio.cutlab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps CUTLAB running while a video is exported with the app in the
 * background: a foreground service with a progress notification and a
 * partial wake lock (the CPU keeps working with the screen off). The
 * rendering itself happens in the media engine's own thread; this service
 * only keeps the process alive and shows where the export is.
 */
class ExportService : Service() {
    companion object {
        const val CHANNEL = "cutlab_export"
        const val NOTIFICATION_ID = 7301
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"  // 0..1000, -1 = unknown
        const val ACTION_UPDATE = "update"
        const val ACTION_STOP = "stop"

        fun start(context: Context, text: String) {
            val i = Intent(context, ExportService::class.java).putExtra(EXTRA_TEXT, text).putExtra(EXTRA_PROGRESS, -1)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        fun update(context: Context, text: String, progress: Int) {
            context.startService(
                Intent(context, ExportService::class.java).setAction(ACTION_UPDATE).putExtra(EXTRA_TEXT, text).putExtra(EXTRA_PROGRESS, progress)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ExportService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Exporting video"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        val n = notification(text, progress)
        if (intent?.action == ACTION_UPDATE) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, n)
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cutlab:export").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)  // released when the export ends; 6 h at most
            }
        }
        // Not restarted if Android stops it: the export lives in the app process.
        return START_NOT_STICKY
    }

    private fun notification(text: String, progress: Int): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Video export", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("CUTLAB export")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
        if (progress >= 0) b.setProgress(1000, progress, false) else b.setProgress(0, 0, true)
        return b.build()
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}
