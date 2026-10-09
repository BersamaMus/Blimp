package com.blimp.app

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import kotlin.math.roundToInt

/**
 * The song's embedded cover art at about [size] pixels, or null if it has
 * none. Android 10 and up keep thumbnails for this; before that, the cover is
 * read out of the file and scaled down here.
 */
fun songArtwork(context: Context, songId: Long, size: Int): Bitmap? {
    val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, songId)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        return try {
            context.contentResolver.loadThumbnail(uri, Size(size, size), null)
        } catch (e: Exception) {
            null
        }
    }
    val retriever = MediaMetadataRetriever()
    return try {
        retriever.setDataSource(context, uri)
        val bytes = retriever.embeddedPicture ?: return null
        // Decoded at the smallest power-of-two step that's still big enough,
        // so a large cover never takes its full size in memory.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= size && bounds.outHeight / (sample * 2) >= size) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val scale = size.toFloat() / maxOf(bitmap.width, bitmap.height)
        if (scale >= 1f) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * scale).roundToInt().coerceAtLeast(1),
                (bitmap.height * scale).roundToInt().coerceAtLeast(1),
                true,
            )
        }
    } catch (e: Exception) {
        null
    } finally {
        try {
            retriever.release()
        } catch (e: Exception) {
            // Nothing to release.
        }
    }
}
