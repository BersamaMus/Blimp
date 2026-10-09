package com.blimp.app

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.Charset

/** Random access to a file's bytes, so tags can be read without loading the file. */
interface ByteSource {
    val size: Long

    /** Up to [length] bytes from [position]; fewer at the end of the file. */
    fun read(position: Long, length: Int): ByteArray
}

class ChannelByteSource(private val channel: FileChannel) : ByteSource {
    override val size: Long get() = channel.size()

    override fun read(position: Long, length: Int): ByteArray {
        if (position < 0 || position >= size || length <= 0) return ByteArray(0)
        val buffer = ByteBuffer.allocate(minOf(length.toLong(), size - position).toInt())
        while (buffer.hasRemaining()) {
            if (channel.read(buffer, position + buffer.position()) < 0) break
        }
        return buffer.array().copyOf(buffer.position())
    }
}

class ArrayByteSource(private val bytes: ByteArray) : ByteSource {
    override val size: Long get() = bytes.size.toLong()

    override fun read(position: Long, length: Int): ByteArray {
        if (position < 0 || position >= bytes.size || length <= 0) return ByteArray(0)
        return bytes.copyOfRange(position.toInt(), minOf(bytes.size.toLong(), position + length).toInt())
    }
}

/** What [EmbeddedLyrics] reads from a song's tags. */
data class EmbeddedTags(
    /** As saved, timed (LRC) or plain; null if there are none. */
    val lyrics: String? = null,
    /** ReplayGain's track gain in dB: how much to change the volume by to even it out. */
    val trackGain: Double? = null,
    /** What kind of release the song is from, "album", "ep" or "single", when tagged. */
    val releaseType: String? = null,
)

/**
 * Reads the lyrics, ReplayGain and release type saved inside a song's file: an ID3v2 tag
 * (MP3), Vorbis comments (FLAC, Ogg Vorbis, Opus) or MP4 atoms (M4A; lyrics only).
 */
object EmbeddedLyrics {
    /** No tag is read past this, so a damaged size can't take all the memory. */
    private const val MAX_TAG = 16 * 1024 * 1024

