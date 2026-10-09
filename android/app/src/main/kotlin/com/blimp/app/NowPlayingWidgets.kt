package com.blimp.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.media.session.MediaController
import android.media.session.MediaSession
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.annotation.LayoutRes
import java.util.concurrent.Executors

/**
 * The home screen widgets showing what's playing, with previous, play/pause
 * and next buttons. The app tells them what to show (see [HomeWidgets.save]),
 * which is saved so they can redraw after the launcher or app restarts. Once
 * playback ends they keep showing the last song, paused.
 */
abstract class NowPlayingWidget(@LayoutRes private val layout: Int, private val artSize: Int) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        HomeWidgets.executor.execute {
            try {
                HomeWidgets.render(context, manager, ids, layout, artSize)
            } finally {
                pending.finish()
            }
        }
    }
}

/** 4x1: art, title and artist, controls in a row. */
class NowPlayingWidgetSmall : NowPlayingWidget(R.layout.widget_now_playing_small, 160)

/** 2x2: the art fills it, with title, artist and controls on top. */
class NowPlayingWidgetSquare : NowPlayingWidget(R.layout.widget_now_playing_square, 480)

/** 4x2: large art beside title, artist, album and controls. */
class NowPlayingWidgetWide : NowPlayingWidget(R.layout.widget_now_playing_wide, 360)

object HomeWidgets {
    /** Loads artwork and pushes updates off the main thread, one at a time. */
    val executor = Executors.newSingleThreadExecutor()

    private const val PREFS = "home_widgets"
    const val ACTION_PREVIOUS = "com.blimp.app.widget.PREVIOUS"
    const val ACTION_PLAY_PAUSE = "com.blimp.app.widget.PLAY_PAUSE"
    const val ACTION_NEXT = "com.blimp.app.widget.NEXT"

    private val providers = listOf(
        Triple(NowPlayingWidgetSmall::class.java, R.layout.widget_now_playing_small, 160),
        Triple(NowPlayingWidgetSquare::class.java, R.layout.widget_now_playing_square, 480),
        Triple(NowPlayingWidgetWide::class.java, R.layout.widget_now_playing_wide, 360),
    )

    data class State(
        val songId: Long,
        val title: String?,
        val artist: String?,
        val album: String?,
        val playing: Boolean,
        /** Whether the app has a queue loaded, for the buttons to control. */
        val loaded: Boolean,
    ) {
        val hasSong get() = songId >= 0
    }

    fun read(context: Context): State {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return State(
            songId = prefs.getLong("songId", -1),
            title = prefs.getString("title", null),
            artist = prefs.getString("artist", null),
            album = prefs.getString("album", null),
            playing = prefs.getBoolean("playing", false),
            loaded = prefs.getBoolean("loaded", false),
        )
    }

    /**
     * Saves what to show and redraws every widget. With no song loaded (a
     * null [songId]) they keep showing the last one, paused, and their
     * buttons open the app to play it.
     */
    fun save(
        context: Context,
        songId: Long?,
        title: String?,
        artist: String?,
        album: String?,
        playing: Boolean,
    ) {
        val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (songId != null) {
            edit.putLong("songId", songId)
                .putString("title", title)
                .putString("artist", artist)
                .putString("album", album)
        }
        edit.putBoolean("playing", playing && songId != null)
            .putBoolean("loaded", songId != null)
            .apply()
        updateAll(context)
    }

    /**
     * Keeps the song shown but paused, with buttons that open the app, for
     * when playback may have ended without the app saying so.
     */
    fun unload(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("playing", false)
            .putBoolean("loaded", false)
            .apply()
        updateAll(context)
    }

    /**
     * Colours the widgets in the app's theme: the play button in [accent],
     * its icon in [onAccent]. Kept apart from what they show, so [clear]
     * doesn't forget them.
     */
    fun setColors(context: Context, accent: Int, onAccent: Int) {
        context.getSharedPreferences(COLOR_PREFS, Context.MODE_PRIVATE).edit()
            .putInt("accent", accent)
            .putInt("onAccent", onAccent)
            .apply()
        updateAll(context)
    }

    private const val COLOR_PREFS = "home_widget_colors"

