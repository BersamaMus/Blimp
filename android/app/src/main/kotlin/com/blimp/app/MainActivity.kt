package com.blimp.app

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Intent
import android.content.IntentSender
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File
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
        if (savedInstanceState == null) {
            handleWidgetIntent(intent)
            handleOpenIntent(intent)
        }
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
                "copySong" -> fileExecutor.execute {
                    try {
                        val path = copySong(call.argument<Number>("id")!!.toLong())
                        runOnUiThread { result.success(path) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("file_error", e.message, null) }
                    }
                }
                "writeSong" -> writeSong(call.argument<Number>("id")!!.toLong(), call.argument<String>("path")!!, result)
                "trashSongs" -> trashSongs(call.argument<List<Number>>("ids")!!.map { it.toLong() }, result)
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
        if (requestCode == CONSENT) {
            val then = consent
            consent = null
            then?.invoke(resultCode == Activity.RESULT_OK)
            return
        }
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

    // ---------------------------------------------------------------------
    // Changing songs' files: tags written back, duplicates thrown away. Other
    // apps' files (most music) can only be changed once the user agrees, in
    // a dialog Android shows.

    /** What to do once the user answers the consent dialog. */
    private var consent: ((Boolean) -> Unit)? = null

    private fun askConsent(sender: IntentSender, then: (Boolean) -> Unit) {
        consent?.invoke(false)
        consent = then
        @Suppress("DEPRECATION")
        startIntentSenderForResult(sender, CONSENT, null, 0, 0, 0)
    }

    private fun songUri(id: Long): Uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)

    /** A copy of the song's file in the app's cache, for its tags to be edited; its path. */
    private fun copySong(id: Long): String {
        val uri = songUri(id)
        val name = displayName(uri) ?: "$id"
        val dir = File(cacheDir, "editing").apply { mkdirs() }
        val copy = File(dir, "$id.${name.substringAfterLast('.', "audio")}")
        contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
        return copy.path
    }

    /**
     * Puts the edited copy at [path] in place of the song's file, then has
     * Android read its tags again. Answers false if the user said no.
     */
    private fun writeSong(id: Long, path: String, result: MethodChannel.Result) {
        val uri = songUri(id)
        fun write() {
            fileExecutor.execute {
                try {
                    // "wt" empties the file first, as the copy may be shorter.
                    contentResolver.openOutputStream(uri, "wt")!!.use { out ->
                        File(path).inputStream().use { it.copyTo(out) }
                    }
                    File(path).delete()
                    rescan(id) { runOnUiThread { result.success(true) } }
                } catch (e: SecurityException) {
                    runOnUiThread { onSecurityException(e, result) { write() } }
                } catch (e: Exception) {
                    runOnUiThread { result.error("file_error", e.message, null) }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            askConsent(MediaStore.createWriteRequest(contentResolver, listOf(uri)).intentSender) { ok ->
                if (ok) write() else result.success(false)
            }
        } else {
            write()
        }
    }

    /**
     * Moves the songs to the trash (Android 11 on, where they can be got back
     * for 30 days), or deletes them on older versions. Answers false if the
     * user said no.
     */
    private fun trashSongs(ids: List<Long>, result: MethodChannel.Result) {
        val uris = ids.map(::songUri)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            askConsent(MediaStore.createTrashRequest(contentResolver, uris, true).intentSender) { result.success(it) }
            return
        }
        fun delete(remaining: List<Uri>) {
            if (remaining.isEmpty()) return result.success(true)
            try {
                contentResolver.delete(remaining.first(), null, null)
                delete(remaining.drop(1))
            } catch (e: SecurityException) {
                onSecurityException(e, result) { delete(remaining) }
            }
        }
        delete(uris)
    }

    /**
     * Android 10 asks the user about each file it won't let the app change
     * ([retry] runs if they agree); older versions need the storage
     * permission, which Dart asks for when told "permission".
     */
    private fun onSecurityException(e: SecurityException, result: MethodChannel.Result, retry: () -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && e is RecoverableSecurityException) {
            askConsent(e.userAction.actionIntent.intentSender) { ok -> if (ok) retry() else result.success(false) }
        } else {
            result.error("permission", e.message, null)
        }
    }

    /** Has Android read the song's file again, then runs [done]. */
    private fun rescan(id: Long, done: () -> Unit) {
        @Suppress("DEPRECATION")
        val path = contentResolver.query(songUri(id), arrayOf(MediaStore.Audio.Media.DATA), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
        if (path == null) return done()
        MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, _ -> done() }
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
        handleOpenIntent(intent)
    }

    /**
     * A song opened with Blimp, from a file manager or another app: passed on
     * to be played, as the library's own song when it's one of them.
     */
    private fun handleOpenIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        // Reopened from Recents, Android hands back the intent that started
        // the task: that file was played back then.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val uri = intent.data ?: return
        val name = try {
            if (uri.scheme == "file") uri.lastPathSegment else displayName(uri)
        } catch (e: Exception) {
            null
        }
        AppChannels.sendOpened(mapOf("uri" to uri.toString(), "id" to librarySongId(uri, name), "name" to name))
    }

    /** The library's id for the song at [uri], if Android's media index has it. */
    private fun librarySongId(uri: Uri, name: String?): Long? = try {
        val audio = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        when {
            uri.authority == MediaStore.AUTHORITY -> ContentUris.parseId(uri)
            uri.scheme == "file" -> @Suppress("DEPRECATION") firstId(audio, "${MediaStore.Audio.Media.DATA}=?", arrayOf(uri.path!!))
            // Another app's file: found by its name and size.
            name != null -> {
                val size = contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
                    if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null
                }
                if (size == null) {
                    null
                } else {
                    firstId(
                        audio,
                        "${MediaStore.Audio.Media.DISPLAY_NAME}=? AND ${MediaStore.Audio.Media.SIZE}=?",
                        arrayOf(name, "$size"),
                    )
                }
            }
            else -> null
        }
    } catch (e: Exception) {
        null
    }

    private fun firstId(uri: Uri, selection: String, args: Array<String>): Long? =
        contentResolver.query(uri, arrayOf(MediaStore.Audio.Media._ID), selection, args, null)?.use {
            if (it.moveToFirst()) it.getLong(0) else null
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
        const val CONSENT = 4202
        const val MAX_FILE = 64 * 1024 * 1024
    }
}
