package com.blimp.app

import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.audiofx.Visualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * The app's channels to Android: the music library ("blimp/media"), the home
 * screen widgets ("blimp/widgets") and the visualizer ("blimp/visualizer").
 *
 * They're set up for every Flutter engine as it starts (see BlimpApplication),
 * not just when the app's screen opens: Android Auto can start the playback
 * service, and the app with it, without one.
 */
object AppChannels {
    private var widgets: MethodChannel? = null
    private var opener: MethodChannel? = null

    /** Files opened with Blimp (from a file manager, say) not yet taken by the app. */
    private val opened = mutableListOf<Map<String, Any?>>()

    /**
     * What a widget asked for when it opened the app (see
     * [HomeWidgets.EXTRA_REQUEST]), if the app hasn't done it yet.
     */
    private var widgetRequest: String? = null

    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        val media = MediaHandler(app)
        MethodChannel(messenger, "blimp/media").setMethodCallHandler { call, result ->
            // Opens Android's share sheet, so it runs here, on the main thread.
            if (call.method == "shareSong") {
                media.shareSong(call.argument<Number>("id")!!.toLong(), call.argument("title"))
                result.success(null)
                return@setMethodCallHandler
            }
            val executor = when (call.method) {
                "getArtwork" -> MediaHandler.artworkExecutor
                "getWaveform", "getGain" -> MediaHandler.waveformExecutor
                "getReleaseTypes", "getHiRes", "getLyricsBatch", "getLyricsStamps" -> MediaHandler.releaseTypeExecutor
                else -> MediaHandler.queryExecutor
            }
            executor.execute {
                try {
                    val value: Any? = when (call.method) {
                        "getSongs" -> media.getSongs()
                        "getArtwork" -> media.getArtwork(
                            call.argument<Number>("id")!!.toLong(),
                            call.argument<Number>("size")?.toInt() ?: 256,
                        )
                        "getAudioFormat" -> media.getAudioFormat(call.argument<Number>("id")!!.toLong())
                        "getFileInfo" -> media.getFileInfo(call.argument<Number>("id")!!.toLong())
                        "getWaveform" -> media.getWaveform(
                            call.argument<Number>("id")!!.toLong(),
                            call.argument<Number>("points")!!.toInt(),
                        )
                        "openFolder" -> media.openFolder(call.argument<String>("path")!!)
                        "getLyrics" -> media.getLyrics(call.argument<Number>("id")!!.toLong())
                        "getEmbeddedLyrics" -> media.getEmbeddedLyrics(call.argument<Number>("id")!!.toLong())
                        "getGain" -> media.getGain(call.argument<Number>("id")!!.toLong())
                        "getReleaseTypes" -> media.getReleaseTypes(call.argument<List<Number>>("ids")!!.map { it.toLong() })
                        "getHiRes" -> media.getHiRes(call.argument<List<Map<String, Any?>>>("songs")!!)
                        "getLyricsBatch" -> media.getLyricsBatch(call.argument<List<Number>>("ids")!!.map { it.toLong() })
                        "getLyricsStamps" -> media.getLyricsStamps(call.argument<List<Map<String, Any?>>>("songs")!!)
                        else -> {
                            main.post { result.notImplemented() }
                            return@execute
                        }
                    }
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    main.post { result.error("media_error", e.message, null) }
                }
            }
        }

