package com.blimp.app

import android.content.ComponentName
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Connects to the app's media service the way Android Auto does and browses
 * it: the tabs at the top, then the songs under Albums' first album. Needs
 * music on the device and the app's access to it granted.
 */
@RunWith(AndroidJUnit4::class)
class CarBrowsingTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val main = Handler(Looper.getMainLooper())

    private fun children(browser: MediaBrowserCompat, parent: String): List<MediaBrowserCompat.MediaItem> {
        val latch = CountDownLatch(1)
        var result: List<MediaBrowserCompat.MediaItem> = emptyList()
        main.post {
            browser.subscribe(parent, object : MediaBrowserCompat.SubscriptionCallback() {
                override fun onChildrenLoaded(parentId: String, children: List<MediaBrowserCompat.MediaItem>) {
                    result = children
                    browser.unsubscribe(parent)
                    latch.countDown()
                }
            })
        }
        assertTrue("no answer for $parent", latch.await(60, TimeUnit.SECONDS))
        return result
    }

    @Test
    fun browsesTheLibrary() {
        // Installing for the test drops the app's access; a user would have given it.
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
            context.packageName,
            if (android.os.Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_AUDIO"
            else "android.permission.READ_EXTERNAL_STORAGE",
        )
        val connected = CountDownLatch(1)
        lateinit var browser: MediaBrowserCompat
        main.post {
            browser = MediaBrowserCompat(
                context,
                ComponentName(context, "com.ryanheise.audioservice.AudioService"),
                object : MediaBrowserCompat.ConnectionCallback() {
                    override fun onConnected() = connected.countDown()
                },
                null,
            )
            browser.connect()
        }
        assertTrue("couldn't connect", connected.await(60, TimeUnit.SECONDS))

        val root = children(browser, browser.root)
        val titles = root.map { it.description.title.toString() }
        println("CAR root: $titles")
        assertTrue(titles == listOf("Recent", "Favourites", "Playlists", "Albums", "Artists"))
        assertTrue(root.none { it.isPlayable })

        val albums = children(browser, "albums")
        println("CAR albums: ${albums.size}, first ${albums.firstOrNull()?.description?.title}")
        assertTrue(albums.isNotEmpty() && albums.all { it.isBrowsable })

        val songs = children(browser, albums.first().mediaId!!)
        println("CAR songs: ${songs.map { it.description.title }}")
        assertTrue(songs.isNotEmpty() && songs.all { it.isPlayable && it.mediaId!!.startsWith("song:") })

        // Picking a song plays it, as tapping it on the car's screen does.
        val playing = CountDownLatch(1)
        main.post {
            val controller = android.support.v4.media.session.MediaControllerCompat(context, browser.sessionToken)
            controller.registerCallback(object : android.support.v4.media.session.MediaControllerCompat.Callback() {
                override fun onPlaybackStateChanged(state: android.support.v4.media.session.PlaybackStateCompat?) {
                    if (state?.state == android.support.v4.media.session.PlaybackStateCompat.STATE_PLAYING) {
                        println("CAR playing: ${controller.metadata?.description?.title}")
                        controller.transportControls.pause()
                        playing.countDown()
                    }
                }
            })
            controller.transportControls.playFromMediaId(songs.first().mediaId, null)
        }
        assertTrue("didn't play", playing.await(60, TimeUnit.SECONDS))

        main.post { browser.disconnect() }
    }
}
