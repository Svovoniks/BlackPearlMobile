package io.github.svovoniks.blackpearlmobile

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
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

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPicture?.changed(isInPictureInPictureMode)
    }

    override fun onDestroy() {
        pictureInPicture?.dispose()
        pictureInPicture = null
        super.onDestroy()
    }
}
