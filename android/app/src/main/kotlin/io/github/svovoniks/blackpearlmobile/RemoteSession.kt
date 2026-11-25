package io.github.svovoniks.blackpearlmobile

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent

/**
 * The PC's video as a media session of this phone, while the background service runs and the PC plays something the
 * phone can control. Android shows an active session's video on the lock screen and among its media controls, with a
 * timeline and buttons, and, while its playback is "remote" and it plays, gives it the phone's volume buttons, as for a
 * cast. Everything done there goes to the app as an action for the PC ([LinkEngine.send]), and what the PC then says
 * comes back through [show].
 *
 * Headset buttons are another matter: Android sends those to the app that last played sound on the phone itself, so
 * they reach this session only once the app has, as while the phone plays the PC's sound.
 */
object RemoteSession {
    /** What Back and Forward skip, as the Remote tab's buttons. */
    const val STEP_MS = 10_000

    // The volume buttons move the PC's volume this much of its 0 to 100 at a time.
    private const val VOLUME_STEP = 4

    private const val CUSTOM_BACK = "back"
    private const val CUSTOM_FORWARD = "forward"
    private const val CUSTOM_NEXT = "next"
    private const val CUSTOM_DISCONNECT = "disconnect"

    private var session: MediaSession? = null
    private var shown: BackgroundLinkService.Playing? = null

    // What the session last said the video is, without where it is in it: set again only when it changes.
    private var described: List<Any?>? = null

    // The PC's volume as the volume buttons see it; null while they are the phone's own.
    private var volume: VolumeProvider? = null

    // When the buttons last changed the volume. What the PC said before that change reached it doesn't put it back.
    private var volumeSetAt = 0L

    /** The session's token, for the media notification; null while there is no session. */
    val token: MediaSession.Token? get() = session?.sessionToken

    /** Shows what [notice] says the PC plays, or ends the session when it plays nothing the phone can control. */
    fun show(context: Context, notice: BackgroundLinkService.Notice) {
        val media = notice.media
        if (media == null) {
            release()
            return
        }
        val current = session ?: MediaSession(context.applicationContext, "BlackPearl remote").also {
            it.setCallback(callback)
            session = it
            described = null
            volume = null
        }
        shown = media

        val description = listOf(media.title, media.detail, notice.title, media.durationMs)
        if (description != described) {
            described = description
            current.setMetadata(
                MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, media.title)
                    // Under the title: the episode when the PC names one, and always which PC plays it.
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, if (media.detail.isEmpty()) notice.title else "${media.detail} · ${notice.title}")
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, if (media.durationMs > 0) media.durationMs else -1L)
                    .build()
            )
        }
        current.setPlaybackState(state(media, media.positionMs))

        val level = media.volume
        if (level == null) {
            if (volume != null) {
                volume = null
                current.setPlaybackToLocal(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            }
        } else {
            val provider = volume
            if (provider == null) {
                volume = PcVolume(level).also { current.setPlaybackToRemote(it) }
            } else if (SystemClock.elapsedRealtime() - volumeSetAt > 1500) {
                provider.currentVolume = level
            }
        }
        if (!current.isActive) current.isActive = true
    }

    fun release() {
        val current = session ?: return
        session = null
        shown = null
        described = null
        volume = null
        current.isActive = false
        current.release()
    }

    // Where the video is and what can be done to it. From Android 13 the system draws the media controls' buttons from
    // this: Play or Pause, then the custom actions in their order. Next and Previous are not offered as the session's own
    // (their buttons would take the places beside Play, which Back and Forward 10 seconds have here); a headset's Next
    // and Previous buttons are taken in onMediaButtonEvent instead.
    private fun state(media: BackgroundLinkService.Playing, positionMs: Long): PlaybackState {
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_REWIND or PlaybackState.ACTION_FAST_FORWARD
        if (media.durationMs > 0) actions = actions or PlaybackState.ACTION_SEEK_TO
        val builder = PlaybackState.Builder()
            .setActions(actions)
            .setState(if (media.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, positionMs, if (media.playing) 1f else 0f)
            .addCustomAction(PlaybackState.CustomAction.Builder(CUSTOM_BACK, "Back 10 seconds", R.drawable.ic_remote_back_10).build())
            .addCustomAction(PlaybackState.CustomAction.Builder(CUSTOM_FORWARD, "Forward 10 seconds", R.drawable.ic_remote_forward_10).build())
        if (media.hasNext) builder.addCustomAction(PlaybackState.CustomAction.Builder(CUSTOM_NEXT, "Next", R.drawable.ic_remote_next).build())
        builder.addCustomAction(PlaybackState.CustomAction.Builder(CUSTOM_DISCONNECT, "Disconnect", R.drawable.ic_remote_disconnect).build())
        return builder.build()
    }

    private val callback = object : MediaSession.Callback() {
        override fun onPlay() = LinkEngine.send("play")
        override fun onPause() = LinkEngine.send("pause")
        override fun onRewind() = LinkEngine.send("seek-by", -STEP_MS)
        override fun onFastForward() = LinkEngine.send("seek-by", STEP_MS)
        override fun onSkipToNext() = LinkEngine.send("next")
        override fun onSkipToPrevious() = LinkEngine.send("previous")

        override fun onSeekTo(pos: Long) {
            val media = shown ?: return
            val target = pos.coerceIn(0L, if (media.durationMs > 0) media.durationMs else Long.MAX_VALUE)
            LinkEngine.send("seek-to", target.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            // The timeline stays where the finger left it until the PC says where it is.
            session?.setPlaybackState(state(media, target))
        }

        override fun onCustomAction(action: String, extras: Bundle?) {
            when (action) {
                CUSTOM_BACK -> LinkEngine.send("seek-by", -STEP_MS)
                CUSTOM_FORWARD -> LinkEngine.send("seek-by", STEP_MS)
                CUSTOM_NEXT -> LinkEngine.send("next")
                // The app drops the link, and the service and this session go with it.
                CUSTOM_DISCONNECT -> LinkEngine.send("disconnect")
            }
        }

        override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
            @Suppress("DEPRECATION")
            val key: KeyEvent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
            } else {
                mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
            }
            if (key != null && (key.keyCode == KeyEvent.KEYCODE_MEDIA_NEXT || key.keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS)) {
                if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) {
                    LinkEngine.send(if (key.keyCode == KeyEvent.KEYCODE_MEDIA_NEXT) "next" else "previous")
                }
                return true
            }
            return super.onMediaButtonEvent(mediaButtonIntent)
        }
    }

    /** The PC's volume, for the phone's volume buttons and Android's volume panel. */
    private class PcVolume(level: Int) : VolumeProvider(VolumeProvider.VOLUME_CONTROL_ABSOLUTE, 100, level.coerceIn(0, 100)) {
        override fun onSetVolumeTo(volume: Int) = change(volume)

        override fun onAdjustVolume(direction: Int) {
            if (direction != 0) change(currentVolume + direction * VOLUME_STEP)
        }

        private fun change(volume: Int) {
            val level = volume.coerceIn(0, 100)
            volumeSetAt = SystemClock.elapsedRealtime()
            // Shown at once; the PC's own word follows.
            currentVolume = level
            LinkEngine.send("volume", level)
        }
    }
}