    private val LYRICS_KEYS = setOf("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "SYNCEDLYRICS")
    private const val GAIN_KEY = "REPLAYGAIN_TRACK_GAIN"

    /** Where taggers such as MusicBrainz Picard put the release type. */
    private val RELEASE_TYPE_KEYS = listOf("RELEASETYPE", "MUSICBRAINZ_ALBUMTYPE", "MUSICBRAINZ ALBUM TYPE")

    /** Just the lyrics. */
    fun read(source: ByteSource): String? = readTags(source).lyrics

    fun readTags(source: ByteSource): EmbeddedTags {
        val head = source.read(0, 12)
        val tags = try {
            when {
                head.startsWith("ID3") -> id3(source)
                head.startsWith("fLaC") -> flac(source)?.let(::fromComments)
                head.startsWith("OggS") -> ogg(source)?.let(::fromComments)
                head.size >= 8 && String(head, 4, 4, Charsets.ISO_8859_1) == "ftyp" -> EmbeddedTags(lyrics = mp4(source))
                else -> null
            }
        } catch (e: RuntimeException) {
            // A damaged tag: nothing rather than a crash.
            null
        } ?: return EmbeddedTags()
        val lyrics = tags.lyrics?.replace("\r\n", "\n")?.replace('\r', '\n')?.trim()?.takeIf { it.isNotEmpty() }
        return tags.copy(lyrics = lyrics)
    }

    /** "-6.54 dB" as -6.54. */
    private fun parseGain(value: String?): Double? =
        value?.trim()?.removeSuffix("dB")?.removeSuffix("db")?.trim()?.replace(',', '.')?.toDoubleOrNull()

    /**
     * The main type from a release type tag: "album; compilation" or
     * "Album/Live" is an album. Null for types other than album, EP and single.
     */
    fun parseReleaseType(value: String?): String? =
        value?.trim()?.lowercase()?.split(Regex("[;,/\\s]+"))?.firstOrNull()?.takeIf { it in setOf("album", "ep", "single") }

    private fun fromComments(comments: Map<String, String>) = EmbeddedTags(
        lyrics = LYRICS_KEYS.firstNotNullOfOrNull { comments[it] },
        trackGain = parseGain(comments[GAIN_KEY]),
        releaseType = parseReleaseType(RELEASE_TYPE_KEYS.firstNotNullOfOrNull { comments[it] }),
    )

    // ---------------------------------------------------------------------
    // ID3v2 (MP3, and some others)

    private fun id3(source: ByteSource): EmbeddedTags? {
        val header = source.read(0, 10)
        if (header.size < 10) return null
        val version = header[3].toInt()
        if (version != 3 && version != 4) return null
        val flags = header[5].toInt()
        val size = syncsafe(header, 6)
        var tag = source.read(10, minOf(size, MAX_TAG))
        if (version == 3 && flags and 0x80 != 0) tag = unsynchronise(tag)
        var pos = 0
        if (flags and 0x40 != 0) {
            pos = if (version == 4) syncsafe(tag, 0) else int32(tag, 0) + 4
        }

        var uslt: String? = null
        val txxx = mutableMapOf<String, String>()
        while (pos + 10 <= tag.size) {
            val id = String(tag, pos, 4, Charsets.ISO_8859_1)
            if (id[0] == '\u0000') break
            val frameSize = if (version == 4) syncsafe(tag, pos + 4) else int32(tag, pos + 4)
            val formatFlags = tag[pos + 9].toInt()
            val start = pos + 10
            pos = start + frameSize
            if (frameSize <= 0 || pos > tag.size) break

            var data = tag.copyOfRange(start, start + frameSize)
            if (version == 4) {
                if (formatFlags and 0x0C != 0) continue // compressed or encrypted
                if (formatFlags and 0x40 != 0) data = data.copyOfRange(1, data.size)
                if (formatFlags and 0x01 != 0) data = data.copyOfRange(4, data.size)
                if (formatFlags and 0x02 != 0) data = unsynchronise(data)
            } else if (formatFlags and 0xC0 != 0) {
                continue // compressed or encrypted
            }
            if (data.isEmpty()) continue

            when (id) {
                "USLT" -> {
                    // Encoding, a 3-letter language, a description, then the text.
                    val encoding = data[0].toInt()
                    val afterDescription = skipString(data, 4, encoding)
                    val text = decode(data, afterDescription, data.size, encoding)
                    if (uslt == null && text.isNotBlank()) uslt = text
                }
                "TXXX" -> {
                    val encoding = data[0].toInt()
                    val descriptionEnd = skipString(data, 1, encoding)
                    val description = decode(data, 1, terminatorStart(data, 1, encoding), encoding).trim().uppercase()
                    txxx.putIfAbsent(description, decode(data, descriptionEnd, data.size, encoding))
                }
            }
        }
        return EmbeddedTags(
            lyrics = uslt ?: LYRICS_KEYS.firstNotNullOfOrNull { txxx[it] },
            trackGain = parseGain(txxx[GAIN_KEY]),
            releaseType = parseReleaseType(RELEASE_TYPE_KEYS.firstNotNullOfOrNull { txxx[it] }),
        )
    }

    /** ID3's "syncsafe" integers use 7 bits per byte. */
    private fun syncsafe(b: ByteArray, at: Int): Int {
        if (at + 4 > b.size) return 0
        return (b[at].toInt() and 0x7F shl 21) or (b[at + 1].toInt() and 0x7F shl 14) or
            (b[at + 2].toInt() and 0x7F shl 7) or (b[at + 3].toInt() and 0x7F)
    }

    private fun int32(b: ByteArray, at: Int): Int {
        if (at + 4 > b.size) return 0
        return (b[at].toInt() and 0xFF shl 24) or (b[at + 1].toInt() and 0xFF shl 16) or
            (b[at + 2].toInt() and 0xFF shl 8) or (b[at + 3].toInt() and 0xFF)
    }

    /** Undoes ID3 unsynchronisation: every 0xFF 0x00 was written for 0xFF. */
    private fun unsynchronise(b: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream(b.size)
        var i = 0
        while (i < b.size) {
            out.write(b[i].toInt())
            if (b[i] == 0xFF.toByte() && i + 1 < b.size && b[i + 1] == 0.toByte()) i++
            i++
        }
        return out.toByteArray()
    }

    private fun charset(encoding: Int): Charset = when (encoding) {
        1 -> Charsets.UTF_16
        2 -> Charsets.UTF_16BE
        3 -> Charsets.UTF_8
        else -> Charsets.ISO_8859_1
    }

    /** Where the null terminator of the string starting at [from] begins. */
    private fun terminatorStart(b: ByteArray, from: Int, encoding: Int): Int {
        if (encoding == 1 || encoding == 2) {
            var i = from
            while (i + 1 < b.size) {
                if (b[i] == 0.toByte() && b[i + 1] == 0.toByte()) return i
                i += 2
            }
            return b.size
        }
        var i = from
        while (i < b.size && b[i] != 0.toByte()) i++
        return i
    }

    /** The index after the terminated string starting at [from]. */
    private fun skipString(b: ByteArray, from: Int, encoding: Int): Int {
        val end = terminatorStart(b, from, encoding)
        return minOf(b.size, end + if (encoding == 1 || encoding == 2) 2 else 1)
    }

    private fun decode(b: ByteArray, from: Int, to: Int, encoding: Int): String {
        if (from >= to) return ""
        // Text may carry its own terminator at the end.
        return String(b, from, to - from, charset(encoding)).trimEnd('\u0000')
    }

    // ---------------------------------------------------------------------
    // FLAC, Ogg Vorbis and Opus: Vorbis comments

    private fun flac(source: ByteSource): Map<String, String>? {
        var pos = 4L
        while (pos + 4 <= source.size) {
            val header = source.read(pos, 4)
            if (header.size < 4) return null
            val last = header[0].toInt() and 0x80 != 0
            val type = header[0].toInt() and 0x7F
            val length = (header[1].toInt() and 0xFF shl 16) or (header[2].toInt() and 0xFF shl 8) or
                (header[3].toInt() and 0xFF)
            if (type == 4) return vorbisComments(source.read(pos + 4, minOf(length, MAX_TAG)), 0)
            pos += 4 + length
            if (last) return null
        }
        return null
    }

    /**
     * The Ogg pages before the audio (granule position 0) hold the stream's
     * headers, the comments among them; their payloads are joined, since the
     * comments (and any cover art in them) can span many pages.
     */
    private fun ogg(source: ByteSource): Map<String, String>? {
        val headers = java.io.ByteArrayOutputStream()
        var pos = 0L
        var first = true
        while (pos + 27 <= source.size && headers.size() < MAX_TAG) {
            val page = source.read(pos, 27)
            if (page.size < 27 || String(page, 0, 4, Charsets.ISO_8859_1) != "OggS") break
            var granule = 0L
            for (i in 0 until 8) granule = granule or ((page[6 + i].toLong() and 0xFF) shl (8 * i))
            val segments = page[26].toInt() and 0xFF
            val table = source.read(pos + 27, segments)
            val payload = table.sumOf { it.toInt() and 0xFF }
            if (!first && granule != 0L) break
            headers.write(source.read(pos + 27 + segments, payload))
            pos += 27 + segments + payload
            first = false
        }
        val bytes = headers.toByteArray()
        for ((marker, skip) in listOf("OpusTags" to 8, "\u0003vorbis" to 7)) {
            val at = indexOf(bytes, marker.toByteArray(Charsets.ISO_8859_1))
            if (at >= 0) return vorbisComments(bytes, at + skip)
        }
        return null
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    private fun int32le(b: ByteArray, at: Int): Int {
        if (at + 4 > b.size) return -1
        return (b[at].toInt() and 0xFF) or (b[at + 1].toInt() and 0xFF shl 8) or
            (b[at + 2].toInt() and 0xFF shl 16) or (b[at + 3].toInt() and 0xFF shl 24)
    }

    /** A Vorbis comment block at [from]: vendor, then "KEY=value" comments. */
    private fun vorbisComments(b: ByteArray, from: Int): Map<String, String>? {
        val vendor = int32le(b, from)
        if (vendor < 0) return null
        var pos = from + 4 + vendor
        val count = int32le(b, pos)
        pos += 4
        // Keys in capitals, the first of each kept. A damaged comment ends
        // the reading, keeping what came before it.
        val comments = mutableMapOf<String, String>()
        for (i in 0 until count) {
            val length = int32le(b, pos)
            if (length < 0 || pos + 4 + length > b.size) break
            val comment = String(b, pos + 4, length, Charsets.UTF_8)
            pos += 4 + length
            val equals = comment.indexOf('=')
            if (equals > 0) comments.putIfAbsent(comment.substring(0, equals).uppercase(), comment.substring(equals + 1))
        }
        return comments
    }

    // ---------------------------------------------------------------------
    // MP4 / M4A: moov.udta.meta.ilst.©lyr

    private fun mp4(source: ByteSource): String? {
        val path = listOf("moov", "udta", "meta", "ilst", "©lyr", "data")
        var start = 0L
        var end = source.size
        for (name in path) {
            val atom = findAtom(source, start, end, name) ?: return null
            start = atom.first
            end = atom.second
            // meta holds 4 bytes of version and flags before its children.
            if (name == "meta") start += 4
        }
        // data: 4 bytes of type, 4 of locale, then the text.
        val length = (end - start - 8).toInt()
        if (length <= 0 || length > MAX_TAG) return null
        return String(source.read(start + 8, length), Charsets.UTF_8)
    }

    /** The content (start to end) of the first [name] atom between [from] and [to]. */
    private fun findAtom(source: ByteSource, from: Long, to: Long, name: String): Pair<Long, Long>? {
        var pos = from
        while (pos + 8 <= to) {
            val header = source.read(pos, 16)
            if (header.size < 8) return null
            var size = int32(header, 0).toLong() and 0xFFFFFFFFL
            var headerSize = 8
            if (size == 1L && header.size >= 16) {
                size = 0L
                for (i in 8 until 16) size = (size shl 8) or (header[i].toLong() and 0xFF)
                headerSize = 16
            } else if (size == 0L) {
                size = to - pos
            }
            if (size < headerSize) return null
            if (String(header, 4, 4, Charsets.ISO_8859_1) == name) return Pair(pos + headerSize, minOf(pos + size, to))
            pos += size
        }
        return null
    }

    private fun ByteArray.startsWith(prefix: String) =
        size >= prefix.length && String(this, 0, prefix.length, Charsets.ISO_8859_1) == prefix
}
