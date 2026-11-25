package io.github.svovoniks.blackpearlmobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps BlackPearl running after the user closes it, so the phone stays connected to the PC. Its notification says how
 * the connection is, with a Disconnect button that drops the link until the app is opened again. While the PC plays a
 * video the phone can control, the notification is a media one ([RemoteSession]): Android then shows the video with
 * its play buttons on the lock screen and among its media controls, and, if the user wants, the volume buttons set the
 * PC's volume.
 */
class BackgroundLinkService : Service() {
    /** What the PC plays, for the media controls. [volume] is the PC's, 0 to 100, when the phone's volume buttons set it. */
    data class Playing(
        val title: String,
        val detail: String,
        val playing: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val hasNext: Boolean,
        val volume: Int?,
    )

    data class Notice(val title: String, val text: String, val playing: Boolean?, val media: Playing? = null)

    companion object {
        private const val CHANNEL = "link"
        private const val NOTIFICATION = 7
        private const val ACTION_TOGGLE = "io.github.svovoniks.blackpearlmobile.TOGGLE"
        private const val ACTION_DISCONNECT = "io.github.svovoniks.blackpearlmobile.DISCONNECT"
        private const val ACTION_BACK = "io.github.svovoniks.blackpearlmobile.BACK"
        private const val ACTION_FORWARD = "io.github.svovoniks.blackpearlmobile.FORWARD"
        private const val ACTION_NEXT = "io.github.svovoniks.blackpearlmobile.NEXT"

        @Volatile
        var running = false
            private set
        // Asked to start, and not started yet: its notification still takes updates.
        @Volatile
        private var starting = false
        @Volatile
        private var notice = Notice("BlackPearl", "Connecting to the PC", null)

        // What the notification last showed. The position moves on with every word from the PC; the notification is
        // posted again only when what it shows changes.
        private var posted: Notice? = null

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
            RemoteSession.show(context, next)
            val shown = shownPart(next)
            if (shown == posted) return true
            try {
                NotificationManagerCompat.from(context).notify(NOTIFICATION, build(context, next))
                posted = shown
            } catch (e: SecurityException) {
                // No permission to show notifications; the service runs regardless.
            }
            return true
        }

        fun stop(context: Context) {
            // Stopped from here on: the service goes away only later (onDestroy), and a start asked for before then must
            // start it again rather than update the one going away.
            running = false
            starting = false
            posted = null
            RemoteSession.release()
            context.stopService(Intent(context, BackgroundLinkService::class.java))
        }

        // A notice without what only the media session follows: where the video is, and the PC's volume.
        private fun shownPart(notice: Notice) = notice.copy(media = notice.media?.copy(positionMs = 0, volume = null))

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
            fun action(icon: Int, label: String, name: String, code: Int) = Notification.Action.Builder(
                Icon.createWithResource(context, icon),
                label,
                PendingIntent.getService(context, code, Intent(context, BackgroundLinkService::class.java).setAction(name), flags),
            ).build()
            val disconnect = action(R.drawable.ic_remote_disconnect, "Disconnect", ACTION_DISCONNECT, 2)

            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
            builder
                .setSmallIcon(R.drawable.ic_stat_link)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            // Before channels, the priority is what keeps it quiet.
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) builder.setPriority(Notification.PRIORITY_LOW)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)

            val media = notice.media
            val token = if (media != null) RemoteSession.token else null
            if (media == null || token == null) {
                // The header says what this is ("BlackPearl · Stays connected to your PC"); the title names the PC.
                builder
                    .setSubText("Stays connected to your PC")
                    .setContentTitle(notice.title)
                    .setContentText(notice.text)
                    .setStyle(
                        Notification.BigTextStyle().bigText(
                            notice.text + "\nBlackPearl keeps the remote ready while the app is closed. Disconnect drops it until you open the app again."
                        )
                    )
                    .setCategory(Notification.CATEGORY_SERVICE)
                notice.playing?.let { playing ->
                    builder.addAction(
                        action(if (playing) R.drawable.ic_remote_pause else R.drawable.ic_remote_play, if (playing) "Pause" else "Play", ACTION_TOGGLE, 1)
                    )
                }
                builder.addAction(disconnect)
                return builder.build()
            }
            // The PC's video, as a media notification: the header names the PC, and the lock screen shows it with its
            // buttons. From Android 13 the system draws the buttons from the session's own actions (RemoteSession); before
            // that, from these, the first three also when the notification is folded.
            builder
                .setSubText(notice.title)
                .setContentTitle(media.title)
                .setContentText(media.detail.ifEmpty { notice.text })
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(action(R.drawable.ic_remote_back_10, "Back 10 seconds", ACTION_BACK, 3))
                .addAction(action(if (media.playing) R.drawable.ic_remote_pause else R.drawable.ic_remote_play, if (media.playing) "Pause" else "Play", ACTION_TOGGLE, 1))
                .addAction(action(R.drawable.ic_remote_forward_10, "Forward 10 seconds", ACTION_FORWARD, 4))
            if (media.hasNext) builder.addAction(action(R.drawable.ic_remote_next, "Next", ACTION_NEXT, 5))
            builder
                .addAction(disconnect)
                .setStyle(Notification.MediaStyle().setMediaSession(token).setShowActionsInCompactView(0, 1, 2))
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
            val current = notice
            RemoteSession.show(this, current)
            ServiceCompat.startForeground(this, NOTIFICATION, build(this, current), type)
            posted = shownPart(current)
        } catch (e: Exception) {
            starting = false
            RemoteSession.release()
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        starting = false
        when (intent?.action) {
            ACTION_TOGGLE -> LinkEngine.send("toggle")
            ACTION_BACK -> LinkEngine.send("seek-by", -RemoteSession.STEP_MS)
            ACTION_FORWARD -> LinkEngine.send("seek-by", RemoteSession.STEP_MS)
            ACTION_NEXT -> LinkEngine.send("next")
            ACTION_DISCONNECT -> {
                LinkEngine.send("disconnect")
                RemoteSession.release()
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        // A start asked for since this one was stopped (starting) is the next service's, and stays: so does its session.
        running = false
        if (!starting) RemoteSession.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
