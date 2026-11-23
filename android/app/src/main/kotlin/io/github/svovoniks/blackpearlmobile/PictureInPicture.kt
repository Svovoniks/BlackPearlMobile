package io.github.svovoniks.blackpearlmobile

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.database.ContentObserver
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Rational
import android.view.OrientationEventListener
import android.view.Surface
import kotlin.math.abs
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

    // The player's shape full screen (Configuration.ORIENTATION_*), the last time it was seen there, and whether the
    // device's natural shape is portrait (a phone) or landscape (most tablets).
    private var fullShape = Configuration.ORIENTATION_UNDEFINED
    private var naturalPortrait = true
    // While the video is in the small window and after it comes back, the activity keeps the shape it had full screen.
    // Without that it comes back in whatever shape the home screen or the other app had, which is portrait while the
    // phone is held upright to use it (with auto-rotate on).
    private var holding = false
    private var turning: OrientationEventListener? = null
    private var watching: ContentObserver? = null

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
                // The player closed: turning the phone works as before.
                "release" -> {
                    release()
                    result.success(null)
                }
                "enter" -> {
                    if (supported) {
                        sawFullScreen()
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

    /**
     * Notes the activity's shape while it fills the screen (not as the small window), to give it back after the small
     * window. Called on every configuration change, on resume, and just before the small window opens.
     */
    fun sawFullScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode) return
        // Coming back from the small window, the held shape is what the activity has, not what the user chose.
        if (holding) return
        val shape = activity.resources.configuration.orientation
        if (shape != Configuration.ORIENTATION_PORTRAIT && shape != Configuration.ORIENTATION_LANDSCAPE) return
        val rotation = displayRotation() ?: return
        fullShape = shape
        val upright = rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_180
        naturalPortrait = upright == (shape == Configuration.ORIENTATION_PORTRAIT)
    }

    private fun displayRotation(): Int? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }
    } catch (e: UnsupportedOperationException) {
        null
    }

    /** The video moved to the small window: it comes back in the shape it had full screen. */
    fun entered() {
        // Back to the small window before the phone was turned to match: the same shape stays held, and turning the
        // phone while the small window shows changes nothing.
        stopFollowing()
        if (holding) return
        val requested = when (fullShape) {
            // Either way up, as the sensor (or the locked rotation) says; most phones show landscape both ways.
            Configuration.ORIENTATION_LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE
            Configuration.ORIENTATION_PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT
            else -> return
        }
        holding = true
        activity.requestedOrientation = requested
    }

    /**
     * Back from the small window, in the held shape. With auto-rotate on, turning the phone works again once the phone
     * is held that way (as in other video players, which come back sideways and follow the phone after it is turned
     * to match). With auto-rotate off, it works again once Android's locked rotation has the same shape, which Android
     * restores a moment after the window expands; otherwise the player keeps the shape until it closes, which releases
     * it (player_screen.dart).
     */
    fun expanded() {
        if (!holding) return
        if (watching == null) {
            val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) = followWhenMatched()
            }
            val resolver = activity.contentResolver
            resolver.registerContentObserver(Settings.System.getUriFor(Settings.System.ACCELEROMETER_ROTATION), false, observer)
            resolver.registerContentObserver(Settings.System.getUriFor(Settings.System.USER_ROTATION), false, observer)
            watching = observer
        }
        followWhenMatched()
    }

    private fun followWhenMatched() {
        turning?.disable()
        turning = null
        if (!holding) return
        val resolver = activity.contentResolver
        if (Settings.System.getInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 0) != 1) {
            val locked = Settings.System.getInt(resolver, Settings.System.USER_ROTATION, Surface.ROTATION_0)
            if (shapeOf(locked == Surface.ROTATION_90 || locked == Surface.ROTATION_270) == fullShape) release()
            return
        }
        val listener = object : OrientationEventListener(activity) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return
                // Well inside a quarter, so a phone held at an angle doesn't count.
                val nearest = ((degrees + 45) / 90) % 4
                if (abs(degrees - nearest * 90).let { minOf(it, 360 - it) } > 30) return
                if (shapeOf(nearest % 2 == 1) == fullShape) release()
            }
        }
        if (!listener.canDetectOrientation()) {
            release()
            return
        }
        turning = listener
        listener.enable()
    }

    // The shape the device has when turned a quarter from its natural shape, or not.
    private fun shapeOf(quarterTurned: Boolean): Int =
        if (naturalPortrait != quarterTurned) Configuration.ORIENTATION_PORTRAIT else Configuration.ORIENTATION_LANDSCAPE

    /** Turning the phone works as before again: the small window was closed, or the phone was turned to match. */
    fun release() {
        stopFollowing()
        if (!holding) return
        holding = false
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    private fun stopFollowing() {
        turning?.disable()
        turning = null
        watching?.let { activity.contentResolver.unregisterContentObserver(it) }
        watching = null
    }

    /** Leaving the app on Android 8 to 11: move to the small window if a video plays. */
    fun userLeaving() {
        sawFullScreen()
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
        stopFollowing()
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
