package com.blimp.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

// AudioServiceActivity (a FlutterActivity) shares its Flutter engine with the
// background playback service, so music keeps playing after the app closes.
// The engine's channels to Android are set up in AppChannels; those that need
// a screen to show things on (the file pickers) are here.
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighestRefreshRate()
        // Not when Android restores the activity, which replays the old intent.
        if (savedInstanceState == null) handleWidgetIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "blimp/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> pickFile(
                    Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(call.argument<String>("mime")!!)
                        .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")),
                    result,
                ) { uri -> write(uri, call.argument<ByteArray>("bytes")!!) }
                "open" -> pickFile(
                    Intent(Intent.ACTION_OPEN_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("*/*")
                        .putExtra(Intent.EXTRA_MIME_TYPES, call.argument<List<String>>("mimes")!!.toTypedArray()),
                    result,
                ) { uri -> mapOf("name" to displayName(uri), "bytes" to read(uri)) }
                "restart" -> {
                    result.success(null)
                    restart()
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---------------------------------------------------------------------
    // Android's own Save and Open pickers, which need no storage permission.

    /** The picker waiting for its answer, and what to do with the file picked. */
    private var pending: Pair<MethodChannel.Result, (Uri) -> Any?>? = null
    private val fileExecutor = Executors.newSingleThreadExecutor()

    /**
     * Shows [intent]'s picker, then runs [use] on the file picked, off the
     * main thread, and answers with what it returns; null if nothing was
     * picked, an error if the file couldn't be read or written.
     */
    private fun pickFile(intent: Intent, result: MethodChannel.Result, use: (Uri) -> Any?) {
        pending?.first?.success(null)
        pending = result to use
        @Suppress("DEPRECATION")
        startActivityForResult(intent, PICK_FILE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILE) return
        val (result, use) = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) return result.success(null)
        fileExecutor.execute {
            try {
                val value = use(uri)
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("file_error", e.message, null) }
            }
        }
    }

    private fun write(uri: Uri, bytes: ByteArray): Boolean {
        // "wt" empties a file being replaced first.
        contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
        return true
    }

    private fun read(uri: Uri): ByteArray {
        contentResolver.openInputStream(uri)!!.use { input ->
            // Backups and playlists are small; anything huge isn't one.
            val bytes = input.readBytes()
            require(bytes.size <= MAX_FILE) { "File too large" }
            return bytes
        }
    }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

    /** Starts the app afresh, as after restoring a backup. */
    private fun restart() {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return
        startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        finishAffinity()
        // The playback service would keep the old app running; end it all.
        Runtime.getRuntime().exit(0)
    }

    /**
     * Asks for the screen's fastest refresh rate (90 or 120Hz, say) at its
     * current resolution. Some phones keep apps at 60Hz unless they ask,
     * even with the screen set to its smoothest.
     */
    private fun preferHighestRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay) ?: return
        val current = display.mode
        val fastest = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        window.attributes = window.attributes.apply { preferredDisplayModeId = fastest.modeId }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleWidgetIntent(intent)
    }

    override fun onDestroy() {
        // Closed while paused, the app is likely to be stopped soon, and the
        // widgets wouldn't hear; their buttons open it from now on instead.
        if (!isChangingConfigurations && !HomeWidgets.read(this).playing) HomeWidgets.unload(this)
        super.onDestroy()
    }

    /** Passes on what a home screen widget asked for when it opened the app. */
    private fun handleWidgetIntent(intent: Intent?) {
        val request = intent?.getStringExtra(HomeWidgets.EXTRA_REQUEST) ?: return
        AppChannels.sendWidgetRequest(request)
    }

    private companion object {
        const val PICK_FILE = 4201
        const val MAX_FILE = 64 * 1024 * 1024
    }
}
