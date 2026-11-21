package io.github.svovoniks.blackpearlmobile

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
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps BlackPearl running after the user closes it, so the phone stays connected to the PC. Its notification shows
 * what plays on the PC, with Play/Pause, and a Turn off button that stops it and switches the setting off.
 */
class BackgroundLinkService : Service() {
    data class Notice(val title: String, val text: String, val playing: Boolean?)

    companion object {
        private const val CHANNEL = "link"
        private const val NOTIFICATION = 7
        private const val ACTION_TOGGLE = "io.github.svovoniks.blackpearlmobile.TOGGLE"
        private const val ACTION_TURN_OFF = "io.github.svovoniks.blackpearlmobile.TURN_OFF"

        @Volatile
        var running = false
            private set
        // Asked to start, and not started yet: its notification still takes updates.
        @Volatile
        private var starting = false
        @Volatile
        private var notice = Notice("BlackPearl", "Connecting to the PC", null)

        /** Starts the service. Android allows it only while the app is showing; then this returns false. */
        fun start(context: Context, next: Notice): Boolean {
            notice = next
            if (running) return update(context, next)
            return try {
                starting = true
                ContextCompat.startForegroundService(context, Intent(context, BackgroundLinkService::class.java))
                true
            } catch (e: IllegalStateException) {
                // ForegroundServiceStartNotAllowedException: the app is in the background.
                starting = false
                false
            }
        }

        fun update(context: Context, next: Notice): Boolean {
            notice = next
            if (!running) return starting
            try {
                NotificationManagerCompat.from(context).notify(NOTIFICATION, build(context, next))
            } catch (e: SecurityException) {
                // No permission to show notifications; the service runs regardless.
            }
            return true
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BackgroundLinkService::class.java))
        }

        private fun channel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Background connection", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while BlackPearl stays connected to your PC with the app closed."
                    setShowBadge(false)
                }
            )
        }

        private fun build(context: Context, notice: Notice): Notification {
            channel(context)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
                flags,
            )
            fun action(name: String, code: Int) = PendingIntent.getService(
                context, code, Intent(context, BackgroundLinkService::class.java).setAction(name), flags,
            )
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_link)
                .setContentTitle(notice.title)
                .setContentText(notice.text)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            notice.playing?.let { playing ->
                builder.addAction(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "Pause" else "Play",
                    action(ACTION_TOGGLE, 1),
                )
            }
            builder.addAction(0, "Turn off", action(ACTION_TURN_OFF, 2))
            return builder.build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Started again by Android after it stopped the app: the engine, and the link, start with it.
        LinkEngine.get(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android stops a service that doesn't show its notification within seconds of starting, so it shows first.
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        try {
            ServiceCompat.startForeground(this, NOTIFICATION, build(this, notice), type)
        } catch (e: Exception) {
            starting = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        starting = false
        when (intent?.action) {
            ACTION_TOGGLE -> LinkEngine.send("toggle")
            ACTION_TURN_OFF -> {
                LinkEngine.send("turnOff")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        starting = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
