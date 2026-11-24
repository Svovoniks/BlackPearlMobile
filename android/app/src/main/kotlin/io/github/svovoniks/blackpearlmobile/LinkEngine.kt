package io.github.svovoniks.blackpearlmobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The app's one Flutter engine, kept apart from the activity. The activity shows it while it is open; when the user
 * closes the app, the engine, and with it the link to the PC, keeps running for as long as [BackgroundLinkService]
 * runs. Opening the app again shows the same engine, already connected.
 */
object LinkEngine {
    private const val ID = "main"
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        sameCrashReportIdForEveryone(app)
        // Plugins register themselves with an engine made this way.
        val engine = FlutterEngine(app)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "blackpearl/background").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> result.success(BackgroundLinkService.start(app, notice(call.arguments)))
                        "update" -> result.success(BackgroundLinkService.update(app, notice(call.arguments)))
                        "stop" -> { BackgroundLinkService.stop(app); result.success(null) }
                        "keepAwake" -> { SoundLocks.set(app, call.arguments == true); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }
        }
        // Debug builds take launch arguments from the opening activity, as FlutterActivity does for its own engine
        // (`am start --esal dart_entrypoint_args ...`).
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val args = if (debuggable && context is android.app.Activity) context.intent?.getStringArrayListExtra("dart_entrypoint_args") else null
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault(), args ?: emptyList())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }

    /**
     * Sentry's Android SDK gives each installation a random id, kept in the file `INSTALLATION` in the app's files
     * folder, and puts it on the crashes it reports itself (Java crashes, ANRs, and through the scope NDK crashes) as
     * the user's and the device's id. Crash reports promise no such id (lib/diagnostics/crash_reports.dart), so every
     * installation gets the same one. It runs before the engine starts Dart, and so before Sentry starts and reads the
     * file.
     */
    private fun sameCrashReportIdForEveryone(app: Context) {
        try {
            val file = java.io.File(app.filesDir, "INSTALLATION")
            if (!file.exists() || file.readText() != SHARED_INSTALLATION_ID) file.writeText(SHARED_INSTALLATION_ID)
        } catch (_: Exception) {
            // Sentry then makes its own id; Settings › Send crash reports still turns reports off.
        }
    }

    private const val SHARED_INSTALLATION_ID = "00000000000000000000000000000000"

    /** Tells the app about a notification button: `toggle` or `disconnect`. */
    fun send(action: String) {
        main.post { channel?.invokeMethod("action", action) }
    }

    private fun notice(arguments: Any?): BackgroundLinkService.Notice {
        val map = arguments as? Map<*, *> ?: emptyMap<String, Any>()
        return BackgroundLinkService.Notice(
            title = map["title"] as? String ?: "BlackPearl",
            text = map["text"] as? String ?: "",
            playing = map["playing"] as? Boolean,
        )
    }
}