    /** Shows nothing playing. */
    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        updateAll(context)
    }

    fun updateAll(context: Context) {
        val app = context.applicationContext
        executor.execute {
            val manager = AppWidgetManager.getInstance(app)
            for ((provider, layout, artSize) in providers) {
                val ids = manager.getAppWidgetIds(ComponentName(app, provider))
                if (ids.isNotEmpty()) render(app, manager, ids, layout, artSize)
            }
        }
    }

    // The last song's artwork at each size, so play/pause doesn't reload it.
    private var artSongId = -1L
    private val artCache = mutableMapOf<Int, Bitmap?>()

    private fun artwork(context: Context, songId: Long, size: Int): Bitmap? {
        if (songId < 0) return null
        if (songId != artSongId) {
            artCache.clear()
            artSongId = songId
        }
        return artCache.getOrPut(size) { songArtwork(context, songId, size) }
    }

    fun render(context: Context, manager: AppWidgetManager, ids: IntArray, @LayoutRes layout: Int, artSize: Int) {
        val state = read(context)
        val views = RemoteViews(context.packageName, layout)
        if (state.hasSong) {
            views.setTextViewText(R.id.widget_title, state.title ?: "")
            views.setTextViewText(R.id.widget_artist, state.artist ?: "")
        } else {
            views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_nothing_playing))
            views.setTextViewText(R.id.widget_artist, context.getString(R.string.widget_tap_to_open))
        }
        if (layout == R.layout.widget_now_playing_wide) {
            val album = state.album?.takeIf { state.hasSong && it.isNotBlank() }
            views.setTextViewText(R.id.widget_album, album ?: "")
            views.setViewVisibility(R.id.widget_album, if (album == null) View.GONE else View.VISIBLE)
        }

        val art = artwork(context, state.songId, artSize)
        if (art != null) {
            views.setImageViewBitmap(R.id.widget_art, art)
        } else {
            views.setImageViewResource(R.id.widget_art, R.drawable.widget_art_placeholder)
        }

        views.setImageViewResource(
            R.id.widget_play,
            if (state.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
        )
        views.setContentDescription(
            R.id.widget_play,
            context.getString(if (state.playing) R.string.widget_pause else R.string.widget_play),
        )

        // The play button in the app's theme. Android only lets a widget's
        // background be recoloured from 12 on; before that the button keeps
        // the default turquoise, so its icon does too.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val colors = context.getSharedPreferences(COLOR_PREFS, Context.MODE_PRIVATE)
            val accent = colors.getInt("accent", context.getColor(R.color.widget_accent))
            val onAccent = colors.getInt("onAccent", context.getColor(R.color.widget_on_accent))
            views.setColorStateList(R.id.widget_play, "setBackgroundTintList", ColorStateList.valueOf(accent))
            views.setColorStateList(R.id.widget_play, "setImageTintList", ColorStateList.valueOf(onAccent))
        }

        // With a queue loaded the buttons control it in the background.
        // Without one they open the app, which loads the last song and does
        // what was tapped, or lets a song be picked if there's none. That has
        // to be set here: Android won't let the button handler open the app
        // itself from the background.
        fun button(action: String, request: String, code: Int) = when {
            state.loaded -> action(context, action, code)
            state.hasSong -> openApp(context, request)
            else -> openApp(context)
        }
        // With a song to show, the widget itself opens straight to the player.
        views.setOnClickPendingIntent(
            R.id.widget_root,
            if (state.hasSong) openApp(context, REQUEST_OPEN_PLAYER) else openApp(context),
        )
        views.setOnClickPendingIntent(R.id.widget_prev, button(ACTION_PREVIOUS, REQUEST_PREVIOUS, 1))
        views.setOnClickPendingIntent(R.id.widget_play, button(ACTION_PLAY_PAUSE, REQUEST_PLAY, 2))
        views.setOnClickPendingIntent(R.id.widget_next, button(ACTION_NEXT, REQUEST_NEXT, 3))
        manager.updateAppWidget(ids, views)
    }

    /**
     * Extra on the intent that opens the app, saying what the widget asked
     * for: one of the REQUEST_ values, named as in the app's WidgetRequest.
     */
    const val EXTRA_REQUEST = "com.blimp.app.widget.REQUEST"
    const val REQUEST_OPEN_PLAYER = "openPlayer"
    const val REQUEST_PLAY = "play"
    const val REQUEST_PREVIOUS = "previous"
    const val REQUEST_NEXT = "next"

    // Each kind needs its own request code, or the system treats them as one.
    private val requestCodes = mapOf(
        null to 0,
        REQUEST_OPEN_PLAYER to 10,
        REQUEST_PLAY to 11,
        REQUEST_PREVIOUS to 12,
        REQUEST_NEXT to 13,
    )

    /** Opens the app, asking it for [request] if given. */
    fun openApp(context: Context, request: String? = null): PendingIntent = PendingIntent.getActivity(
        context,
        requestCodes.getValue(request),
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_REQUEST, request),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun action(context: Context, action: String, requestCode: Int): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        Intent(context, WidgetActionReceiver::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * The playback service's media session, if music is loaded. audio_service
     * keeps its running service in a package-private field, so it's read by
     * reflection; null when the service isn't running.
     */
    fun mediaController(context: Context): MediaController? = try {
        val service = Class.forName("com.ryanheise.audioservice.AudioService")
            .getDeclaredField("instance")
            .apply { isAccessible = true }
            .get(null)
        val compatToken = service?.javaClass?.getMethod("getSessionToken")?.invoke(service)
        val token = compatToken?.javaClass?.getMethod("getToken")?.invoke(compatToken) as? MediaSession.Token
        token?.let { MediaController(context, it) }
    } catch (e: Exception) {
        null
    }
}

/** Handles the widgets' previous, play/pause and next buttons. */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val controller = HomeWidgets.mediaController(context)
        if (controller == null) {
            // Playback ended without the widgets hearing (say, the system
            // closed the app): show that, which also points the buttons at
            // the app for next time.
            HomeWidgets.unload(context)
            return
        }
        val controls = controller.transportControls
        when (intent.action) {
            HomeWidgets.ACTION_PREVIOUS -> controls.skipToPrevious()
            HomeWidgets.ACTION_NEXT -> controls.skipToNext()
            HomeWidgets.ACTION_PLAY_PAUSE -> {
                val state = HomeWidgets.read(context)
                if (state.playing) controls.pause() else controls.play()
            }
        }
    }
}