        // What the home screen widgets show.
        widgets = MethodChannel(messenger, "blimp/widgets").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        HomeWidgets.save(
                            app,
                            songId = call.argument<Number>("songId")?.toLong(),
                            title = call.argument("title"),
                            artist = call.argument("artist"),
                            album = call.argument("album"),
                            playing = call.argument<Boolean>("playing") ?: false,
                        )
                        result.success(null)
                    }
                    "clear" -> {
                        HomeWidgets.clear(app)
                        result.success(null)
                    }
                    "setColors" -> {
                        HomeWidgets.setColors(
                            app,
                            accent = call.argument<Number>("accent")!!.toInt(),
                            onAccent = call.argument<Number>("onAccent")!!.toInt(),
                        )
                        result.success(null)
                    }
                    // Asked once the app has started, in case a widget opened
                    // it before the app was ready to hear about it.
                    "takeRequest" -> {
                        result.success(widgetRequest)
                        widgetRequest = null
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Files opened with Blimp: kept until the app takes them, as it may
        // still be starting; it's told when more come.
        opener = MethodChannel(messenger, "blimp/open").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeOpened") {
                    result.success(opened.toList())
                    opened.clear()
                } else {
                    result.notImplemented()
                }
            }
        }

        EventChannel(messenger, "blimp/visualizer")
            .setStreamHandler(VisualizerStreamHandler(app.getSystemService(AudioManager::class.java)))
    }

    /** Hands a file opened with Blimp to the app, which plays it. */
    fun sendOpened(file: Map<String, Any?>) {
        opened.add(file)
        opener?.invokeMethod("opened", null)
    }

    /**
     * Passes on what a widget asked for when it opened the app. The app may
     * still be starting, so the request is also kept for it to take once
     * it's ready.
     */
    fun sendWidgetRequest(request: String) {
        widgetRequest = request
        widgets?.invokeMethod("request", request, object : MethodChannel.Result {
            override fun success(result: Any?) {
                widgetRequest = null
            }

            override fun error(code: String, message: String?, details: Any?) {}

            override fun notImplemented() {}
        })
    }
}

/** Reads the music library, its files and their artwork, for "blimp/media". */
private class MediaHandler(private val context: Context) {
    companion object {
        // MediaStore queries hit disk, so keep them off the UI thread. Artwork
        // gets its own small pool so thumbnails decode in parallel and never wait
        // behind a library scan; the Dart side caps requests at the same number.
        // They live as long as the process, as the Flutter engine does.
        val queryExecutor = Executors.newSingleThreadExecutor()
        val artworkExecutor = Executors.newFixedThreadPool(3)

        // Decoding a whole song for its waveform takes a moment, so it gets a
        // thread of its own rather than holding up the others.
        val waveformExecutor = Executors.newSingleThreadExecutor()

        // Reading every album's tags after a scan takes a while; on its own
        // thread, it holds up nothing else.
        val releaseTypeExecutor = Executors.newSingleThreadExecutor()

        /** How many frames from each slice of a song its waveform is worked out from. */
        private const val BURST_FRAMES = 5

        /** Slices sampled to measure a song's loudness: enough to average out its quiet parts. */
        private const val GAIN_POINTS = 40

        /**
         * The loudness (RMS, dB of full scale) measured songs are brought to.
         * Picked so measured songs land about where ReplayGain tags put
         * theirs, since a library holds both.
         */
        private const val MEASURED_TARGET_DB = -17.0
    }

