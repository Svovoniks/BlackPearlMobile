package io.github.svovoniks.blackpearlmobile

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import androidx.lifecycle.Lifecycle
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    // Downloaded updates live here; res/xml/update_files.xml shares only this folder with the installer.
    private val updateFolder get() = File(cacheDir, "updates")

    // The engine outlives the activity (see LinkEngine), so closing the app leaves the link to the PC running while
    // the background service runs, and opening it again shows the same app.
    override fun provideFlutterEngine(context: Context): FlutterEngine = LinkEngine.get(this)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var pictureInPicture: PictureInPicture? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pictureInPicture?.dispose()
        pictureInPicture = PictureInPicture(this, flutterEngine.dartExecutor.binaryMessenger)
        // The camera cutout's safe insets, in pixels. Flutter reports none while the system bars are hidden, which is
        // when the player needs them.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "blackpearl/display").setMethodCallHandler { call, result ->
            if (call.method == "cutout") {
                // In the window's current rotation, whether or not the bars show.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val insets = windowManager.currentWindowMetrics.windowInsets.getInsetsIgnoringVisibility(android.view.WindowInsets.Type.displayCutout())
                    result.success(mapOf("left" to insets.left, "top" to insets.top, "right" to insets.right, "bottom" to insets.bottom))
                } else {
                    val cutout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) window?.decorView?.rootWindowInsets?.displayCutout else null
                    result.success(
                        mapOf(
                            "left" to (cutout?.safeInsetLeft ?: 0),
                            "top" to (cutout?.safeInsetTop ?: 0),
                            "right" to (cutout?.safeInsetRight ?: 0),
                            "bottom" to (cutout?.safeInsetBottom ?: 0),
                        )
                    )
                }
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "blackpearl/notifications").setMethodCallHandler { call, result ->
            if (call.method == "request") {
                // Android 13 and later show the background service's notification only with this permission.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "blackpearl/updates").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "updateFolder" -> result.success(updateFolder.apply { mkdirs() }.absolutePath)
                    // Android 8 and later ask once whether this app may install apps; before that it was one system setting.
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                    )
                    "allowInstalls" -> {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                        } else {
                            Intent(Settings.ACTION_SECURITY_SETTINGS)
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "install" -> {
                        val file = File(call.argument<String>("path") ?: "").canonicalFile
                        if (file.parentFile != updateFolder.canonicalFile || !file.isFile || !file.name.endsWith(".apk")) {
                            result.error("path", "Not a downloaded update", null)
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            startActivity(
                                Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            )
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("failed", e.message, null)
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        pictureInPicture?.userLeaving()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        pictureInPicture?.sawFullScreen()
    }

    override fun onResume() {
        super.onResume()
        pictureInPicture?.sawFullScreen()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPicture?.changed(isInPictureInPictureMode)
        when {
            isInPictureInPictureMode -> pictureInPicture?.entered()
            // Leaving picture in picture while stopped means its window was closed, not expanded back to the app.
            // (Stopping while still in picture in picture is the screen turning off, which keeps the window.)
            lifecycle.currentState == Lifecycle.State.CREATED -> {
                pictureInPicture?.release()
                pictureInPicture?.dismissed()
            }
            else -> pictureInPicture?.expanded()
        }
    }

    override fun onStart() {
        super.onStart()
        // Flutter hears "resumed" only from onResume, which a picture-in-picture window doesn't reach after the screen
        // was off; the app still believes it is in the background.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode) pictureInPicture?.shown()
        pictureInPicture?.visible()
    }

    override fun onStop() {
        pictureInPicture?.hidden()
        super.onStop()
    }

    override fun onDestroy() {
        pictureInPicture?.dispose()
        pictureInPicture = null
        super.onDestroy()
    }
}
