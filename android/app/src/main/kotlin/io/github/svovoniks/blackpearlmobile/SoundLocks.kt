package io.github.svovoniks.blackpearlmobile

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager

/**
 * Held while the phone plays the PC's sound. With the screen off, Android lets the processor sleep between the audio
 * it has queued and puts Wi-Fi in power saving, which holds the PC's answers back for hundreds of milliseconds: the
 * sound would stutter and drift from the picture. The background service keeps the app itself running.
 */
object SoundLocks {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var lowLatency: WifiManager.WifiLock? = null

    @Suppress("DEPRECATION")
    fun set(context: Context, hold: Boolean) {
        if (hold) {
            if (wake == null) {
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "BlackPearl:sound").apply { setReferenceCounted(false); acquire() }
            }
            val manager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
            // High performance keeps Wi-Fi out of power saving with the screen off; it is deprecated from Android 14,
            // whose low latency mode applies only while the app shows. Both are held: each covers what the other doesn't.
            if (wifi == null) {
                wifi = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "BlackPearl:sound").apply { setReferenceCounted(false); acquire() }
            }
            if (lowLatency == null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                lowLatency = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "BlackPearl:sound-low-latency").apply { setReferenceCounted(false); acquire() }
            }
        } else {
            wake?.let { if (it.isHeld) it.release() }
            wake = null
            wifi?.let { if (it.isHeld) it.release() }
            wifi = null
            lowLatency?.let { if (it.isHeld) it.release() }
            lowLatency = null
        }
    }
}