    fun getSongs(): List<Map<String, Any?>> {
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        // GENRE, ALBUM_ARTIST, COMPILATION and DISC_NUMBER are only columns
        // of the audio table from Android 11.
        val r = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        val projection = listOfNotNull(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.YEAR,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.SIZE,
            // Deprecated for opening files, but still the file's path, for
            // browsing by folder.
            @Suppress("DEPRECATION") MediaStore.Audio.Media.DATA,
            if (r) MediaStore.Audio.Media.GENRE else null,
            if (r) MediaStore.Audio.Media.ALBUM_ARTIST else null,
            if (r) MediaStore.Audio.Media.COMPILATION else null,
            if (r) MediaStore.Audio.Media.DISC_NUMBER else null,
            MediaStore.Audio.Media.IS_PODCAST,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.Audio.Media.IS_AUDIOBOOK else null,
        ).toTypedArray()
        val songs = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            collection,
            projection,
            songSelection(),
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumIdCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val trackCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TRACK)
            val yearCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.YEAR)
            val dateAddedCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            @Suppress("DEPRECATION")
            val pathCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val genreCol = if (r) cursor.getColumnIndex(MediaStore.Audio.Media.GENRE) else -1
            val albumArtistCol = if (r) cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ARTIST) else -1
            val compilationCol = if (r) cursor.getColumnIndex(MediaStore.Audio.Media.COMPILATION) else -1
            val discCol = if (r) cursor.getColumnIndex(MediaStore.Audio.Media.DISC_NUMBER) else -1
            val podcastCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.IS_PODCAST)
            val audiobookCol = cursor.getColumnIndex(MediaStore.Audio.Media.IS_AUDIOBOOK)
            while (cursor.moveToNext()) {
                val path = cursor.getString(pathCol)
                if (VoiceRecordings.isRecording(path)) continue
                val id = cursor.getLong(idCol)
                val track = cursor.getInt(trackCol)
                songs.add(
                    mapOf(
                        "id" to id,
                        "title" to cursor.getString(titleCol)?.fixMojibake(),
                        "artist" to cursor.getString(artistCol)?.takeIf { it != MediaStore.UNKNOWN_STRING }?.fixMojibake(),
                        "album" to cursor.getString(albumCol)?.fixMojibake(),
                        "albumId" to cursor.getLong(albumIdCol),
                        "albumArtist" to if (albumArtistCol >= 0) cursor.getString(albumArtistCol)?.fixMojibake() else null,
                        "compilation" to (compilationCol >= 0 && cursor.getString(compilationCol)?.trim() == "1"),
                        "duration" to cursor.getLong(durationCol),
                        // TRACK is encoded as disc * 1000 + track; DISC_NUMBER
                        // ("2" or "2/3") is the disc where that leaves it out.
                        "track" to track % 1000,
                        "disc" to ((track / 1000).takeIf { it > 0 }
                            ?: if (discCol >= 0) cursor.getString(discCol)?.substringBefore('/')?.trim()?.toIntOrNull() else null),
                        "year" to cursor.getInt(yearCol).takeIf { it > 0 },
                        "dateAdded" to cursor.getLong(dateAddedCol),
                        "size" to cursor.getLong(sizeCol),
                        "path" to path,
                        "genre" to if (genreCol >= 0) cursor.getString(genreCol)?.fixMojibake() else null,
                        // Podcasts and audiobooks carry on where they were left.
                        "spoken" to (cursor.getInt(podcastCol) != 0 || (audiobookCol >= 0 && cursor.getInt(audiobookCol) != 0)),
                        "uri" to ContentUris.withAppendedId(collection, id).toString(),
                    )
                )
            }
        }
        return songs
    }

    /**
     * Music, podcasts and audiobooks; not ringtones, alarms or notification
     * sounds. Android 12 and later also mark voice recordings, which are left
     * out ([VoiceRecordings] catches those made before, or in other folders).
     */
    private fun songSelection(): String {
        val kinds = listOfNotNull(
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            "${MediaStore.Audio.Media.IS_PODCAST} != 0",
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) "${MediaStore.Audio.Media.IS_AUDIOBOOK} != 0" else null,
        )
        val notRecording = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            " AND ${MediaStore.Audio.Media.IS_RECORDING} = 0"
        } else {
            ""
        }
        return kinds.joinToString(" OR ", "(", ")") + notRecording
    }

    /**
     * How the song's audio is encoded, as a map of `mime` (the codec, e.g.
     * audio/mpeg), `sampleRate` (Hz), `bitrate` (bits per second), `bitsPerSample`
     * and `channels`; each is left out when the file doesn't say.
     */
    fun getAudioFormat(id: Long): Map<String, Any?> {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val format = mutableMapOf<String, Any?>()
        // The extractor knows the codec and channels for every format Android plays.
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount)
                .map { extractor.getTrackFormat(it) }
                .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            if (track != null) {
                format["mime"] = track.getString(MediaFormat.KEY_MIME)
                format["sampleRate"] = track.intOrNull(MediaFormat.KEY_SAMPLE_RATE)
                format["channels"] = track.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)
                format["bitrate"] = track.intOrNull(MediaFormat.KEY_BIT_RATE)
                // WAV comes out as raw PCM, whose encoding gives its bit depth.
                format["bitsPerSample"] = when (track.intOrNull(MediaFormat.KEY_PCM_ENCODING)) {
                    AudioFormat.ENCODING_PCM_8BIT -> 8
                    AudioFormat.ENCODING_PCM_16BIT -> 16
                    AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                    AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 32
                    else -> if (track.getString(MediaFormat.KEY_MIME) == "audio/raw") 16 else null
                }
            }
        } catch (e: Exception) {
            // Unreadable: fall through to whatever the retriever finds.
        } finally {
            extractor.release()
        }
        // The retriever reads the file's tags for the rest, and is the better
        // source of bitrate: extractors often leave it out.
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
                ?.let { format["bitrate"] = it }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_SAMPLERATE)?.toIntOrNull()
                    ?.takeIf { it > 0 }?.let { format["sampleRate"] = it }
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITS_PER_SAMPLE)?.toIntOrNull()
                    ?.takeIf { it > 0 }?.let { format["bitsPerSample"] = it }
            }
            if (format["mime"] == null) {
                format["mime"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            }
        } catch (e: Exception) {
            // Keep what the extractor found.
        } finally {
            retriever.release()
        }
        return format.filterValues { it != null }
    }

    /**
     * Where the song's file is: `name` (e.g. Song.mp3), `path` (the full path,
     * for showing and opening its folder) and `modified` (seconds since 1970).
     */
    fun getFileInfo(id: Long): Map<String, Any?> {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val projection = arrayOf(
            MediaStore.Audio.Media.DISPLAY_NAME,
            // Deprecated for opening files, but still the file's path to show.
            @Suppress("DEPRECATION") MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DATE_MODIFIED,
        )
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return mapOf(
                    "name" to cursor.getString(0),
                    "path" to cursor.getString(1),
                    "modified" to cursor.getLong(2).takeIf { it > 0 },
                )
            }
        }
        return emptyMap()
    }

    /** The song's lyrics as saved (see [readLyrics]). Null if there are none. */
    fun getLyrics(id: Long): String? = readLyrics(id, strict = false)

    /**
     * Just the lyrics saved inside the song's file, not a .lrc file beside it,
     * for the tag editor. Null if it has none; throws if it can't be read.
     */
    fun getEmbeddedLyrics(id: Long): String? {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val descriptor = context.contentResolver.openFileDescriptor(uri, "r")
            ?: throw java.io.IOException("Couldn't open the song's file")
        descriptor.use {
            java.io.FileInputStream(it.fileDescriptor).channel.use { channel ->
                return EmbeddedLyrics.readStrict(ChannelByteSource(channel))
            }
        }
    }

    /**
     * The lyrics of each song of [ids] (see [getLyrics]), by id, "" for those
     * with none, for lyrics search to read the whole library a batch at a
     * time. Songs whose files can't be opened (a card still being mounted,
     * say) are left out, so they're tried again later rather than taken to
     * have none.
     */
    fun getLyricsBatch(ids: List<Long>): Map<String, String> {
        val found = mutableMapOf<String, String>()
        for (id in ids) {
            try {
                found["$id"] = readLyrics(id, strict = true) ?: ""
            } catch (e: Exception) {
                // Couldn't be opened: left out.
            }
        }
        return found
    }

    /**
     * A stamp for each of the songs given (as id and path) that changes when
     * its file, or the .lrc file beside it, does, by id, so lyrics search
     * only reads lyrics again when they may have changed.
     */
    fun getLyricsStamps(songs: List<Map<String, Any?>>): Map<String, String> {
        // When each file last changed, as Android has it, in one query.
        val modified = mutableMapOf<Long, String>()
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DATE_MODIFIED),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                modified[cursor.getLong(0)] = "${cursor.getLong(1)}.${cursor.getLong(2)}"
            }
        }
        val stamps = mutableMapOf<String, String>()
        for (song in songs) {
            val id = (song["id"] as Number).toLong()
            val stamp = modified[id] ?: continue
            val path = song["path"] as String?
            // 0 when there's none, or it can't be seen (from Android 13).
            val lrc = path?.let { File(it.substringBeforeLast('.') + ".lrc").lastModified() } ?: 0L
            stamps["$id"] = "$stamp.$lrc"
        }
        return stamps
    }

    /**
     * The song's lyrics as saved, timed (LRC) or plain: from its own tags, or
     * else a .lrc file of the same name beside it. Null if there are none.
     * When [strict], a file that can't be opened throws rather than counting
     * as having none.
     *
     * From Android 13 a music app may only read audio files, so the .lrc file
     * is only found on older versions.
     */
    private fun readLyrics(id: Long, strict: Boolean): String? {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val descriptor = try {
            context.contentResolver.openFileDescriptor(uri, "r")
        } catch (e: Exception) {
            if (strict) throw e
            null
        }
        try {
            descriptor?.use {
                java.io.FileInputStream(it.fileDescriptor).channel.use { channel ->
                    EmbeddedLyrics.read(ChannelByteSource(channel))?.let { text -> return text }
                }
            }
        } catch (e: Exception) {
            // Unreadable tags: try for a .lrc file instead.
        }
        val path = getFileInfo(id)["path"] as? String ?: return null
        val lrc = File(path.substringBeforeLast('.') + ".lrc")
        return try {
            if (lrc.canRead()) lrc.readText().trim().takeIf { it.isNotEmpty() } else null
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Sends the song's file to another app through Android's share sheet. The
     * app picked is let read just that file.
     */
    fun shareSong(id: Long, title: String?) {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val send = Intent(Intent.ACTION_SEND)
            .setType(context.contentResolver.getType(uri) ?: "audio/*")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // The share sheet previews and grants access from the clip, not the extra.
        send.clipData = android.content.ClipData.newRawUri(title, uri)
        // From the application context, so as a task of its own.
        context.startActivity(Intent.createChooser(send, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /**
     * Opens the folder holding [path] in the Files app, returning whether one
     * opened. Android has no standard way to show a folder, so this asks for
     * the folder's document in the external storage provider, which the
     * system Files app handles on most phones.
     */
    fun openFolder(path: String): Boolean {
        val folder = path.substringBeforeLast('/', "")
        // "/storage/emulated/0/Music/X" is "primary:Music/X"; an SD card's
        // "/storage/1A2B-3C4D/Music" is "1A2B-3C4D:Music".
        val match = Regex("^/storage/(emulated/0|[^/]+)/?(.*)$").find(folder) ?: return false
        val (volume, relative) = match.destructured
        val documentId = "${if (volume == "emulated/0") "primary" else volume}:$relative"
        val documentUri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", documentId)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(documentUri, DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Which of the songs given (as id and path) are hi-res, by id (see
     * [HiRes]). Only formats that can be lossless are opened; each song's
     * answer is kept in a small file, so it's only worked out once.
     */
    fun getHiRes(songs: List<Map<String, Any?>>): List<Long> {
        val dir = File(context.filesDir, "hi_res").apply { mkdirs() }
        val hiRes = mutableListOf<Long>()
        for (song in songs) {
            val id = (song["id"] as Number).toLong()
            val path = song["path"] as String?
            if (!HiRes.isCandidate(path)) continue
            val cached = File(dir, "$id")
            val yes = if (cached.exists()) {
                cached.readText() == "1"
            } else {
                checkHiRes(id, path!!).also { cached.writeText(if (it) "1" else "0") }
            }
            if (yes) hiRes.add(id)
        }
        return hiRes
    }

    private fun checkHiRes(id: Long, path: String): Boolean {
        val extension = path.substringAfterLast('.').lowercase()
        // DSD is always hi-res.
        if (extension == "dsf" || extension == "dff") return true
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val header = try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                java.io.FileInputStream(descriptor.fileDescriptor).channel.use { HiRes.readHeader(ChannelByteSource(it)) }
            }
        } catch (e: Exception) {
            null
        }
        if (header != null) return HiRes.isHiRes(header.first, header.second)
        // ALAC, AIFF and the rest: ask Android, as Details does.
        val format = getAudioFormat(id)
        val lossless = format["mime"] in setOf("audio/flac", "audio/x-flac", "audio/alac", "audio/raw", "audio/wav", "audio/x-wav")
        return lossless && HiRes.isHiRes((format["sampleRate"] as Int?) ?: 0, (format["bitsPerSample"] as Int?) ?: 0)
    }

    /**
     * The release type tagged in each song of [ids] that has one, "album", "ep"
     * or "single", by id. Each song's answer (none included) is kept in a
     * small file, so a song's tags are only read once.
     */
    fun getReleaseTypes(ids: List<Long>): Map<String, String> {
        val dir = File(context.filesDir, "release_types").apply { mkdirs() }
        val types = mutableMapOf<String, String>()
        for (id in ids) {
            val cached = File(dir, "$id")
            val type = if (cached.exists()) {
                cached.readText()
            } else {
                val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                val read = try {
                    context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                        java.io.FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                            EmbeddedLyrics.readTags(ChannelByteSource(channel)).releaseType
                        }
                    }
                } catch (e: Exception) {
                    null
                }
                (read ?: "").also { cached.writeText(it) }
            }
            if (type.isNotEmpty()) types["$id"] = type
        }
        return types
    }

    /**
     * How loud the song is across [points] equal slices of it, each 0..255
     * (255 the loudest slice), for the waveform seek bar; null if it can't
     * be decoded. Decoding takes a moment, so each result is kept in a small
     * file and only worked out once per song.
     */
    fun getWaveform(id: Long, points: Int): ByteArray? {
        val cached = File(File(context.filesDir, "waveforms").apply { mkdirs() }, "$id-$points")
        if (cached.exists()) return cached.readBytes()

        val levels = sampleLevels(id, points) ?: return null
        val loudest = levels.max()
        if (loudest <= 0) return null
        val bytes = ByteArray(points) { (levels[it] / loudest * 255).toInt().coerceIn(0, 255).toByte() }
        cached.writeBytes(bytes)
        return bytes
    }

    /**
     * How many decibels to turn the song up (or, below 0, down) by so it
     * plays about as loud as the rest, for volume normalisation: its
     * ReplayGain tag if it has one, otherwise worked out from a sample of
     * the song. Null if neither can be had. Kept in a small file once known.
     */
    fun getGain(id: Long): Double? {
        val cached = File(File(context.filesDir, "gains").apply { mkdirs() }, "$id")
        if (cached.exists()) cached.readText().toDoubleOrNull()?.let { return it }

        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val tagged = try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                java.io.FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                    EmbeddedLyrics.readTags(ChannelByteSource(channel)).trackGain
                }
            }
        } catch (e: Exception) {
            null
        }
        val gain = tagged ?: sampleLevels(id, GAIN_POINTS)?.let { levels ->
            // The loudness of the samples, root mean square, in dB of full scale.
            val rms = sqrt(levels.sumOf { it * it } / levels.size)
            if (rms <= 0) null else MEASURED_TARGET_DB - 20 * log10(rms)
        } ?: return null
        cached.writeText("$gain")
        return gain
    }

    /**
     * How loud the song is across [points] equal slices of it, each the root
     * mean square of its samples (0..1); null if it can't be decoded.
     */
    private fun sampleLevels(id: Long, points: Int): DoubleArray? {
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            if (durationUs <= 0) return null
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!).apply {
                configure(format, null, null, 0)
                start()
            }

            // Decoding all of a song takes many seconds, so each slice is
            // judged by a short burst of frames from its middle instead (an
            // eighth of a second or so is enough to tell how loud it is). The
            // bursts go through the decoder one after another without
            // stopping it, so the whole waveform takes a fraction of the
            // time; each frame that comes out counts towards the slice it was
            // fed in for. A slice's loudness is the root mean square of its
            // samples.
            val sums = DoubleArray(points)
            val counts = IntArray(points)
            var floatPcm = false
            val info = MediaCodec.BufferInfo()
            fun middleOf(slice: Int) = ((slice + 0.5) * durationUs / points).toLong()
            var slice = 0
            var fed = 0
            var inputDone = false
            var idle = 0
            // Frames out of the decoder so far, BURST_FRAMES to a slice.
            var decoded = 0
            extractor.seekTo(middleOf(0), MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            while (true) {
                if (!inputDone) {
                    val input = codec.dequeueInputBuffer(2_000)
                    if (input >= 0) {
                        if (fed == BURST_FRAMES) {
                            fed = 0
                            if (++slice < points) extractor.seekTo(middleOf(slice), MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                        }
                        val size = if (slice < points) extractor.readSampleData(codec.getInputBuffer(input)!!, 0) else -1
                        if (size < 0) {
                            codec.queueInputBuffer(input, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(input, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                            fed++
                        }
                    }
                }
                val output = codec.dequeueOutputBuffer(info, 2_000)
                if (output == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    // A decoder that never says it's finished: give up after a
                    // couple of seconds, without saving half a waveform.
                    if (inputDone && ++idle > 1000) return null
                } else if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    floatPcm = codec.outputFormat.intOrNull(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (output >= 0) {
                    if (info.size > 0) {
                        val pcm = codec.getOutputBuffer(output)!!.order(ByteOrder.nativeOrder())
                        pcm.position(info.offset)
                        pcm.limit(info.offset + info.size)
                        // By order, not time: decoders often ignore the jumps
                        // and count their timestamps on from the first frame.
                        val at = (decoded++ / BURST_FRAMES).coerceAtMost(points - 1)
                        if (floatPcm) {
                            val samples = pcm.asFloatBuffer()
                            for (i in 0 until samples.limit()) {
                                val s = samples.get(i).toDouble()
                                sums[at] += s * s
                            }
                            counts[at] += samples.limit()
                        } else {
                            val samples = pcm.asShortBuffer()
                            for (i in 0 until samples.limit()) {
                                val s = samples.get(i) / 32768.0
                                sums[at] += s * s
                            }
                            counts[at] += samples.limit()
                        }
                    }
                    codec.releaseOutputBuffer(output, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            // A slice that couldn't be read at all means the file can't be
            // decoded properly: don't save a waveform with holes in it.
            if (counts.count { it == 0 } > points / 10) return null

            return DoubleArray(points) { if (counts[it] > 0) sqrt(sums[it] / counts[it]) else 0.0 }
        } catch (e: Exception) {
            return null
        } finally {
            try {
                codec?.stop()
            } catch (e: Exception) {
                // Never started.
            }
            codec?.release()
            extractor.release()
        }
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) try { getInteger(key) } catch (e: Exception) { null } else null

    /** Returns a JPEG of the song's embedded artwork at roughly [size] px, or null if it has none. */
    fun getArtwork(id: Long, size: Int): ByteArray? {
        val bitmap = songArtwork(context, id, size) ?: return null
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            out.toByteArray()
        }
    }
}



/**
 * Streams what the player is outputting, for the Visualizer tab. Listen with
 * the player's audio session id; each event is a map of:
 * - `bands`: the spectrum's shape, frequency levels low to high, each 0..1.
 *   Android scales every capture to full range, so this says nothing about
 *   how loud the music is;
 * - `fineBands`: the same in more, narrower bands, for the bar styles;
 * - `wave`: the waveform's shape, -1..1, scaled the same way;
 * - `rms`: how loud the music actually is, in dB below full scale. This is
 *   after the volume is applied;
 * - `volume`: the music volume step, so a change can be told apart from the
 *   song getting quieter.
 *
 * Android only allows this with the RECORD_AUDIO permission, though nothing
 * is recorded: it reads the session's output, not the microphone.
 */
private class VisualizerStreamHandler(private val audio: AudioManager) : EventChannel.StreamHandler {
    private var visualizer: Visualizer? = null
    private var wave = DoubleArray(WAVE_POINTS)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        release()
        try {
            // Created on the main thread, so captures arrive there too, where
            // the event sink must be called.
            val v = Visualizer((arguments as Number).toInt())
            v.captureSize = Visualizer.getCaptureSizeRange()[1].coerceAtMost(1024)
            v.measurementMode = Visualizer.MEASUREMENT_MODE_PEAK_RMS
            val measurement = Visualizer.MeasurementPeakRms()
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(v: Visualizer, waveform: ByteArray, samplingRate: Int) {
                    wave = DoubleArray(WAVE_POINTS) { i ->
                        ((waveform[i * waveform.size / WAVE_POINTS].toInt() and 0xFF) - 128) / 128.0
                    }
                }

                override fun onFftDataCapture(v: Visualizer, fft: ByteArray, samplingRate: Int) {
                    // A capture queued just before this visualizer was let go
                    // (the song changed, say) can still arrive; reading it then
                    // throws and would crash the app.
                    if (v !== visualizer) return
                    try {
                        v.getMeasurementPeakRms(measurement)
                    } catch (e: IllegalStateException) {
                        return
                    }
                    events.success(
                        mapOf(
                            // samplingRate is in milliHertz.
                            "bands" to bands(fft, samplingRate / 1000.0),
                            "fineBands" to bands(fft, samplingRate / 1000.0, FINE_BANDS),
                            "wave" to wave,
                            // Millibels to decibels.
                            "rms" to measurement.mRms / 100.0,
                            "volume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                        )
                    )
                }
            }, Visualizer.getMaxCaptureRate(), true, true)
            v.enabled = true
            visualizer = v
        } catch (e: Exception) {
            events.error("visualizer_unavailable", e.message, null)
        }
    }

    override fun onCancel(arguments: Any?) = release()

    private fun release() {
        visualizer?.release()
        visualizer = null
    }

    companion object {
        const val BANDS = 48
        const val FINE_BANDS = 96
        const val WAVE_POINTS = 96
        const val MIN_HZ = 50.0
        const val MAX_HZ = 16000.0

        // Band levels in dB map from this range onto 0..1. The FFT's 8-bit
        // magnitudes top out around 45 dB.
        const val FLOOR_DB = 18.0
        const val CEILING_DB = 46.0
        const val TREBLE_FLOOR_DROP_DB = 16.0

        /** Groups FFT bins into [count] log-spaced bands, each a 0..1 level. */
        fun bands(fft: ByteArray, sampleRateHz: Double, count: Int = BANDS): DoubleArray {
            // fft holds the real parts of DC and Nyquist, then (re, im) per bin.
            val bins = fft.size / 2
            val binHz = sampleRateHz / fft.size
            fun magnitude(k: Int) = hypot(fft[2 * k].toDouble(), fft[2 * k + 1].toDouble())
            return DoubleArray(count) { b ->
                val low = MIN_HZ * (MAX_HZ / MIN_HZ).pow(b.toDouble() / count) / binHz
                val high = MIN_HZ * (MAX_HZ / MIN_HZ).pow((b + 1.0) / count) / binHz
                val peak = if (high - low < 1) {
                    // Bass bands are narrower than a bin: interpolate between the
                    // nearest two, so neighbouring bands don't all read the same.
                    val center = ((low + high) / 2).coerceIn(1.0, bins - 2.0)
                    val k = center.toInt()
                    val frac = center - k
                    magnitude(k) * (1 - frac) + magnitude(k + 1) * frac
                } else {
                    var max = 0.0
                    for (k in low.toInt().coerceIn(1, bins - 1)..high.toInt().coerceIn(1, bins - 1)) {
                        max = maxOf(max, magnitude(k))
                    }
                    max
                }
                // Higher frequencies carry far less energy; lower the floor
                // towards the treble so that end isn't flat.
                val x = b.toDouble() / count
                val floor = FLOOR_DB - TREBLE_FLOOR_DROP_DB * x
                val db = 20 * log10(peak + 1)
                ((db - floor) / (CEILING_DB - floor)).coerceIn(0.0, 1.0)
            }
        }
    }
}

/**
 * Undoes a common tagging mix-up: text saved as UTF-8 but labelled as
 * Latin-1, so Android reads each accented letter as two or three odd ones
 * ("Después" shows as "DespuÃ©s"). The string's characters are turned back
 * into the bytes they came from and read as UTF-8; that's kept only if
 * they make valid UTF-8 with something other than plain ASCII in it, so
 * correctly tagged text is never changed.
 */
private fun String.fixMojibake(): String {
    // Every garbled letter starts with one of Â..ô, the lead bytes of UTF-8.
    if (none { it in 'Â'..'ô' }) return this
    val cp1252 = Charset.forName("windows-1252").newEncoder()
    val bytes = ByteArray(length)
    for ((i, c) in withIndex()) {
        bytes[i] = when {
            c.code <= 0xFF -> c.code.toByte()
            // Read as Windows-1252, bytes 0x80..0x9F became letters like €, ’ and “.
            cp1252.canEncode(c) -> cp1252.encode(CharBuffer.wrap(c.toString())).get(0)
            else -> return this
        }
    }
    return try {
        val fixed = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
        if (fixed.any { it.code > 0x7F }) fixed else this
    } catch (e: CharacterCodingException) {
        this
    }
}
