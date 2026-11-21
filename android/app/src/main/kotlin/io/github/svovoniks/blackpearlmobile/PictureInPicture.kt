package io.github.svovoniks.blackpearlmobile

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Picture in picture for the phone's player (lib/playback/picture_in_picture.dart). While the player says it wants it
 * (a video plays), leaving the app moves the activity to a small window: by itself on Android 12 and later, and from
 * onUserLeaveHint before that. The window has a Play/Pause button, which the player handles.
 */
class PictureInPicture(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        private const val ACTION_TOGGLE = "io.github.svovoniks.blackpearlmobile.PIP_TOGGLE"
        // The activity's instance that owns the channel now. An old activity going away after a new one attached must
        // not take the handler from it.
        private var current: PictureInPicture? = null
    }

    private val channel = MethodChannel(messenger, "blackpearl/pip")
    private var wanted = false
    private var playing = false
    private var aspect = Rational(16, 9)
    private var registered = false

    private val supported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private val toggle = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            channel.invokeMethod("toggle", null)
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(supported)
                "update" -> {
                    wanted = call.argument<Boolean>("wanted") ?: false
                    playing = call.argument<Boolean>("playing") ?: false
                    val width = call.argument<Int>("width") ?: 16
                    val height = call.argument<Int>("height") ?: 9
                    // Android accepts shapes between 1:2.39 and 2.39:1.
                    val ratio = (width.toDouble() / height.coerceAtLeast(1)).coerceIn(1 / 2.39 + 0.001, 2.39 - 0.001)
                    aspect = Rational((ratio * 1000).toInt(), 1000)
                    apply()
                    result.success(null)
                }
                "enter" -> {
                    if (supported) {
                        try {
                            activity.enterPictureInPictureMode(params())
                        } catch (e: IllegalStateException) {
                            // Not while the activity is stopping.
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        if (supported) {
            ContextCompat.registerReceiver(activity, toggle, IntentFilter(ACTION_TOGGLE), ContextCompat.RECEIVER_NOT_EXPORTED)
            registered = true
        }
        current = this
        // The app may have started without a window (the background service), or this is a new activity: the player
        // says again what it wants.
        channel.invokeMethod("ready", supported)
    }

    private fun params(): PictureInPictureParams {
        val intent = Intent(ACTION_TOGGLE).setPackage(activity.packageName)
        val pending = PendingIntent.getBroadcast(activity, 3, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val icon = Icon.createWithResource(activity, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
        val label = if (playing) "Pause" else "Play"
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .setActions(listOf(RemoteAction(icon, label, label, pending)))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(wanted).setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun apply() {
        if (!supported) return
        try {
            activity.setPictureInPictureParams(params())
        } catch (e: IllegalStateException) {
            // The activity is finishing.
        }
    }

    /** Leaving the app on Android 8 to 11: move to the small window if a video plays. */
    fun userLeaving() {
        if (supported && wanted && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                activity.enterPictureInPictureMode(params())
            } catch (e: IllegalStateException) {
                // Not allowed now.
            }
        }
    }

    fun changed(active: Boolean) = channel.invokeMethod("changed", active)

    /** The small window was closed (picture in picture ended while the activity was stopped). */
    fun dismissed() = channel.invokeMethod("dismissed", null)

    /** The window shows again after the screen was off: the activity starts, but goes no further than paused. */
    fun shown() = channel.invokeMethod("shown", null)

    fun dispose() {
        if (current === this) {
            channel.setMethodCallHandler(null)
            current = null
        }
        if (registered) {
            try {
                activity.unregisterReceiver(toggle)
            } catch (e: IllegalArgumentException) {
            }
            registered = false
        }
    }
}
