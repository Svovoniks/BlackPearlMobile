package io.github.svovoniks.blackpearlmobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The phone's Wi-Fi or Ethernet, for reaching the PC on its home network when the room server can't introduce them
 * (PHONE-REMOTE.md, "On the home network"; lib/connection/local_network.dart).
 *
 * When the home internet is down, Android finds the Wi-Fi has no internet and makes mobile data the default network.
 * Sockets the app opens go out on the default network, so the PC's home address would be tried over mobile data and
 * never answer. While the app opens its sockets to the PC, `bind` makes the Wi-Fi this process's network, and `unbind`
 * gives the choice back to Android; sockets opened meanwhile stay on the Wi-Fi. The app's sockets to the PC are the
 * home-network socket and then the link's ICE sockets, which libdatachannel opens as the offer is made.
 */
object LocalNetwork {
    fun register(context: Context, messenger: BinaryMessenger) {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        MethodChannel(messenger, "blackpearl/network").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "available" -> result.success(local(connectivity) != null)
                    "bind" -> {
                        val network = local(connectivity)
                        // Nothing to do when the Wi-Fi is the default network already, or there is none.
                        if (network == null || network == connectivity.activeNetwork) result.success(false)
                        else result.success(connectivity.bindProcessToNetwork(network))
                    }
                    "unbind" -> {
                        connectivity.bindProcessToNetwork(null)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("failed", e.message, null)
            }
        }
    }

    /** A connected Wi-Fi or Ethernet network: the default one when it is one, else the first Android lists. */
    @Suppress("DEPRECATION")
    private fun local(connectivity: ConnectivityManager): Network? {
        fun isLocal(network: Network?): Boolean {
            val capabilities = network?.let { connectivity.getNetworkCapabilities(it) } ?: return false
            return (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        connectivity.activeNetwork?.let { if (isLocal(it)) return it }
        return connectivity.allNetworks.firstOrNull { isLocal(it) }
    }
}
